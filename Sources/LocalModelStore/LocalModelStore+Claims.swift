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
        /// Models that could not be deleted this time, such as for permissions.
        public let failed: [String]
    }

    private var claims: ClaimStore { ClaimStore(layout: layout, now: now) }

    /// Keeps a model on disk while it is resident. Call `release()` when it unloads;
    /// dropping the last reference and crashing also release it.
    public final class ModelLease: Sendable {
        public let directory: URL
        /// False on a volume with no `flock`, where only claims protect a model.
        public var isProtected: Bool { lock != nil }
        private let lock: FileLock?

        init(directory: URL, lock: FileLock?) {
            self.directory = directory
            self.lock = lock
        }

        public func release() {
            lock?.unlock()
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
            switch try waitPolicy.useLockAttempt?(url) ?? FileLock.tryShared(at: url) {
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
        defer { withExtendedLifetime(lock) {} }
        switch scope {
        case .thisConsumer: claims.drop(key, consumer: consumer)
        case .allConsumers: claims.dropAll(key)
        }
        if case .busy = lock { return .deferred }
        let remaining = claims.live(key)
        guard remaining.isEmpty else { return .keptForOthers(remaining.map(\.displayName)) }
        // The user asked for this, so a volume that cannot show leases does not stop it.
        guard case .retired(let doomed) = try retire(key, ifUseIsUnknown: true) else { return .deferred }
        let partial = retirePartial(key)
        lock.release()
        await deleteBytes(doomed)
        await deleteBytes(partial)
        return .removed
    }

    private enum Retirement {
        case inUse
        case retired(doomed: URL?)
    }

    /// Takes a model away from readers and drops its claims in one step. The caller
    /// holds the install lock and releases it before deleting the bytes: a slow delete
    /// holding the lock would read as a stall, and a waiter's new install could lose
    /// its claim to a cleanup that ran later.
    private func retire(_ key: String, ifUseIsUnknown proceed: Bool) throws -> Retirement {
        let model = layout.model(key)
        guard FileManager.default.fileExists(atPath: model.path) else {
            claims.dropAll(key)
            return .retired(doomed: nil)
        }
        let url = layout.useLock(key)
        let use = try waitPolicy.useLockAttempt?(url) ?? FileLock.tryExclusive(at: url)
        switch use {
        case .busy: return .inUse
        case .unsupported where !proceed: return .inUse
        case .acquired, .unsupported: break
        }
        try FileManager.default.createDirectory(at: layout.trash, withIntermediateDirectories: true)
        let doomed = layout.trash.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: model, to: doomed)
        claims.dropAll(key)
        withExtendedLifetime(use) {}
        return .retired(doomed: doomed)
    }

    /// Renamed away under the lock, like a model, so deleting it never holds the lock.
    private func retirePartial(_ key: String) -> URL? {
        let partial = layout.partial(key)
        guard layout.partialsAreReal, FileFingerprint.read(partial) != .missing else { return nil }
        let doomed = layout.trash.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: layout.trash, withIntermediateDirectories: true)
        guard (try? FileManager.default.moveItem(at: partial, to: doomed)) != nil else { return nil }
        return doomed
    }

    private func deleteBytes(_ doomed: URL?) async {
        guard let doomed else { return }
        await Self.offActor { try? FileManager.default.removeItem(at: doomed) }
    }

    /// Marks this app's claims outside `manifests` as retired after an update re-pins
    /// them. A retired claim keeps protecting its model for 14 days, so a rollback
    /// downloads nothing, and claims that come back are restored.
    public func reconcileClaims(keeping manifests: [ModelManifest]) throws {
        for manifest in manifests { try manifest.validate() }
        let kept = Set(manifests.map(\.storeKey))
        for key in claims.keys() {
            guard kept.contains(key) else {
                try claims.setRetired(true, key: key, consumer: consumer)
                continue
            }
            guard claims.isRetired(key, consumer: consumer) else { continue }
            let lock = try FileLock.tryExclusive(at: layout.installLock(key))
            // Left retired if busy: the next `ensureAvailable` restores it under the lock.
            if case .busy = lock { continue }
            try claims.setRetired(false, key: key, consumer: consumer)
            withExtendedLifetime(lock) {}
        }
    }

    /// Deletes models nobody claims or uses, retired claims past their grace, kept
    /// downloads past theirs, and work abandoned in staging and trash. A model being
    /// installed or leased stays.
    public func collectGarbage() async throws -> GarbageReport {
        guard FileManager.default.fileExists(atPath: layout.version.path) else {
            return GarbageReport(removed: [], inUse: [], failed: [])
        }
        var removed: [String] = []
        var inUse: [String] = []
        var failed: [String] = []
        for key in modelKeys() {
            // One stuck model must not block cleanup of the rest.
            do {
                let lock = try FileLock.tryExclusive(at: layout.installLock(key))
                defer { withExtendedLifetime(lock) {} }
                if case .busy = lock {
                    inUse.append(key)
                    continue
                }
                claims.dropExpired(key)
                guard claims.live(key).isEmpty else { continue }
                // Nobody asked for this one, so without proof of no readers it stays.
                guard case .retired(let doomed) = try retire(key, ifUseIsUnknown: false) else {
                    inUse.append(key)
                    continue
                }
                let partial = retirePartial(key)
                lock.release()
                await deleteBytes(doomed)
                await deleteBytes(partial)
                removed.append(key)
            } catch {
                failed.append(key)
            }
        }
        dropClaimsOfMissingModels()
        await collectPartials()
        await emptyTrashAndStaging()
        return GarbageReport(removed: removed, inUse: inUse, failed: failed)
    }

    /// By age alone: an install claims only after it succeeds, so a claim says nothing
    /// about kept files. An unknown lock proceeds, because the grace already outlasts any attempt.
    private func collectPartials() async {
        guard layout.partialsAreReal else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.partials.path)) ?? []
        for key in names {
            guard let lock = try? FileLock.tryExclusive(at: layout.installLock(key)) else { continue }
            if case .busy = lock { continue }
            // Read under the lock, because an install refreshes the time while holding it.
            let path = layout.partial(key).path
            guard let touched = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now().timeIntervalSince(touched) >= ClaimStore.retiredGrace else { continue }
            let doomed = retirePartial(key)
            lock.release()
            await deleteBytes(doomed)
        }
    }

    /// Under each key's lock, so a claim from an install that just finished survives.
    private func dropClaimsOfMissingModels() {
        for key in claims.keys() {
            guard !FileManager.default.fileExists(atPath: layout.model(key).path),
                  let lock = try? FileLock.tryExclusive(at: layout.installLock(key)) else { continue }
            if case .busy = lock { continue }
            guard !FileManager.default.fileExists(atPath: layout.model(key).path) else { continue }
            claims.dropAll(key)
            withExtendedLifetime(lock) {}
        }
    }

    private func emptyTrashAndStaging() async {
        let version = layout.version
        let trash = layout.trash
        let layout = layout
        await Self.offActor {
            StagingDirectory.sweep(root: version)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [] {
                // `<key>~<uuid>` is an old copy kept for a reader. It goes once the lease ends.
                let key = name.split(separator: "~").first.map(String.init)
                if name.contains("~"), let key,
                   case .busy? = try? FileLock.tryExclusive(at: layout.useLock(key)) { continue }
                try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
            }
        }
    }

    /// Reads no model bytes. Manifests on disk are hints, good enough for a list.
    public func inventory() -> [InventoryEntry] {
        modelKeys().map { key in
            let file = layout.model(key).appendingPathComponent("manifest.json")
            let manifest = (try? Data(contentsOf: file))
                .flatMap { try? JSONDecoder().decode(ModelManifest.self, from: $0) }
            let live = claims.live(key)
            // Two lists refreshing together can see each other here for a moment, and
            // the next refresh corrects it.
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
