import Darwin
import Foundation

/// Identity of one file at the moment it was hashed. Kept in memory only, so
/// editing a file cannot forge it, and any edit changes `ctime`.
struct FileFingerprint: Equatable, Sendable {
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    enum Reading: Equatable, Sendable {
        case regular(FileFingerprint)
        case directory(FileFingerprint)
        case missing
        /// A symlink or other entry a manifest never describes.
        case irregular
    }

    static func read(_ url: URL) -> Reading {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .irregular
        }
        let fingerprint = FileFingerprint(
            inode: info.st_ino,
            size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec,
            changedNanoseconds: info.st_ctimespec.tv_nsec)
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regular(fingerprint)
        case S_IFDIR: return .directory(fingerprint)
        default: return .irregular
        }
    }
}
