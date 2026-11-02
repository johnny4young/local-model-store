import Foundation

/// Downloads and verifies model artifacts against the pinned registry.
/// Nothing is ever loaded from a directory this store hasn't verified:
/// a model file is code we execute, so integrity is not optional.
public actor LocalModelStore {
    /// Room kept free beyond a download, so an install does not fill the disk.
    private static let freeSpaceMargin: Int64 = 64 << 20

    nonisolated let layout: StoreLayout
    let now: @Sendable () -> Date
    private let session: URLSession
    let waitPolicy: WaitPolicy
    private let availableCapacity: @Sendable (URL) -> Int64?
    var verifiedFingerprints: [String: [FileFingerprint]] = [:]
    private(set) var fullInspectionCount = 0
    private var claims: ClaimStore { ClaimStore(layout: layout, now: now) }

    nonisolated public let consumer: StoreConsumer

    /// Location and consumer are always explicit, so no caller can reach a real
    /// store by accident. Nothing is written until an install needs it.
    public init(location: StoreLocation, consumer: StoreConsumer, session: URLSession = .shared) throws {
        try self.init(location: location, consumer: consumer, session: session, waitPolicy: WaitPolicy())
    }

    package init(
        location: StoreLocation,
        consumer: StoreConsumer,
        session: URLSession,
        waitPolicy: WaitPolicy,
        availableCapacity: @escaping @Sendable (URL) -> Int64? = LocalModelStore.volumeCapacity,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard consumer.hasSafeBundleID else {
            throw LocalModelStoreError.invalidConsumer(bundleID: consumer.bundleID)
        }
        self.layout = StoreLayout(root: try location.resolvedRoot())
        self.now = now
        self.consumer = consumer
        self.session = session
        self.waitPolicy = waitPolicy
        self.availableCapacity = availableCapacity
    }

    /// The important-usage figure can read 0 outside APFS, which would report a full
    /// disk on an external volume, so the larger of the two counts.
    package static func volumeCapacity(at url: URL) -> Int64? {
        let existing = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? existing.resourceValues(forKeys: keys) else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        return max(important, Int64(values.volumeAvailableCapacity ?? 0))
    }

    /// The exact directory a loader receives.
    public func directory(for manifest: ModelManifest) throws -> URL {
        try manifest.validate()
        return layout.payload(manifest.storeKey)
    }

    /// Re-hashes every artifact on disk against the manifest, away from the actor.
    /// A cancelled pass reports the unread files as corrupted, never as verified.
    public func verify(_ manifest: ModelManifest) async -> VerificationReport {
        await inspect(manifest).report
    }

    /// Returns loadable installation evidence only after every pinned artifact
    /// has been hashed in this process and is unchanged since. Callers must not
    /// infer readiness from directory, filename, or byte-count checks of their own.
    /// This says the bytes are good, not that this app may use them: another app can
    /// have installed them, so consent stays each app's own decision.
    public func verifiedInstallation(
        _ manifest: ModelManifest,
        forceHash: Bool = false
    ) async -> VerifiedInstallation? {
        if !forceHash, fingerprintIsCurrent(manifest) { return evidence(for: manifest) }
        return await inspect(manifest).report.isComplete ? evidence(for: manifest) : nil
    }

    /// Whether the files still match the ones last hashed clean. No file is read.
    public func fingerprintIsCurrent(_ manifest: ModelManifest) -> Bool {
        guard let expected = verifiedFingerprints[manifest.evidenceKey] else { return false }
        return Self.fingerprints(of: manifest, at: layout.payload(manifest.storeKey)) == expected
    }

    /// Ensures the model is installed and verified, placing each file from what is
    /// already on this Mac when it can and downloading the rest. Returns the
    /// directory to load. `seeds` are read-only directories shaped like the payload,
    /// such as a legacy install; their bytes count only after hashing.
    @discardableResult
    public func ensureAvailable(
        _ manifest: ModelManifest,
        seeds: [URL] = [],
        progress: (@Sendable (InstallEvent) -> Void)? = nil
    ) async throws -> URL {
        let base = try directory(for: manifest)
        progress?(.verifying)
        // Without this app's claim, the slow path claims under the lock, so a
        // removal in another process cannot miss it.
        if await verifiedInstallation(manifest) != nil, claims.isActive(manifest.storeKey, consumer: consumer) {
            claims.touch(manifest.storeKey, consumer: consumer)
            return base
        }
        try Task.checkCancellation()

        // The first write of an install, so the lock cannot create the root with wider permissions.
        try Self.storing("store") { try layout.prepare() }

        // Nil means a stalled holder or no `flock`: installing anyway is safe,
        // because publishing is atomic and every file is hashed first.
        let lock = try await acquireInstallLock(for: manifest, progress: progress)
        defer { withExtendedLifetime(lock) {} }
        // A crashed or finished holder's progress must not read as this one's.
        lock?.write(Data())
        let version = layout.version
        await Self.offActor { StagingDirectory.sweep(root: version) }
        progress?(.verifying)
        if await verifiedInstallation(manifest) == nil {
            try Task.checkCancellation()
            try await install(manifest, seeds: seeds, lock: lock, progress: progress)
        }
        try Self.storing("claim") { try claims.write(manifest, consumer: consumer) }
        return base
    }

    // MARK: - Internals

    private func evidence(for manifest: ModelManifest) -> VerifiedInstallation {
        VerifiedInstallation(
            manifestID: manifest.id,
            manifestRevision: manifest.revision,
            directory: layout.payload(manifest.storeKey),
            artifactBytes: Int64(manifest.totalSizeBytes))
    }

    private func acquireInstallLock(
        for manifest: ModelManifest,
        progress: (@Sendable (InstallEvent) -> Void)?
    ) async throws -> FileLock? {
        let url = layout.installLock(manifest.storeKey)
        let clock = ContinuousClock()
        var lastReport: Data?
        var lastChange = clock.now
        var announced = false
        while true {
            switch try Self.storingResult(url.lastPathComponent, { try FileLock.tryExclusive(at: url) }) {
            case .acquired(let lock): return lock
            case .unsupported: return nil
            case .busy: break
            }
            let report = try? Data(contentsOf: url)
            if !announced || report != lastReport {
                lastReport = report
                lastChange = clock.now
                let snapshot = report.flatMap { try? JSONDecoder().decode(ProgressReport.self, from: $0) }
                if !announced || snapshot != nil {
                    announced = true
                    progress?(.waitingForOtherProcess(
                        completedBytes: snapshot?.completedBytes ?? 0,
                        totalBytes: snapshot?.totalBytes ?? manifest.totalSizeBytes))
                }
            }
            if clock.now - lastChange >= waitPolicy.stallTimeout { return nil }
            try await Task.sleep(for: waitPolicy.pollInterval)
        }
    }

    private func inspect(_ manifest: ModelManifest) async -> Inspection {
        guard (try? manifest.validate()) != nil else {
            return Inspection(
                report: VerificationReport(missing: manifest.artifacts.map(\.path), corrupted: ["invalid manifest"]),
                fingerprints: nil)
        }
        let inspection = await inspectFiles(of: manifest, at: layout.payload(manifest.storeKey))
        verifiedFingerprints[manifest.evidenceKey] = inspection.fingerprints
        return inspection
    }

    private func inspectFiles(of manifest: ModelManifest, at payload: URL) async -> Inspection {
        fullInspectionCount += 1
        return await Self.offActor { Self.inspectFiles(of: manifest, at: payload) }
    }

    private func install(
        _ manifest: ModelManifest,
        seeds: [URL],
        lock: FileLock?,
        progress: (@Sendable (InstallEvent) -> Void)?
    ) async throws {
        let staging = try Self.storingResult("staging") { try StagingDirectory(root: layout.version) }
        defer { staging.remove() }
        let payload = staging.url.appendingPathComponent("payload", isDirectory: true)

        // The current install comes first: a repair keeps every file that still hashes clean.
        let sharedSources = localSources()
        var toFetch: [ModelArtifact] = []
        var placedBytes = 0
        for artifact in manifest.artifacts {
            let roots = [layout.payload(manifest.storeKey)] + seeds
            let sources = roots.map { LocalSource(root: $0, path: artifact.path) }
                + (sharedSources[artifact.sha256] ?? [])
            if try await placeLocally(artifact, in: payload, from: sources) {
                placedBytes += artifact.sizeBytes
                // A long copy from a slow disk must not read as a stall to waiters.
                lock?.write(ProgressReport(completedBytes: placedBytes, totalBytes: manifest.totalSizeBytes).encoded)
            } else {
                toFetch.append(artifact)
            }
        }
        try checkFreeSpace(for: toFetch)

        let totalBytes = toFetch.reduce(0) { $0 + $1.sizeBytes }
        var completedBytes = 0
        for artifact in toFetch {
            let completed = completedBytes
            let onBytes: @Sendable (Int) -> Void = { written in
                let state = DownloadProgress(
                    completedBytes: completed + written, totalBytes: totalBytes, currentPath: artifact.path)
                progress?(.downloading(state))
                lock?.write(ProgressReport(completedBytes: state.completedBytes, totalBytes: totalBytes).encoded)
            }
            onBytes(0)
            try await fetch(artifact, of: manifest, into: payload, staging: staging.url, onBytes: onBytes)
            completedBytes += artifact.sizeBytes
        }
        if !toFetch.isEmpty {
            progress?(.downloading(
                DownloadProgress(completedBytes: totalBytes, totalBytes: totalBytes, currentPath: "")))
        }

        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let information = try JSONEncoder.sorted.encode(manifest)
        try information.write(to: staging.url.appendingPathComponent("manifest.json"))
        let sealed = staging.url
        let sealing = await Self.offActor { Result { try ModelInstaller.seal(sealed) } }
        try Self.storing("seal") { try sealing.get() }

        // The last check before the commit point: everything the manifest lists,
        // and nothing else, hashes clean.
        progress?(.verifying)
        let final = await inspectFiles(of: manifest, at: payload)
        try Task.checkCancellation()
        guard final.report.isComplete else {
            throw LocalModelStoreError.notInstalled(missing: final.report.missing, corrupted: final.report.corrupted)
        }
        try await commit(manifest, staging: staging.url, fingerprints: final.fingerprints)
    }

    /// Nothing after the rename can fail or be cancelled, so a published install
    /// is always reported as one.
    private func commit(
        _ manifest: ModelManifest,
        staging: URL,
        fingerprints: [FileFingerprint]?
    ) async throws {
        let model = layout.model(manifest.storeKey)
        switch try Self.storingResult("publish", { try ModelInstaller.publish(staging, as: model) }) {
        case .published:
            verifiedFingerprints[manifest.evidenceKey] = fingerprints
            waitPolicy.afterPublish?()
        case .alreadyExists:
            try await keepOrRepair(manifest, model: model, staging: staging, fingerprints: fingerprints)
        }
    }

    /// Either another process just won, or this is a repair of a damaged install.
    /// Past the point of cancelling: a cancelled hash would read as damage. The
    /// target is re-read before replacing it, so a repair that lands during the
    /// hash is kept. Without a lock a small window remains, and both copies are verified.
    private func keepOrRepair(
        _ manifest: ModelManifest,
        model: URL,
        staging: URL,
        fingerprints: [FileFingerprint]?
    ) async throws {
        let payload = layout.payload(manifest.storeKey)
        while true {
            let target = FileFingerprint.read(model)
            let existing = await Task.detached(priority: .utility) {
                Self.inspectFiles(of: manifest, at: payload)
            }.value
            if existing.report.isComplete {
                verifiedFingerprints[manifest.evidenceKey] = existing.fingerprints
                return
            }
            waitPolicy.beforeRepair?()
            guard FileFingerprint.read(model) == target else { continue }
            try Self.storing("publish") {
                try ModelInstaller.replace(model, with: staging, trash: layout.trash)
            }
            keepOldCopyWhileLeased(manifest.storeKey, at: staging)
            verifiedFingerprints[manifest.evidenceKey] = fingerprints
            return
        }
    }

    /// A reader with a lease may hold a directory handle into the copy just replaced,
    /// so that copy waits in the trash until the lease ends. Otherwise staging cleanup
    /// deletes it. The key in the name tells a collection which lease to check.
    private func keepOldCopyWhileLeased(_ key: String, at old: URL) {
        guard case .busy? = try? FileLock.tryExclusive(at: layout.useLock(key)) else { return }
        let kept = layout.trash.appendingPathComponent("\(key)~\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: layout.trash, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: old, to: kept)
    }

    /// Other installs that hold a file with a given hash, as a re-pin usually does.
    /// Their manifests are only hints: paths are checked here and bytes after cloning.
    private func localSources() -> [String: [LocalSource]] {
        var sources: [String: [LocalSource]] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.models.path)) ?? []
        for name in names {
            let file = layout.models.appendingPathComponent("\(name)/manifest.json")
            guard let data = try? Data(contentsOf: file),
                  let other = try? JSONDecoder().decode(ModelManifest.self, from: data) else { continue }
            for artifact in other.artifacts where artifact.hasSafePath {
                let source = LocalSource(root: layout.payload(name), path: artifact.path)
                sources[artifact.sha256, default: []].append(source)
            }
        }
        return sources
    }

    /// Tries each local source in order. A source is only a hint: bad bytes are
    /// discarded and the next one is tried.
    private func placeLocally(
        _ artifact: ModelArtifact,
        in payload: URL,
        from sources: [LocalSource]
    ) async throws -> Bool {
        let destination = payload.appendingPathComponent(artifact.path)
        for source in sources {
            try Task.checkCancellation()
            let placement = await Self.offActor {
                Result { try ModelInstaller.place(from: source.root, path: source.path, to: destination) }
            }
            guard try Self.storingResult(artifact.path, { try placement.get() }) == .placed else { continue }
            let digest = try await Self.offActor { Result { try Self.sha256(of: destination) } }.get()
            if digest == artifact.sha256 { return true }
            try? FileManager.default.removeItem(at: destination)
        }
        return false
    }

    private func checkFreeSpace(for artifacts: [ModelArtifact]) throws {
        guard let first = artifacts.first, let available = availableCapacity(layout.root) else { return }
        let needed = artifacts.reduce(Int64(0)) { $0 + Int64($1.sizeBytes) } + Self.freeSpaceMargin
        if available < needed { throw LocalModelStoreError.outOfSpace(path: first.path) }
    }

    private func fetch(
        _ artifact: ModelArtifact,
        of manifest: ModelManifest,
        into payload: URL,
        staging: URL,
        onBytes: @escaping @Sendable (Int) -> Void
    ) async throws {
        let source = manifest.downloadURL(for: artifact)
        let destination = payload.appendingPathComponent(artifact.path)
        let staged = staging.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }

        let response: URLResponse
        do {
            response = try await ArtifactDownload.run(
                session: session, from: source, to: staged, onBytes: onBytes)
        } catch {
            try Task.checkCancellation()
            // URLSession also writes its temporary download to disk.
            if Self.isOutOfSpace(error as NSError) { throw LocalModelStoreError.outOfSpace(path: artifact.path) }
            throw LocalModelStoreError.downloadFailed(
                path: artifact.path, underlying: String(describing: error))
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LocalModelStoreError.downloadFailed(path: artifact.path, underlying: "HTTP \(http.statusCode)")
        }

        try Task.checkCancellation()
        try Self.storing(artifact.path) {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? Int) ?? -1
        guard size == artifact.sizeBytes else {
            throw LocalModelStoreError.sizeMismatch(
                path: artifact.path, expected: artifact.sizeBytes, actual: size)
        }

        let digest = try await Self.offActor { Result { try Self.sha256(of: staged) } }.get()
        guard digest == artifact.sha256 else {
            throw LocalModelStoreError.checksumMismatch(
                path: artifact.path, expected: artifact.sha256, actual: digest)
        }

        try Task.checkCancellation()
        try Self.storing(artifact.path) { try FileManager.default.moveItem(at: staged, to: destination) }
    }
}

/// A file that might already hold the bytes an install needs.
private struct LocalSource: Sendable {
    let root: URL
    let path: String
}

/// What a lock holder publishes for waiters. Advisory: a torn read only delays
/// the next update.
private struct ProgressReport: Codable {
    let completedBytes: Int
    let totalBytes: Int

    var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}
