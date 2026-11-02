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

    /// `O_CLOEXEC` keeps a spawned child from holding the lock after this process dies.
    package static func tryExclusive(at url: URL) throws -> Attempt {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            return .acquired(FileLock(descriptor: descriptor))
        }
        let failure = errno
        close(descriptor)
        switch failure {
        case EWOULDBLOCK: return .busy
        case ENOTSUP, EOPNOTSUPP: return .unsupported
        default: throw POSIXError(.init(rawValue: failure) ?? .EIO)
        }
    }

    /// Replaces the file's contents, which are advisory and read by waiters.
    package func write(_ data: Data) {
        guard ftruncate(descriptor, 0) == 0 else { return }
        _ = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    }
}
