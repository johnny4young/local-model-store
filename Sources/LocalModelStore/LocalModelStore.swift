import CryptoKit
import Foundation

/// Downloads and verifies model artifacts against the pinned registry.
/// Nothing is ever loaded from a directory this store hasn't verified:
/// a model file is code we execute, so integrity is not optional.
public actor LocalModelStore {
    public enum LocalModelStoreError: Error, LocalizedError {
        case checksumMismatch(path: String, expected: String, actual: String)
        case sizeMismatch(path: String, expected: Int, actual: Int)
        case downloadFailed(path: String, underlying: String)
        /// The disk or quota was full while downloading, staging or publishing.
        case outOfSpace(path: String)
        case notInstalled(missing: [String], corrupted: [String])

        public var errorDescription: String? {
            switch self {
            case .checksumMismatch(let path, let expected, let actual):
                return "sha256 mismatch for \(path): expected \(expected), got \(actual)"
            case .sizeMismatch(let path, let expected, let actual):
                return "size mismatch for \(path): expected \(expected) bytes, got \(actual)"
            case .downloadFailed(let path, let underlying):
                return "download failed for \(path): \(underlying)"
            case .outOfSpace(let path):
                return "not enough disk space to save \(path)"
            case .notInstalled(let missing, let corrupted):
                return "model not installed (missing: \(missing.count), corrupted: \(corrupted.count))"
            }
        }
    }

    /// Result of checking an installed model against its manifest.
    public struct VerificationReport: Sendable {
        public let missing: [String]
        public let corrupted: [String]
        public var isComplete: Bool { missing.isEmpty && corrupted.isEmpty }
    }

    /// A directory that passed the complete pinned manifest, not merely a
    /// path that happens to contain one expected filename.
    public struct VerifiedInstallation: Equatable, Sendable {
        public let manifestID: String
        public let manifestRevision: String
        public let directory: URL
        public let artifactBytes: Int64

        init(
            manifestID: String,
            manifestRevision: String,
            directory: URL,
            artifactBytes: Int64
        ) {
            self.manifestID = manifestID
            self.manifestRevision = manifestRevision
            self.directory = directory
            self.artifactBytes = artifactBytes
        }
    }

    public struct DownloadProgress: Equatable, Sendable {
        public let completedBytes: Int
        public let totalBytes: Int
        public let currentPath: String
        public var fraction: Double {
            totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0
        }
    }

    /// A checksum pass or a wait is never reported as a download.
    public enum InstallEvent: Equatable, Sendable {
        case verifying
        case waitingForOtherProcess(completedBytes: Int, totalBytes: Int)
        case downloading(DownloadProgress)
    }

    /// How a waiter behaves while another process holds the install lock.
    package struct WaitPolicy: Sendable {
        package var pollInterval: Duration = .milliseconds(100)
        /// A holder that reports no progress for this long is raced, never robbed:
        /// the waiter installs on its own, and the worst outcome is wasted bytes.
        package var stallTimeout: Duration = .seconds(120)

        package init() {}
    }

    private struct Inspection: Sendable {
        let report: VerificationReport
        /// Present only when every file hashed clean and stayed unchanged meanwhile.
        let fingerprints: [FileFingerprint]?
    }

    private let rootDirectory: URL
    private let session: URLSession
    private let waitPolicy: WaitPolicy
    private var verifiedFingerprints: [String: [FileFingerprint]] = [:]
    private(set) var fullInspectionCount = 0

    nonisolated public let consumer: StoreConsumer

    /// Root and consumer are always explicit, so no caller can reach a real
    /// store by accident.
    public init(rootDirectory: URL, consumer: StoreConsumer, session: URLSession = .shared) {
        self.rootDirectory = rootDirectory
        self.consumer = consumer
        self.session = session
        self.waitPolicy = WaitPolicy()
    }

    package init(rootDirectory: URL, consumer: StoreConsumer, session: URLSession, waitPolicy: WaitPolicy) {
        self.rootDirectory = rootDirectory
        self.consumer = consumer
        self.session = session
        self.waitPolicy = waitPolicy
    }

    public func directory(for manifest: ModelManifest) -> URL {
        rootDirectory.appendingPathComponent(manifest.folderName, isDirectory: true)
    }

    /// Re-hashes every artifact on disk against the manifest, away from the actor.
    /// A cancelled pass reports the unread files as corrupted, never as verified.
    public func verify(_ manifest: ModelManifest) async -> VerificationReport {
        await inspect(manifest).report
    }

    /// Returns loadable installation evidence only after every pinned artifact
    /// has been hashed in this process and is unchanged since. Callers must not
    /// infer readiness from directory, filename, or byte-count checks of their own.
    public func verifiedInstallation(
        _ manifest: ModelManifest,
        forceHash: Bool = false
    ) async -> VerifiedInstallation? {
        if !forceHash, fingerprintIsCurrent(manifest) { return evidence(for: manifest) }
        return await inspect(manifest).report.isComplete ? evidence(for: manifest) : nil
    }

    /// Whether the files still match the ones last hashed clean. No file is read.
    public func fingerprintIsCurrent(_ manifest: ModelManifest) -> Bool {
        guard let expected = verifiedFingerprints[Self.key(for: manifest)] else { return false }
        return Self.fingerprints(of: manifest, at: directory(for: manifest)) == expected
    }

    /// Ensures the model is installed and verified, downloading whatever is
    /// missing or corrupted. Returns the model directory, ready to load.
    /// Every downloaded file is hashed before it replaces anything on disk.
    @discardableResult
    public func ensureAvailable(
        _ manifest: ModelManifest,
        progress: (@Sendable (InstallEvent) -> Void)? = nil
    ) async throws -> URL {
        let base = directory(for: manifest)
        progress?(.verifying)
        if await verifiedInstallation(manifest) != nil { return base }
        try Task.checkCancellation()

        // Nil means a stalled holder or no `flock`: installing anyway is safe,
        // because every published file is hashed first.
        let lock = try await acquireInstallLock(for: manifest, progress: progress)
        defer { withExtendedLifetime(lock) {} }
        let report = await inspect(manifest).report
        if report.isComplete { return base }
        try Task.checkCancellation()
        try await install(report, of: manifest, lock: lock, progress: progress)
        return base
    }

    public func remove(_ manifest: ModelManifest) throws {
        let base = directory(for: manifest)
        verifiedFingerprints[Self.key(for: manifest)] = nil
        if FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.removeItem(at: base)
        }
    }

    // MARK: - Internals

    private func evidence(for manifest: ModelManifest) -> VerifiedInstallation {
        VerifiedInstallation(
            manifestID: manifest.id,
            manifestRevision: manifest.revision,
            directory: directory(for: manifest),
            artifactBytes: Int64(manifest.totalSizeBytes))
    }

    private static func key(for manifest: ModelManifest) -> String {
        "\(manifest.id)@\(manifest.revision)"
    }

    private func installLockURL(for manifest: ModelManifest) -> URL {
        rootDirectory.appendingPathComponent("locks/\(Self.key(for: manifest)).lock")
    }

    private func acquireInstallLock(
        for manifest: ModelManifest,
        progress: (@Sendable (InstallEvent) -> Void)?
    ) async throws -> FileLock? {
        let url = installLockURL(for: manifest)
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
                announced = true
                lastReport = report
                lastChange = clock.now
                let snapshot = report.flatMap { try? JSONDecoder().decode(ProgressReport.self, from: $0) }
                progress?(.waitingForOtherProcess(
                    completedBytes: snapshot?.completedBytes ?? 0,
                    totalBytes: snapshot?.totalBytes ?? manifest.totalSizeBytes))
            }
            if clock.now - lastChange >= waitPolicy.stallTimeout { return nil }
            try await Task.sleep(for: waitPolicy.pollInterval)
        }
    }

    private func inspect(_ manifest: ModelManifest) async -> Inspection {
        fullInspectionCount += 1
        let base = directory(for: manifest)
        let task = Task.detached(priority: .utility) { Self.inspectFiles(of: manifest, at: base) }
        let inspection = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        verifiedFingerprints[Self.key(for: manifest)] = inspection.fingerprints
        return inspection
    }

    nonisolated private static func inspectFiles(of manifest: ModelManifest, at base: URL) -> Inspection {
        var missing: [String] = []
        var corrupted: [String] = []
        var before: [FileFingerprint] = []
        for artifact in manifest.artifacts {
            let url = base.appendingPathComponent(artifact.path)
            switch FileFingerprint.read(url) {
            case .missing:
                missing.append(artifact.path)
            case .irregular:
                corrupted.append(artifact.path)
            case .regular(let fingerprint):
                before.append(fingerprint)
                if (try? sha256(of: url)) != artifact.sha256 { corrupted.append(artifact.path) }
            }
        }
        let report = VerificationReport(missing: missing, corrupted: corrupted)
        let stable = report.isComplete && fingerprints(of: manifest, at: base) == before
        return Inspection(report: report, fingerprints: stable ? before : nil)
    }

    nonisolated private static func fingerprints(of manifest: ModelManifest, at base: URL) -> [FileFingerprint]? {
        var result: [FileFingerprint] = []
        for artifact in manifest.artifacts {
            guard case .regular(let fingerprint) = FileFingerprint.read(base.appendingPathComponent(artifact.path))
            else { return nil }
            result.append(fingerprint)
        }
        return result
    }

    private func install(
        _ report: VerificationReport,
        of manifest: ModelManifest,
        lock: FileLock?,
        progress: (@Sendable (InstallEvent) -> Void)?
    ) async throws {
        let base = directory(for: manifest)
        let pending = Set(report.missing + report.corrupted)
        let toFetch = manifest.artifacts.filter { pending.contains($0.path) }
        let totalBytes = toFetch.reduce(0) { $0 + $1.sizeBytes }
        var completedBytes = 0

        StagingDirectory.sweep(root: rootDirectory)
        let staging = try Self.storingResult("staging") { try StagingDirectory(root: rootDirectory) }
        defer { staging.remove() }

        for artifact in toFetch {
            let completed = completedBytes
            let onBytes: @Sendable (Int) -> Void = { written in
                let state = DownloadProgress(
                    completedBytes: completed + written, totalBytes: totalBytes, currentPath: artifact.path)
                progress?(.downloading(state))
                lock?.write(ProgressReport(completedBytes: state.completedBytes, totalBytes: totalBytes).encoded)
            }
            onBytes(0)
            try await fetch(artifact, of: manifest, into: base, staging: staging.url, onBytes: onBytes)
            completedBytes += artifact.sizeBytes
        }
        progress?(.downloading(DownloadProgress(completedBytes: totalBytes, totalBytes: totalBytes, currentPath: "")))

        // Paranoia pass: everything the manifest lists must now hash clean.
        let final = await inspect(manifest).report
        guard final.isComplete else {
            throw LocalModelStoreError.notInstalled(missing: final.missing, corrupted: final.corrupted)
        }
    }

    private func fetch(
        _ artifact: ModelArtifact,
        of manifest: ModelManifest,
        into base: URL,
        staging: URL,
        onBytes: @escaping @Sendable (Int) -> Void
    ) async throws {
        let source = manifest.downloadURL(for: artifact)
        let destination = base.appendingPathComponent(artifact.path)

        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(
                from: source, delegate: DownloadObserver(onBytes: onBytes))
        } catch {
            // URLSession also writes its temporary download to disk.
            if Self.isOutOfSpace(error as NSError) { throw LocalModelStoreError.outOfSpace(path: artifact.path) }
            throw LocalModelStoreError.downloadFailed(
                path: artifact.path, underlying: String(describing: error))
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LocalModelStoreError.downloadFailed(path: artifact.path, underlying: "HTTP \(http.statusCode)")
        }

        try Task.checkCancellation()
        let staged = staging.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try Self.storing(artifact.path) {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try FileManager.default.moveItem(at: temporary, to: staged)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.copyItem(at: temporary, to: staged)
            }
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? Int) ?? -1
        guard size == artifact.sizeBytes else {
            throw LocalModelStoreError.sizeMismatch(
                path: artifact.path, expected: artifact.sizeBytes, actual: size)
        }

        let digest = try await Task.detached(priority: .utility) { try Self.sha256(of: staged) }.value
        guard digest == artifact.sha256 else {
            throw LocalModelStoreError.checksumMismatch(
                path: artifact.path, expected: artifact.sha256, actual: digest)
        }

        // The verified file is on the destination volume, so publication is one
        // atomic rename or replace, and a failed repair preserves the old file.
        try Task.checkCancellation()
        try Self.storing(artifact.path) { try Self.publish(staged, at: destination) }
    }

    private static func publish(_ staged: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    /// Local writes report a full disk as `outOfSpace`; every other error passes through.
    static func storing(_ path: String, _ write: () throws -> Void) throws {
        try storingResult(path, write)
    }

    private static func storingResult<Result>(_ path: String, _ write: () throws -> Result) throws -> Result {
        do {
            return try write()
        } catch where isOutOfSpace(error as NSError) {
            throw LocalModelStoreError.outOfSpace(path: path)
        }
    }

    /// Whether a disk-full or quota cause appears anywhere in the error's cause chain.
    public static func isOutOfSpace(_ error: NSError) -> Bool {
        if case .outOfSpace = error as? LocalModelStoreError { return true }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(ENOSPC) || error.code == Int(EDQUOT) {
            return true
        }
        var causes = (error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError]) ?? []
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { causes.append(underlying) }
        return causes.contains { isOutOfSpace($0) }
    }

    /// Streaming SHA-256 (1 MiB reads) so a 445 MB weight file never has to
    /// fit in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What a lock holder publishes for waiters. Advisory: a torn read only delays
/// the next update.
private struct ProgressReport: Codable {
    let completedBytes: Int
    let totalBytes: Int

    var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

/// Forwards byte counts so waiters can tell a slow download from a stalled one.
private final class DownloadObserver: NSObject, URLSessionDownloadDelegate, Sendable {
    private let onBytes: @Sendable (Int) -> Void

    init(onBytes: @escaping @Sendable (Int) -> Void) {
        self.onBytes = onBytes
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onBytes(Int(totalBytesWritten))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
