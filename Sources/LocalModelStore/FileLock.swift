import Darwin
import Foundation

/// A `flock` on one file. The kernel releases it when the process dies, so a
/// crash needs no recovery. The file is never deleted: unlinking a lock file
/// lets two holders exist at once.
package final class FileLock: Sendable {
    package enum Attempt {
        case acquired(FileLock)
        case busy
        /// The volume has no `flock`, as on some network homes.
        case unsupported
    }

    package let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// `O_EXLOCK` takes the lock atomically with the open, so a sweep can never
    /// lock a new file before its writer. `O_CLOEXEC` keeps a spawned child from
    /// holding the lock after this process dies.
    package static func tryExclusive(at url: URL) throws -> Attempt {
        try attempt(at: url, mode: O_EXLOCK)
    }

    /// Many readers can hold this together, and it keeps an exclusive holder out.
    package static func tryShared(at url: URL) throws -> Attempt {
        try attempt(at: url, mode: O_SHLOCK)
    }

    private static func attempt(at url: URL, mode: Int32) throws -> Attempt {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | mode | O_NONBLOCK, 0o600)
        if descriptor >= 0 { return .acquired(FileLock(descriptor: descriptor)) }
        let failure = errno
        switch failure {
        case EWOULDBLOCK: return .busy
        case ENOTSUP, EOPNOTSUPP: return .unsupported
        default: throw POSIXError(.init(rawValue: failure) ?? .EIO)
        }
    }

    /// Replaces the file's contents, which are advisory and read by waiters.
    /// Writing first leaves no moment when a waiter sees an empty file mid-update.
    package func write(_ data: Data) {
        let written = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        if written == data.count { ftruncate(descriptor, off_t(data.count)) }
    }
}
