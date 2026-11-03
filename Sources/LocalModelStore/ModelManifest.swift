import CryptoKit
import Foundation

/// One file inside a model distribution. CoreML models ship as `.mlmodelc`
/// bundles (directories of weights + compiled program), so a model is a
/// *set* of artifacts, each pinned individually.
public struct ModelArtifact: Codable, Sendable, Hashable {
    /// Path relative to the model's install directory (e.g.
    /// `Encoder.mlmodelc/weights/weight.bin`).
    public let path: String
    /// SHA-256 of the file contents, lowercase hex. Checked on download and on
    /// every store verification; a model file is code we execute.
    public let sha256: String
    public let sizeBytes: Int

    public init(path: String, sha256: String, sizeBytes: Int) {
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

extension ModelArtifact {
    /// A relative path with no `..`, `.` or empty component, which stays inside the
    /// directory it is joined to.
    var hasSafePath: Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

private extension Character {
    var isLowercaseHex: Bool { isHexDigit && !isUppercase }
}

/// An entry in the curated model registry. Every artifact is verified
/// against its pinned `sha256`, and `resolveBase` is pinned to an exact
/// upstream revision — never a moving branch.
public struct ModelManifest: Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    /// Base URL each artifact path is resolved against. For Hugging Face
    /// this is `…/resolve/<commit-sha>` so the download can never drift.
    public let resolveBase: URL
    /// Upstream revision the artifacts were pinned at (informational; the
    /// binding pin is `resolveBase` + per-artifact sha256).
    public let revision: String
    public let artifacts: [ModelArtifact]
    public let minimumRAMGB: Int
    public let license: String

    public init(
        id: String,
        displayName: String,
        resolveBase: URL,
        revision: String,
        artifacts: [ModelArtifact],
        minimumRAMGB: Int,
        license: String
    ) {
        self.id = id
        self.displayName = displayName
        self.resolveBase = resolveBase
        self.revision = revision
        self.artifacts = artifacts
        self.minimumRAMGB = minimumRAMGB
        self.license = license
    }

    /// Saturates, because manifests read from disk are untrusted and an overflow would trap.
    public var totalSizeBytes: Int {
        artifacts.reduce(0) { total, artifact in
            let (sum, overflow) = total.addingReportingOverflow(max(artifact.sizeBytes, 0))
            return overflow ? .max : sum
        }
    }

    /// SHA-256 over the artifact list, sorted by bytes so every client agrees. Two
    /// manifests with the same ID and revision can pin different files, because a
    /// revision is only informational.
    public var digest: String {
        let lines = artifacts
            .map { Array("\($0.path)\u{0}\($0.sha256)\u{0}\($0.sizeBytes)\n".utf8) }
            .sorted { $0.lexicographicallyPrecedes($1) }
            .flatMap { $0 }
        return SHA256.hash(data: lines).map { String(format: "%02x", $0) }.joined()
    }

    /// The directory name of an install: readable, and separate for each revision
    /// and each set of pinned files. See `docs/FORMAT.md`.
    var storeKey: String {
        "\(id)@\(revision.prefix(12))-\(digest.prefix(12))"
    }

    /// Rejects anything that could reach outside a model's directory or collide on
    /// a case-insensitive volume. A reusable package cannot assume reviewed manifests.
    func validate() throws {
        func reject(_ reason: String) -> LocalModelStore.LocalModelStoreError {
            .invalidManifest(id: id, reason: reason)
        }
        guard Self.isSafeName(id, allowingUppercase: false) else { throw reject("id") }
        guard Self.isSafeName(revision, allowingUppercase: true) else { throw reject("revision") }
        // An empty list would verify as installed with nothing on disk.
        guard !artifacts.isEmpty else { throw reject("no artifacts") }
        // Past this, space checks would overflow. No model is close to it.
        guard totalSizeBytes < Int.max / 2 else { throw reject("total size") }
        var seen = Set<String>()
        for artifact in artifacts {
            guard artifact.hasSafePath else { throw reject("path \(artifact.path)") }
            guard seen.insert(artifact.path.lowercased()).inserted else { throw reject("duplicate \(artifact.path)") }
            guard artifact.sizeBytes >= 0 else { throw reject("size of \(artifact.path)") }
            guard artifact.sha256.count == 64, artifact.sha256.allSatisfy(\.isLowercaseHex) else {
                throw reject("hash of \(artifact.path)")
            }
        }
        try validateParents(listedPaths: seen)
    }

    private func validateParents(listedPaths: Set<String>) throws {
        var spellings: [String: String] = [:]
        for artifact in artifacts {
            var parent = (artifact.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                let folded = parent.lowercased()
                guard !listedPaths.contains(folded) else {
                    throw LocalModelStore.LocalModelStoreError.invalidManifest(
                        id: id, reason: "file and directory at \(parent)")
                }
                // On a case-insensitive volume, A/x and a/y land in one directory.
                guard spellings[folded, default: parent] == parent else {
                    throw LocalModelStore.LocalModelStoreError.invalidManifest(id: id, reason: "case of \(parent)")
                }
                spellings[folded] = parent
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }

    private static func isSafeName(_ name: String, allowingUppercase: Bool) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.count <= 128 else { return false }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                return allowingUppercase
            default:
                return false
            }
        }
    }

    /// Identifies verification evidence. It includes the digest, because evidence
    /// for one set of pins says nothing about another.
    var evidenceKey: String {
        "\(id)@\(revision)-\(digest)"
    }

    public func downloadURL(for artifact: ModelArtifact) -> URL {
        resolveBase.appendingPathComponent(artifact.path)
    }
}
