import Darwin
import Foundation

/// File operations behind an install. They hold no state, and nothing here decides
/// whether bytes are good: every placed file is hashed by the store afterward.
enum ModelInstaller {
    enum Placement: Equatable {
        case placed
        case unavailable
    }

    enum Publication: Equatable {
        case published
        case alreadyExists
    }

    typealias CloneFunction = (String, String) -> Int32

    /// Clones a regular file, or copies it where cloning is unavailable, as on
    /// another volume. A symlink is never followed.
    static func place(
        from source: URL,
        to destination: URL,
        clone: CloneFunction = { clonefile($0, $1, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) }
    ) throws -> Placement {
        guard case .regular = FileFingerprint.read(source) else { return .unavailable }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if clone(source.path, destination.path) == 0 { return .placed }
        let cloneFailure = errno
        try throwIfOutOfSpace(cloneFailure)
        guard cloneFailure == ENOTSUP || cloneFailure == EXDEV else { return .unavailable }
        if copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_NOFOLLOW)) == 0 {
            return .placed
        }
        let copyFailure = errno
        try? FileManager.default.removeItem(at: destination)
        try throwIfOutOfSpace(copyFailure)
        return .unavailable
    }

    private static func throwIfOutOfSpace(_ code: Int32) throws {
        if code == ENOSPC || code == EDQUOT { throw POSIXError(.init(rawValue: code) ?? .ENOSPC) }
    }

    /// Makes files read-only and flushes them, so a crash right after the commit
    /// point cannot publish an install whose bytes never reached the disk.
    static func seal(_ directory: URL) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            throw CocoaError(.fileReadUnknown)
        }
        var directories = [directory]
        for case let url as URL in walker {
            if try url.resourceValues(forKeys: Set(keys)).isDirectory == true {
                directories.append(url)
            } else {
                guard chmod(url.path, 0o444) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                flush(url)
            }
        }
        for url in directories.reversed() {
            guard chmod(url.path, 0o755) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            flush(url)
        }
    }

    private static func flush(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        // Not every volume has a barrier; the hash at first use still covers it.
        _ = fcntl(descriptor, F_BARRIERFSYNC)
    }

    /// The commit point. `RENAME_EXCL` makes a second publisher lose instead of
    /// replacing a model that another process may be loading.
    static func publish(_ source: URL, as destination: URL) throws -> Publication {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return .published }
        switch errno {
        case EEXIST, ENOTEMPTY:
            return .alreadyExists
        case ENOTSUP, EINVAL:
            // Plain `rename` fails on a non-empty target, so it still cannot replace a model.
            if rename(source.path, destination.path) == 0 { return .published }
            if errno == EEXIST || errno == ENOTEMPTY { return .alreadyExists }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        default:
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    /// Replaces a damaged model in one step, leaving the old one at `source` to delete.
    /// A process with the old model loaded keeps running from its compiled copy.
    static func replace(_ destination: URL, with source: URL, trash: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_SWAP)) == 0 { return }
        switch errno {
        case ENOENT:
            _ = try publish(source, as: destination)
        case ENOTSUP, EINVAL:
            // No atomic swap on this volume: readers may briefly see no model, never a mix.
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let old = trash.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.moveItem(at: destination, to: old)
            _ = try publish(source, as: destination)
            try? FileManager.default.removeItem(at: old)
        default:
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}
