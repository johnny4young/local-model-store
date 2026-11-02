import Foundation

/// A unique work directory. Its `.owner` lock lives as long as the writer, so a
/// sweep can tell abandoned work from live work with no age heuristic.
final class StagingDirectory {
    let url: URL
    private let ownerFile: URL
    /// Nil on a volume with no `flock`: the work is simply never swept.
    private let owner: FileLock?

    init(root: URL, acquire: (URL) throws -> FileLock.Attempt = FileLock.tryExclusive(at:)) throws {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let name = UUID().uuidString
        ownerFile = staging.appendingPathComponent("\(name).owner")
        url = staging.appendingPathComponent(name, isDirectory: true)
        // The lock exists before the directory, so a sweep never sees it unowned.
        switch try acquire(ownerFile) {
        case .acquired(let lock): owner = lock
        case .unsupported: owner = nil
        case .busy: throw CocoaError(.fileLocking)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: ownerFile)
    }

    /// Removes work whose writer is gone. Directories without an owner file are
    /// leftovers from an interrupted removal.
    static func sweep(root: URL) {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        for entry in entries where entry.hasSuffix(".owner") {
            let file = staging.appendingPathComponent(entry)
            guard case .acquired(let lock)? = try? FileLock.tryExclusive(at: file) else { continue }
            let name = String(entry.dropLast(".owner".count))
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(name, isDirectory: true))
            try? FileManager.default.removeItem(at: file)
            withExtendedLifetime(lock) {}
        }
        // Checked now, not from the listing: an owner file always exists before its
        // directory, but a listing can return the directory and miss the file.
        for entry in entries where !entry.hasSuffix(".owner") {
            guard !FileManager.default.fileExists(atPath: staging.appendingPathComponent("\(entry).owner").path)
            else { continue }
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(entry, isDirectory: true))
        }
    }
}
