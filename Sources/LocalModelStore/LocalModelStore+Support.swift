import CryptoKit
import Foundation

extension LocalModelStore {
    public enum LocalModelStoreError: Error, LocalizedError {
        case checksumMismatch(path: String, expected: String, actual: String)
        case sizeMismatch(path: String, expected: Int, actual: Int)
        case downloadFailed(path: String, underlying: String)
        /// The disk or quota was full while downloading, staging or publishing.
        case outOfSpace(path: String)
        case notInstalled(missing: [String], corrupted: [String])
        case invalidManifest(id: String, reason: String)
        /// A sandboxed process asked for the shared store, which it cannot reach.
        case sandboxed
        case invalidConsumer(bundleID: String)
        /// Another process is installing or removing this model right now.
        case busy(id: String)

        public var errorDescription: String? {
            switch self {
            case .checksumMismatch(let path, let expected, let actual):
                return "sha256 mismatch for \(path): expected \(expected), got \(actual)"
            case .sizeMismatch(let path, let expected, let actual):
                return "size mismatch for \(path): expected \(expected) bytes, got \(actual)"
            case .downloadFailed(let path, let underlying):
                return "download failed for \(path): \(underlying)"
            case .outOfSpace(let path):
                return "not enough disk space to save \(path)"
            case .notInstalled(let missing, let corrupted):
                return "model not installed (missing: \(missing.count), corrupted: \(corrupted.count))"
            case .invalidManifest(let id, let reason):
                return "invalid manifest \(id): \(reason)"
            case .sandboxed:
                return "a sandboxed process cannot use the shared model store"
            case .invalidConsumer(let bundleID):
                return "invalid consumer bundle ID: \(bundleID)"
            case .busy(let id):
                return "model \(id) is being installed or removed"
            }
        }
    }

    /// Result of checking an installed model against its manifest.
    public struct VerificationReport: Sendable {
        public let missing: [String]
        public let corrupted: [String]
        public var isComplete: Bool { missing.isEmpty && corrupted.isEmpty }
    }

    /// A directory that passed the complete pinned manifest, not merely a
    /// path that happens to contain one expected filename.
    public struct VerifiedInstallation: Equatable, Sendable {
        public let manifestID: String
        public let manifestRevision: String
        public let directory: URL
        public let artifactBytes: Int64

        init(
            manifestID: String,
            manifestRevision: String,
            directory: URL,
            artifactBytes: Int64
        ) {
            self.manifestID = manifestID
            self.manifestRevision = manifestRevision
            self.directory = directory
            self.artifactBytes = artifactBytes
        }
    }

    public struct DownloadProgress: Equatable, Sendable {
        public let completedBytes: Int
        public let totalBytes: Int
        public let currentPath: String
        public var fraction: Double {
            totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0
        }
    }

    /// A checksum pass or a wait is never reported as a download.
    public enum InstallEvent: Equatable, Sendable {
        case verifying
        case waitingForOtherProcess(completedBytes: Int, totalBytes: Int)
        case downloading(DownloadProgress)
    }

    /// How a waiter behaves while another process holds the install lock.
    package struct WaitPolicy: Sendable {
        package var pollInterval: Duration = .milliseconds(100)
        /// A holder that reports no progress for this long is raced, never robbed:
        /// the waiter installs on its own, and the worst outcome is wasted bytes.
        package var stallTimeout: Duration = .seconds(120)
        /// How long a lease waits for a deletion in progress.
        package var leaseTimeout: Duration = .seconds(5)
        /// Runs before a repair replaces a damaged install, for tests of that race.
        package var beforeRepair: (@Sendable () -> Void)?
        /// Runs right after the commit point, for tests that crash there.
        package var afterPublish: (@Sendable () -> Void)?
        /// Replaces taking the use lock, for tests of a volume with no `flock`.
        package var useLockAttempt: (@Sendable (URL) throws -> FileLock.Attempt)?

        package init() {}
    }

    struct Inspection: Sendable {
        let report: VerificationReport
        /// Present only when every file hashed clean and stayed unchanged meanwhile.
        let fingerprints: [FileFingerprint]?
    }

    /// A file that changes while it is hashed does not count as verified: the open
    /// handle would keep reading a deleted or replaced file to a clean result.
    static func inspectFiles(
        of manifest: ModelManifest,
        at base: URL,
        afterHashing: () -> Void = {}
    ) -> Inspection {
        var missing: [String] = []
        var corrupted: [String] = []
        var hashed: [(artifact: ModelArtifact, fingerprint: FileFingerprint)] = []
        for artifact in manifest.artifacts {
            let url = base.appendingPathComponent(artifact.path)
            switch FileFingerprint.read(url) {
            case .missing:
                missing.append(artifact.path)
            case .irregular, .directory:
                corrupted.append(artifact.path)
            case .regular(let fingerprint):
                if fingerprint.size == Int64(artifact.sizeBytes), (try? sha256(of: url)) == artifact.sha256 {
                    hashed.append((artifact, fingerprint))
                } else {
                    corrupted.append(artifact.path)
                }
            }
        }
        afterHashing()
        for (artifact, fingerprint) in hashed {
            switch FileFingerprint.read(base.appendingPathComponent(artifact.path)) {
            case .regular(fingerprint): continue
            case .missing: missing.append(artifact.path)
            case .regular, .irregular, .directory: corrupted.append(artifact.path)
            }
        }
        // Read before the fence, so an entry added after it still changes a directory's fingerprint.
        let directories = directoryFingerprints(of: manifest, at: base)
        corrupted += unlistedEntries(of: manifest, at: base)
        let report = VerificationReport(missing: missing, corrupted: corrupted)
        guard report.isComplete, let directories else { return Inspection(report: report, fingerprints: nil) }
        return Inspection(report: report, fingerprints: hashed.map(\.fingerprint) + directories)
    }

