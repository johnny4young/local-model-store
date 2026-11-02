import Foundation

/// Every path in a store. `docs/FORMAT.md` is the contract for this layout.
struct StoreLayout: Sendable {
    let root: URL

    var version: URL { root.appendingPathComponent(StoreFormat.directoryName, isDirectory: true) }
    var models: URL { version.appendingPathComponent("models", isDirectory: true) }
    var trash: URL { version.appendingPathComponent("trash", isDirectory: true) }

    func model(_ key: String) -> URL { models.appendingPathComponent(key, isDirectory: true) }
    func payload(_ key: String) -> URL { model(key).appendingPathComponent("payload", isDirectory: true) }
    func installLock(_ key: String) -> URL { version.appendingPathComponent("locks/\(key).lock") }

    /// Creates the root on first write. Read paths never call this, so inspecting a
    /// store leaves nothing behind.
    func prepare() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: root.path) {
            try manager.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.createDirectory(at: models, withIntermediateDirectories: true)

        // Models are pinned and can be downloaded again, so they stay out of backups.
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var rootURL = root
        try rootURL.setResourceValues(excluded)

        let marker = root.appendingPathComponent("store.json")
        if !manager.fileExists(atPath: marker.path) {
            try Data(#"{"format":\#(StoreFormat.version)}"#.utf8).write(to: marker, options: .atomic)
        }
    }
}
