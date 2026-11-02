import Foundation

extension LocalModelStore {
    /// Who a removal applies to.
    public enum RemovalScope: Sendable {
        case thisConsumer
        /// Also drops other apps' claims. They download again on next use, after
        /// asking for their own consent.
        case allConsumers
    }

    public enum RemovalOutcome: Equatable, Sendable {
        case removed
        /// This app's claim is gone, and the bytes stay for these apps.
        case keptForOthers([String])
        /// This app's claim is gone, and a running process still uses the model or
        /// is installing it. `collectGarbage()` finishes the job later.
        case deferred
    }

    /// One row of a disk-usage list. Sizes are logical bytes, which match what a
    /// download costs. Physical numbers mislead because clones share blocks.
    public struct InventoryEntry: Equatable, Sendable {
        public let key: String
        public let id: String?
        public let displayName: String?
        public let logicalBytes: Int?
        public let claimants: [String]
        public let isClaimedByThisConsumer: Bool
        public let isInUse: Bool
    }

    public struct GarbageReport: Equatable, Sendable {
        public let removed: [String]
        public let inUse: [String]
    }

    private var claims: ClaimStore { ClaimStore(layout: layout, now: now) }

    /// Keeps a model on disk for as long as this value lives. Keep it while the model
    /// is resident. A crash releases it, because the kernel owns the lock.
    public final class ModelLease: Sendable {
        public let directory: URL
        private let lock: FileLock?

        init(directory: URL, lock: FileLock?) {
            self.directory = directory
            self.lock = lock
        }
    }

    /// Takes the lease before verifying, so the model cannot be deleted between the
    /// check and the load. Presence is not consent: callers decide whether to use a model.
    public func lease(_ manifest: ModelManifest) async throws -> ModelLease {
        let base = try directory(for: manifest)
        let key = manifest.storeKey
        guard FileManager.default.fileExists(atPath: layout.model(key).path) else {
            throw LocalModelStoreError.notInstalled(missing: manifest.artifacts.map(\.path), corrupted: [])
        }
        let lock = try await acquireUseLock(for: manifest)
        guard await verifiedInstallation(manifest) != nil else {
            let report = await verify(manifest)
            throw LocalModelStoreError.notInstalled(missing: report.missing, corrupted: report.corrupted)
        }
        claims.touch(key, consumer: consumer)
        return ModelLease(directory: base, lock: lock)
    }

