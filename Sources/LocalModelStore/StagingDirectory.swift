import Foundation

/// A unique work directory. Its `.owner` lock lives as long as the writer, so a
/// sweep can tell abandoned work from live work with no age heuristic.
final class StagingDirectory {
    let url: URL
    private let ownerFile: URL
    private let owner: FileLock

    init(root: URL) throws {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let name = UUID().uuidString
        ownerFile = staging.appendingPathComponent("\(name).owner")
        url = staging.appendingPathComponent(name, isDirectory: true)
        // The lock exists before the directory, so a sweep never sees it unowned.
        switch try FileLock.tryExclusive(at: ownerFile) {
        case .acquired(let lock): owner = lock
        case .busy, .unsupported:
            throw CocoaError(.fileLocking)
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
        let remaining = Set(entries)
        for entry in entries where !entry.hasSuffix(".owner") && !remaining.contains("\(entry).owner") {
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(entry, isDirectory: true))
        }
    }
}
