import Darwin
import Foundation

/// One consumer's declaration that it needs a model. Claims are declarative rather
/// than counted, because a crash or a drag to the Trash would leak a count. On disk
/// they are hints between cooperating apps, and decoding ignores unknown keys. A file
/// that does not decode still protects the model: deleting another app's bytes
/// because of a format difference is worse than keeping them.
struct ModelClaim: Codable, Equatable, Sendable {
    let consumer: String
    let displayName: String
    let firstClaimedAt: Date
    var lastUsedAt: Date
    /// When this consumer stopped pinning the model. It still protects the model
    /// for the grace period, so rolling back does not download again.
    var retiredAt: Date?
}

/// Reads and writes claim files for one store.
struct ClaimStore: Sendable {
    static let retiredGrace: TimeInterval = 14 * 24 * 60 * 60
    private static let touchInterval: TimeInterval = 24 * 60 * 60

    let layout: StoreLayout
    let now: @Sendable () -> Date

    /// Whether this consumer has a claim that is not retired. A retired one goes
    /// through the slow path, which restores it.
    func isActive(_ key: String, consumer: StoreConsumer) -> Bool {
        guard let claim = read(file(key, consumer)) else { return false }
        return claim.retiredAt == nil
    }

    func all(_ key: String) -> [ModelClaim] {
        let directory = layout.claims.appendingPathComponent(key, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted()
            .filter { $0.hasSuffix(".json") }
            .map { name in
                read(directory.appendingPathComponent(name)) ?? Self.unreadable(name: name, at: now())
            }
    }

    private static func unreadable(name: String, at date: Date) -> ModelClaim {
        let bundleID = String(name.dropLast(".json".count))
        return ModelClaim(
            consumer: bundleID, displayName: bundleID, firstClaimedAt: date, lastUsedAt: date, retiredAt: nil)
    }

    /// Claims that still protect a model.
    func live(_ key: String) -> [ModelClaim] {
        all(key).filter { claim in
            guard let retired = claim.retiredAt else { return true }
            return now().timeIntervalSince(retired) < Self.retiredGrace
        }
    }

    func keys() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: layout.claims.path)) ?? []
    }

    /// Writes this consumer's claim, restoring a retired one. The caller holds the
    /// install lock. A failure is reported: without the claim, another app's
    /// removal could delete a model this app was just told it has.
    func write(_ manifest: ModelManifest, consumer: StoreConsumer) throws {
        let key = manifest.storeKey
        let existing = read(file(key, consumer))
        let date = now()
        try store(
            ModelClaim(
                consumer: consumer.bundleID,
                displayName: consumer.displayName,
                firstClaimedAt: existing?.firstClaimedAt ?? date,
                lastUsedAt: date,
                retiredAt: nil),
            key: key,
            consumer: consumer)
    }

    /// Refreshes `lastUsedAt` at most once a day, so loads stay free of writes. Best
    /// effort: a lost refresh changes nothing that matters.
    func touch(_ key: String, consumer: StoreConsumer) {
        guard var claim = read(file(key, consumer)),
              now().timeIntervalSince(claim.lastUsedAt) >= Self.touchInterval else { return }
        claim.lastUsedAt = now()
        try? store(claim, key: key, consumer: consumer)
    }

    func isRetired(_ key: String, consumer: StoreConsumer) -> Bool {
        read(file(key, consumer))?.retiredAt != nil
    }

    /// Restoring a claim needs the install lock, or a collection that already read
    /// the old expiry could delete the restored file.
    func setRetired(_ retired: Bool, key: String, consumer: StoreConsumer) throws {
        guard var claim = read(file(key, consumer)), (claim.retiredAt != nil) != retired else { return }
        claim.retiredAt = retired ? now() : nil
        try store(claim, key: key, consumer: consumer)
    }

    func drop(_ key: String, consumer: StoreConsumer) {
        try? FileManager.default.removeItem(at: file(key, consumer))
        signalChange()
    }

    func dropAll(_ key: String) {
        try? FileManager.default.removeItem(at: layout.claims.appendingPathComponent(key, isDirectory: true))
        signalChange()
    }

    func dropExpired(_ key: String) {
        let directory = layout.claims.appendingPathComponent(key, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let retired = read(url)?.retiredAt,
                  now().timeIntervalSince(retired) >= Self.retiredGrace else { continue }
            try? FileManager.default.removeItem(at: url)
            signalChange()
        }
    }

    private func file(_ key: String, _ consumer: StoreConsumer) -> URL {
        layout.claim(key, bundleID: consumer.bundleID)
    }

    private func read(_ url: URL) -> ModelClaim? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ModelClaim.self, from: data)
    }

    private func store(_ claim: ModelClaim, key: String, consumer: StoreConsumer) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let url = file(key, consumer)
        let data = try encoder.encode(claim)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        signalChange()
    }

    /// A new file in a key's directory does not touch `claims/` itself, which is
    /// the directory `changes()` watches.
    private func signalChange() {
        _ = utimes(layout.claims.path, nil)
    }
}