    private func acquireUseLock(for manifest: ModelManifest) async throws -> FileLock? {
        let url = layout.useLock(manifest.storeKey)
        let deadline = ContinuousClock.now + waitPolicy.leaseTimeout
        while true {
            switch try FileLock.tryShared(at: url) {
            case .acquired(let lock): return lock
            case .unsupported: return nil
            case .busy:
                // A deleter holds this only for one rename.
                guard ContinuousClock.now < deadline else { throw LocalModelStoreError.busy(id: manifest.id) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Drops this app's claim, and deletes the bytes only if no other app claims them
    /// and no process has them leased.
    @discardableResult
    public func remove(_ manifest: ModelManifest, scope: RemovalScope = .thisConsumer) async throws -> RemovalOutcome {
        try manifest.validate()
        let key = manifest.storeKey
        verifiedFingerprints[manifest.evidenceKey] = nil
        guard FileManager.default.fileExists(atPath: layout.version.path) else { return .removed }

        let lock = try FileLock.tryExclusive(at: layout.installLock(key))
        switch scope {
        case .thisConsumer: claims.drop(key, consumer: consumer)
        case .allConsumers: claims.dropAll(key)
        }
        if case .busy = lock { return .deferred }
        let remaining = claims.live(key)
        guard remaining.isEmpty else { return .keptForOthers(remaining.map(\.displayName)) }
        let deleted = try await deleteIfUnused(key)
        withExtendedLifetime(lock) {}
        return deleted ? .removed : .deferred
    }

    /// The caller holds the install lock. Returns false when a process has it leased.
    private func deleteIfUnused(_ key: String) async throws -> Bool {
        let model = layout.model(key)
        guard FileManager.default.fileExists(atPath: model.path) else { return true }
        let use = try FileLock.tryExclusive(at: layout.useLock(key))
        if case .busy = use { return false }
        // One rename takes the model away from readers; deleting it can then take its time.
        try FileManager.default.createDirectory(at: layout.trash, withIntermediateDirectories: true)
        let doomed = layout.trash.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: model, to: doomed)
        withExtendedLifetime(use) {}
        await Self.offActor { try? FileManager.default.removeItem(at: doomed) }
        return true
    }

    /// Marks this app's claims outside `manifests` as retired after an update re-pins
    /// them. A retired claim keeps protecting its model for 14 days, so a rollback
    /// downloads nothing, and claims that come back are restored.
    public func reconcileClaims(keeping manifests: [ModelManifest]) throws {
        for manifest in manifests { try manifest.validate() }
        let kept = Set(manifests.map(\.storeKey))
        for key in claims.keys() {
            claims.setRetired(!kept.contains(key), key: key, consumer: consumer)
        }
    }

    /// Deletes models nobody claims or uses, retired claims past their grace, and
    /// work abandoned in staging and trash. A model being installed or leased stays.
    public func collectGarbage() async throws -> GarbageReport {
        guard FileManager.default.fileExists(atPath: layout.version.path) else {
            return GarbageReport(removed: [], inUse: [])
        }
        var removed: [String] = []
        var inUse: [String] = []
        for key in modelKeys() {
            let lock = try FileLock.tryExclusive(at: layout.installLock(key))
            if case .busy = lock {
                inUse.append(key)
                continue
            }
            claims.dropExpired(key)
            guard claims.live(key).isEmpty else { continue }
            if try await deleteIfUnused(key) {
                claims.dropAll(key)
                removed.append(key)
            } else {
                inUse.append(key)
            }
            withExtendedLifetime(lock) {}
        }
        let modelsLeft = Set(modelKeys())
        for key in claims.keys() where !modelsLeft.contains(key) { claims.dropAll(key) }
        let version = layout.version
        let trash = layout.trash
        await Self.offActor {
            StagingDirectory.sweep(root: version)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [] {
                try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
            }
        }
        return GarbageReport(removed: removed, inUse: inUse)
    }

    /// Reads no model bytes. Manifests on disk are hints, good enough for a list.
    public func inventory() throws -> [InventoryEntry] {
        modelKeys().map { key in
            let file = layout.model(key).appendingPathComponent("manifest.json")
            let manifest = (try? Data(contentsOf: file))
                .flatMap { try? JSONDecoder().decode(ModelManifest.self, from: $0) }
            let live = claims.live(key)
            var isInUse = false
            if case .busy? = try? FileLock.tryExclusive(at: layout.useLock(key)) { isInUse = true }
            return InventoryEntry(
                key: key,
                id: manifest?.id,
                displayName: manifest?.displayName,
                logicalBytes: manifest?.totalSizeBytes,
                claimants: live.map(\.displayName),
                isClaimedByThisConsumer: live.contains { $0.consumer == consumer.bundleID },
                isInUse: isInUse)
        }
    }

    /// Only real directories count: a symlink in `models/` is never a model, and
    /// nothing here deletes through it.
    private func modelKeys() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.models.path)) ?? []
        return names.sorted().filter { name in
            if case .directory = FileFingerprint.read(layout.models.appendingPathComponent(name)) { return true }
            return false
        }
    }

    /// Fires when models or claims change in any process. Use it to refresh readiness
    /// flags, with no polling. Events are coalesced and carry nothing, so read state after each.
    nonisolated public func changes() -> AsyncStream<Void> {
        let layout = layout
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let watcher = StoreWatcher(layout: layout) { continuation.yield() }
            watcher.start()
            continuation.onTermination = { _ in watcher.stop() }
        }
    }
}