    /// Files and directories in a fixed order. Directories catch what file identity
    /// cannot: an added entry, or a symlink swapped in for a parent.
    static func fingerprints(of manifest: ModelManifest, at base: URL) -> [FileFingerprint]? {
        var result: [FileFingerprint] = []
        for artifact in manifest.artifacts {
            guard case .regular(let fingerprint) = FileFingerprint.read(base.appendingPathComponent(artifact.path))
            else { return nil }
            result.append(fingerprint)
        }
        guard let directories = directoryFingerprints(of: manifest, at: base) else { return nil }
        return result + directories
    }

    private static func parentDirectories(of manifest: ModelManifest) -> Set<String> {
        var directories = Set<String>()
        for artifact in manifest.artifacts {
            var parent = (artifact.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                directories.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return directories
    }

    private static func directoryFingerprints(of manifest: ModelManifest, at base: URL) -> [FileFingerprint]? {
        var result: [FileFingerprint] = []
        for path in [""] + parentDirectories(of: manifest).sorted() {
            let url = path.isEmpty ? base : base.appendingPathComponent(path)
            guard case .directory(let fingerprint) = FileFingerprint.read(url) else { return nil }
            result.append(fingerprint)
        }
        return result
    }

    /// Loaders receive the whole directory, so anything the manifest does not list
    /// makes it unverified, including a symlink in place of a directory. Names are
    /// compared normalized, because some volumes decompose them.
    private static func unlistedEntries(of manifest: ModelManifest, at base: URL) -> [String] {
        let directories = Set(parentDirectories(of: manifest).map(\.precomposedStringWithCanonicalMapping))
        let listed = Set(manifest.artifacts.map(\.path.precomposedStringWithCanonicalMapping))
        let (entries, unreadable) = listEntries(under: base)
        return unreadable + entries.filter { path in
            let name = path.precomposedStringWithCanonicalMapping
            if listed.contains(name) { return false }
            let reading = FileFingerprint.read(base.appendingPathComponent(path))
            if directories.contains(name), case .directory = reading { return false }
            if (name as NSString).lastPathComponent == ".DS_Store", case .regular = reading { return false }
            return true
        }
    }

    /// Every entry below `base`, without following symlinks. A directory that cannot
    /// be read is reported, because it could hide anything.
    private static func listEntries(under base: URL) -> (entries: [String], unreadable: [String]) {
        var entries: [String] = []
        var unreadable: [String] = []
        var pending = [""]
        while let relative = pending.popLast() {
            let directory = relative.isEmpty ? base : base.appendingPathComponent(relative)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
                if !relative.isEmpty || FileFingerprint.read(base) != .missing {
                    unreadable.append(relative.isEmpty ? "." : relative)
                }
                continue
            }
            for name in names {
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                entries.append(path)
                if case .directory = FileFingerprint.read(base.appendingPathComponent(path)) {
                    pending.append(path)
                }
            }
        }
        return (entries, unreadable)
    }

    /// Hashing takes seconds, so it runs away from the actor and stops when the
    /// caller is cancelled.
    static func offActor<Value: Sendable>(
        _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        let task = Task.detached(priority: .utility, operation: work)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Local writes report a full disk as `outOfSpace`; every other error passes through.
    static func storing(_ path: String, _ write: () throws -> Void) throws {
        try storingResult(path, write)
    }

    static func storingResult<Result>(_ path: String, _ write: () throws -> Result) throws -> Result {
        do {
            return try write()
        } catch where isOutOfSpace(error as NSError) {
            throw LocalModelStoreError.outOfSpace(path: path)
        }
    }

    /// Whether a disk-full or quota cause appears anywhere in the error's cause chain.
    public static func isOutOfSpace(_ error: NSError) -> Bool {
        if case .outOfSpace = error as? LocalModelStoreError { return true }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(ENOSPC) || error.code == Int(EDQUOT) {
            return true
        }
        var causes = (error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError]) ?? []
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { causes.append(underlying) }
        return causes.contains { isOutOfSpace($0) }
    }

    /// Streaming SHA-256 (1 MiB reads) so a 445 MB weight file never has to
    /// fit in memory.
    package static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var reading = true
        while reading {
            try Task.checkCancellation()
            // Each read returns an autoreleased buffer, and no pool drains inside this loop.
            reading = try autoreleasepool {
                guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { return false }
                hasher.update(data: data)
                return true
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
