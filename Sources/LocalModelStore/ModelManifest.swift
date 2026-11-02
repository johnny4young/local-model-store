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

/// An entry in the curated model registry. Every artifact is verified
/// against its pinned `sha256`, and `resolveBase` is pinned to an exact
/// upstream revision — never a moving branch.
public struct ModelManifest: Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    /// Directory name on disk.
    public let folderName: String
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
        folderName: String,
        resolveBase: URL,
        revision: String,
        artifacts: [ModelArtifact],
        minimumRAMGB: Int,
        license: String
    ) {
        self.id = id
        self.displayName = displayName
        self.folderName = folderName
        self.resolveBase = resolveBase
        self.revision = revision
        self.artifacts = artifacts
        self.minimumRAMGB = minimumRAMGB
        self.license = license
    }

    public var totalSizeBytes: Int {
        artifacts.reduce(0) { $0 + $1.sizeBytes }
    }

    public func downloadURL(for artifact: ModelArtifact) -> URL {
        resolveBase.appendingPathComponent(artifact.path)
    }
}
