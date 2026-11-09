import Foundation

extension LocalModelStore {
    /// Claims an existing verified installation without downloading or repairing it.
    /// Call only after this app's own consent. Returns nil when the model is missing,
    /// damaged or still being installed for the first time. Throws `busy` when this app
    /// has no active claim yet and another process holds the install lock.
    /// A claim keeps idle bytes; a loader still needs a lease while they are resident.
    public func claimInstalled(_ manifest: ModelManifest) async throws -> VerifiedInstallation? {
        try manifest.validate()
        try Task.checkCancellation()
        let key = manifest.storeKey
        guard FileManager.default.fileExists(atPath: layout.model(key).path) else { return nil }
        // Hashed before the lock, so a long hash never makes another caller busy.
        guard let installation = await verifiedInstallation(manifest) else {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()
        if claims.isActive(key, consumer: consumer) {
            claims.touch(key, consumer: consumer)
            return installation
        }

        let lockURL = layout.installLock(key)
        let lock = try Self.storingResult(lockURL.lastPathComponent) { try FileLock.tryExclusive(at: lockURL) }
        defer { withExtendedLifetime(lock) {} }
        if case .busy = lock { throw LocalModelStoreError.busy(id: manifest.id) }
        // No suspension while locked: the bytes only need to be unchanged since the hash.
        guard fingerprintIsCurrent(manifest) else { return nil }
        try Self.storing("claim") { try claims.write(manifest, consumer: consumer) }
        return installation
    }
}
