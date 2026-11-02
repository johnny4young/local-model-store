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
    /// another volume. No symlink is followed, at the source or on the way to it.
    static func place(
        from root: URL,
        path: String,
        to destination: URL,
        clone: CloneFunction = { clonefile($0, $1, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) }
    ) throws -> Placement {
        let source = root.appendingPathComponent(path)
        guard hasRealParents(path, under: root), case .regular = FileFingerprint.read(source) else {
            return .unavailable
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if clone(source.path, destination.path) != 0 {
            let cloneFailure = errno
            try throwIfOutOfSpace(cloneFailure)
            guard cloneFailure == ENOTSUP || cloneFailure == EXDEV else { return .unavailable }
            guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_NOFOLLOW)) == 0
            else {
                let copyFailure = errno
                try? FileManager.default.removeItem(at: destination)
                try throwIfOutOfSpace(copyFailure)
                return .unavailable
            }
        }
        // The source can change after the check above, and a cloned symlink must
        // never reach the hash or the seal, which would act on its target.
        guard case .regular = FileFingerprint.read(destination) else {
            try? FileManager.default.removeItem(at: destination)
            return .unavailable
        }
        return .placed
    }

    /// Whether every directory between `root` and `path` is a real directory.
    /// `root` itself may be a symlink, as when a whole store lives on another disk.
    private static func hasRealParents(_ path: String, under root: URL) -> Bool {
        var current = root
        for component in path.split(separator: "/").dropLast() {
            current.appendPathComponent(String(component))
            guard case .directory = FileFingerprint.read(current) else { return false }
        }
        return true
    }

    private static func throwIfOutOfSpace(_ code: Int32) throws {
        if code == ENOSPC || code == EDQUOT { throw POSIXError(.init(rawValue: code) ?? .ENOSPC) }
    }

    /// Makes files read-only and flushes them, so a crash right after the commit
    /// point cannot publish an install whose bytes never reached the disk.
    static func seal(_ directory: URL, flush: (URL) throws -> Void = ModelInstaller.flush) throws {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        var directories = [directory]
        for case let url as URL in walker {
            switch FileFingerprint.read(url) {
            case .directory:
                directories.append(url)
            case .regular:
                try setPermissions(0o444, of: url)
                try flush(url)
            case .irregular, .missing:
                throw CocoaError(.fileReadUnknown)
            }
        }
        for url in directories.reversed() {
            try setPermissions(0o755, of: url)
            try flush(url)
        }
    }

    private static func setPermissions(_ mode: mode_t, of url: URL) throws {
        guard fchmodat(AT_FDCWD, url.path, mode, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    /// A failed flush fails the install: valid bytes in the cache prove nothing about
    /// the disk. A volume with no barrier gets a plain `fsync` instead.
    static func flush(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        if fcntl(descriptor, F_BARRIERFSYNC) == 0 { return }
        let failure = errno
        guard failure == ENOTSUP || failure == EINVAL || failure == ENOTTY else {
            throw POSIXError(.init(rawValue: failure) ?? .EIO)
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
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
