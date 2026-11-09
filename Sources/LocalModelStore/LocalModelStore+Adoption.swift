import Foundation

extension LocalModelStore {
    /// Claims an existing verified installation without downloading or repairing it.
    /// Call only after this app's own consent. Returns nil when the model is missing
    /// or damaged, and throws `busy` when another process is installing or removing it.
    /// A claim keeps idle bytes; a loader still needs a lease while they are resident.
    public func claimInstalled(_ manifest: ModelManifest) async throws -> VerifiedInstallation? {
        _ = try directory(for: manifest)
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: layout.model(manifest.storeKey).path) else { return nil }

        let lockURL = layout.installLock(manifest.storeKey)
        let lock = try Self.storingResult(lockURL.lastPathComponent) { try FileLock.tryExclusive(at: lockURL) }
        defer { withExtendedLifetime(lock) {} }
        if case .busy = lock { throw LocalModelStoreError.busy(id: manifest.id) }
        guard let installation = await verifiedInstallation(manifest) else {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()
        if claims.isActive(manifest.storeKey, consumer: consumer) {
            claims.touch(manifest.storeKey, consumer: consumer)
        } else {
            try Self.storing("claim") { try claims.write(manifest, consumer: consumer) }
        }
        return installation
    }
}
