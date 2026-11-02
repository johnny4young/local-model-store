import Foundation
@testable import LocalModelStore
import Testing

private func manifest(
    id: String = "fixture",
    revision: String = "rev1",
    artifacts: [ModelArtifact] = [ModelArtifact(path: "a.bin", sha256: String(repeating: "a", count: 64), sizeBytes: 1)]
) throws -> ModelManifest {
    ModelManifest(
        id: id, displayName: "Fixture", resolveBase: try #require(URL(string: "https://fixture.invalid")),
        revision: revision, artifacts: artifacts, minimumRAMGB: 0, license: "MIT")
}

struct KeyTests {
    @Test func theDigestIsAPublishedFormatAndIgnoresArtifactOrder() throws {
        let first = ModelArtifact(path: "b.bin", sha256: String(repeating: "b", count: 64), sizeBytes: 2)
        let second = ModelArtifact(path: "a.bin", sha256: String(repeating: "a", count: 64), sizeBytes: 1)
        let one = try manifest(artifacts: [first, second])
        let other = try manifest(artifacts: [second, first])
        #expect(one.digest == other.digest)
        // Computed outside Swift: every client in every language must derive this value.
        #expect(one.digest == "8959c738d48d2d9e7090b9854612d5b01129f2332e247304faa010e212b66854")
    }

    @Test func theKeyTruncatesTheRevisionAndKeepsTheDigestApart() throws {
        let long = try manifest(revision: "0123456789abcdef")
        #expect(long.storeKey == "fixture@0123456789ab-\(long.digest.prefix(12))")
        let repinned = try manifest(
            revision: "0123456789abcdef",
            artifacts: [ModelArtifact(path: "a.bin", sha256: String(repeating: "c", count: 64), sizeBytes: 1)])
        #expect(long.storeKey != repinned.storeKey)
    }
}

struct ValidationTests {
    private static let sha = String(repeating: "a", count: 64)

    @Test(arguments: ["", ".", "..", "a/b", "../x", "Upper", "a b", String(repeating: "x", count: 129)])
    func unsafeIDsAreRejected(id: String) throws {
        #expect(throws: LocalModelStore.LocalModelStoreError.self) { try manifest(id: id).validate() }
    }

    @Test(arguments: ["", ".", "..", "a/b", "a b"])
    func unsafeRevisionsAreRejected(revision: String) throws {
        #expect(throws: LocalModelStore.LocalModelStoreError.self) { try manifest(revision: revision).validate() }
    }

    @Test(arguments: ["", "/etc/passwd", "../x", "a/../../x", "a//b", "./a", "a/.", "a/", "a\u{0}b"])
    func unsafePathsAreRejected(path: String) throws {
        let artifact = ModelArtifact(path: path, sha256: Self.sha, sizeBytes: 1)
        #expect(throws: LocalModelStore.LocalModelStoreError.self) { try manifest(artifacts: [artifact]).validate() }
    }

    @Test(arguments: [String(repeating: "A", count: 64), String(repeating: "a", count: 63), String(repeating: "g", count: 64)])
    func malformedHashesAreRejected(sha: String) throws {
        let artifact = ModelArtifact(path: "a.bin", sha256: sha, sizeBytes: 1)
        #expect(throws: LocalModelStore.LocalModelStoreError.self) { try manifest(artifacts: [artifact]).validate() }
    }

    @Test func pathsThatCollideOnACaseInsensitiveVolumeAreRejected() throws {
        let artifacts = ["A.bin", "a.bin"].map { ModelArtifact(path: $0, sha256: Self.sha, sizeBytes: 1) }
        #expect(throws: LocalModelStore.LocalModelStoreError.self) { try manifest(artifacts: artifacts).validate() }
    }

    @Test func anEvilManifestWritesNothingAndVerifiesNothing() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let evil = try manifest(artifacts: [ModelArtifact(path: "../../escape", sha256: Self.sha, sizeBytes: 1)])
        let store = try scratch.store()
        await #expect(throws: LocalModelStore.LocalModelStoreError.self) { try await store.ensureAvailable(evil) }
        #expect(await store.verifiedInstallation(evil) == nil)
        #expect(await store.verify(evil).isComplete == false)
        await #expect(throws: LocalModelStore.LocalModelStoreError.self) { try await store.remove(evil) }
        #expect(!FileManager.default.fileExists(atPath: scratch.storeRoot.path))
    }
}

struct LocationTests {
    @Test func theSharedLocationIsThePermanentPathAndIsNeverCreatedByResolving() throws {
        let root = try StoreLocation.userLibrary.resolvedRoot(environment: [:])
        #expect(root.path.hasSuffix("/Library/Application Support/com.johnny4young.local-models"))
    }

    @Test func aSandboxedProcessFailsInsteadOfCreatingAPrivateStore() throws {
        #expect(throws: LocalModelStore.LocalModelStoreError.self) {
            try StoreLocation.userLibrary.resolvedRoot(environment: ["APP_SANDBOX_CONTAINER_ID": "x"])
        }
        let explicit = URL(fileURLWithPath: "/tmp/x")
        #expect(try StoreLocation.directory(explicit).resolvedRoot(environment: ["APP_SANDBOX_CONTAINER_ID": "x"]) == explicit)
    }
}

struct LayoutTests {
    @Test func anInstallProducesTheDocumentedLayout() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store()
        let directory = try await store.ensureAvailable(scratch.manifest)
        let root = scratch.storeRoot
        let key = scratch.manifest.storeKey

        #expect(directory.path == root.path + "/v1.noindex/models/\(key)/payload")
        #expect(try permissions(of: root) == 0o700)
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let marker = try Data(contentsOf: root.appendingPathComponent("store.json"))
        #expect(String(decoding: marker, as: UTF8.self) == #"{"format":1}"#)

        let model = directory.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: model.path).sorted() == ["manifest.json", "payload"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["vocab.json", "weights.bin"])
        #expect(try permissions(of: directory.appendingPathComponent("weights.bin")) == 0o444)
        #expect(try permissions(of: directory) == 0o755)
        #expect(scratch.stagingEntries().isEmpty)
    }

    @Test func readingAStoreLeavesNothingBehind() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store()
        #expect(await store.verify(scratch.manifest).isComplete == false)
        #expect(await store.verifiedInstallation(scratch.manifest) == nil)
        #expect(!FileManager.default.fileExists(atPath: scratch.storeRoot.path))
    }

    @Test func anUnknownMarkerOrNewerFormatDoesNotBlockThisOne() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let newer = scratch.storeRoot.appendingPathComponent("v2.noindex/models/keep", isDirectory: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: scratch.storeRoot.appendingPathComponent("store.json"))

        let store = try scratch.store()
        try await store.ensureAvailable(scratch.manifest)

        #expect(await store.verify(scratch.manifest).isComplete)
        #expect(FileManager.default.fileExists(atPath: newer.path), "another format's tree is never touched")
    }

    @Test func notEnoughSpaceFailsBeforeAnyDownload() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try LocalModelStore(
            location: .directory(scratch.storeRoot), consumer: .test, session: scratch.localSession(),
            waitPolicy: .init(), availableCapacity: { _ in 1024 })
        do {
            try await store.ensureAvailable(scratch.manifest)
            Issue.record("The install must not start without room")
        } catch let error as LocalModelStore.LocalModelStoreError {
            guard case .outOfSpace = error else {
                Issue.record("Expected outOfSpace, got \(error)")
                return
            }
        }
        #expect(scratch.requests.isEmpty)
        #expect(scratch.stagingEntries().isEmpty)
    }

    private func permissions(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }
}

struct LocalReuseTests {
    private func seed(from scratch: Scratch) throws -> URL {
        let seed = scratch.root.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.copyItem(at: scratch.upstream, to: seed)
        return seed
    }

    @Test func aSeedInstallsWithoutDownloadingAndStaysUntouched() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let seed = try seed(from: scratch)
        try Data("litter".utf8).write(to: seed.appendingPathComponent(".weights.bin.download-1"))
        let before = try FileManager.default.subpathsOfDirectory(atPath: seed.path).sorted()
        let weights = seed.appendingPathComponent("weights.bin")
        let original = try LocalModelStore.sha256(of: weights)

        let store = try scratch.store()
        let directory = try await store.ensureAvailable(scratch.manifest, seeds: [seed])

        #expect(scratch.requests.isEmpty)
        #expect(await store.verify(scratch.manifest).isComplete)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["vocab.json", "weights.bin"])
        #expect(try FileManager.default.subpathsOfDirectory(atPath: seed.path).sorted() == before)
        #expect(try LocalModelStore.sha256(of: weights) == original)
    }

    @Test func aBadSeedFileIsDownloadedInstead() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let seed = try seed(from: scratch)
        try Data("wrong".utf8).write(to: seed.appendingPathComponent("weights.bin"))

        let store = try scratch.store()
        try await store.ensureAvailable(scratch.manifest, seeds: [seed])

        #expect(scratch.requests == ["weights.bin"])
        #expect(await store.verify(scratch.manifest).isComplete)
    }

    @Test func aSymlinkInASeedIsNeverFollowed() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let seed = try seed(from: scratch)
        let weights = seed.appendingPathComponent("weights.bin")
        let elsewhere = scratch.root.appendingPathComponent("elsewhere.bin")
        try FileManager.default.moveItem(at: weights, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: weights, withDestinationURL: elsewhere)

        let store = try scratch.store()
        try await store.ensureAvailable(scratch.manifest, seeds: [seed])

        #expect(scratch.requests == ["weights.bin"])
    }

    @Test func aRepinKeepsBothInstallsAndDownloadsOnlyWhatChanged() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store()
        let oldDirectory = try await store.ensureAvailable(scratch.manifest)

        let changed = scratch.upstream.appendingPathComponent("vocab.json")
        try Data(repeating: 0x33, count: 4096).write(to: changed)
        let old = scratch.manifest
        let repinned = ModelManifest(
            id: old.id, displayName: old.displayName, resolveBase: old.resolveBase, revision: "rev2",
            artifacts: [
                old.artifacts[0],
                ModelArtifact(path: "vocab.json", sha256: try LocalModelStore.sha256(of: changed), sizeBytes: 4096)
            ],
            minimumRAMGB: 0, license: "MIT")
        let requestsBefore = scratch.requests.count

        let newDirectory = try await store.ensureAvailable(repinned)

        #expect(Array(scratch.requests.dropFirst(requestsBefore)) == ["vocab.json"])
        #expect(newDirectory != oldDirectory)
        #expect(await store.verify(old).isComplete, "a re-pin never touches the old install")
        #expect(await store.verify(repinned).isComplete)
    }

    @Test func aHostileManifestOnDiskIsOnlyAHint() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        // A file outside the store, with the hash the real manifest wants.
        let secret = scratch.storeRoot.appendingPathComponent("secret.bin")
        try FileManager.default.createDirectory(at: scratch.storeRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: scratch.upstream.appendingPathComponent("weights.bin"), to: secret)
        let hostile = scratch.layout.model("hostile")
        try FileManager.default.createDirectory(at: hostile, withIntermediateDirectories: true)
        let wanted = scratch.manifest.artifacts[0]
        let evil = ModelManifest(
            id: "hostile", displayName: "x", resolveBase: scratch.manifest.resolveBase, revision: "x",
            artifacts: [ModelArtifact(path: "../../../../secret.bin", sha256: wanted.sha256, sizeBytes: wanted.sizeBytes)],
            minimumRAMGB: 0, license: "x")
        try JSONEncoder().encode(evil).write(to: hostile.appendingPathComponent("manifest.json"))
        let garbage = scratch.layout.model("garbage")
        try FileManager.default.createDirectory(at: garbage, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: garbage.appendingPathComponent("manifest.json"))

        let store = try scratch.store()
        try await store.ensureAvailable(scratch.manifest)

        #expect(scratch.requests.sorted() == ["vocab.json", "weights.bin"], "the path outside the store is refused")
    }
}

struct RepairTests {
    private func installed() async throws -> (Scratch, LocalModelStore, URL) {
        let scratch = try Scratch()
        let store = try scratch.store()
        return (scratch, store, try await store.ensureAvailable(scratch.manifest))
    }

    @Test func aRepairDownloadsOnlyTheBadFileAtTheSamePath() async throws {
        let (scratch, store, directory) = try await installed()
        defer { scratch.cleanUp() }
        try Data("bad".utf8).write(to: directory.appendingPathComponent("weights.bin"), options: .atomic)
        let before = scratch.requests.count

        let repaired = try await store.ensureAvailable(scratch.manifest)

        #expect(repaired == directory)
        #expect(Array(scratch.requests.dropFirst(before)) == ["weights.bin"])
        #expect(await store.verify(scratch.manifest).isComplete)
        #expect(scratch.stagingEntries().isEmpty)
    }

    @Test func anUnlistedFileMakesAnInstallUnverifiedUntilRepaired() async throws {
        let (scratch, store, directory) = try await installed()
        defer { scratch.cleanUp() }
        try Data("extra".utf8).write(to: directory.appendingPathComponent("extra.bin"))
        let before = scratch.requests.count

        #expect(await store.verify(scratch.manifest).corrupted == ["extra.bin"])
        try await store.ensureAvailable(scratch.manifest)

        #expect(scratch.requests.count == before, "every listed file was still good")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("extra.bin").path))
        #expect(await store.verify(scratch.manifest).isComplete)
    }

    @Test func finderMetadataIsNotDamage() async throws {
        let (scratch, store, directory) = try await installed()
        defer { scratch.cleanUp() }
        try Data().write(to: directory.appendingPathComponent(".DS_Store"))
        #expect(await store.verify(scratch.manifest).isComplete)
    }

    @Test func aSymlinkInPlaceOfADirectoryIsNotVerified() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let nestedSource = scratch.upstream.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSource, withIntermediateDirectories: true)
        let body = nestedSource.appendingPathComponent("file.bin")
        try Data(repeating: 1, count: 8).write(to: body)
        let manifest = ModelManifest(
            id: "nested", displayName: "x", resolveBase: scratch.manifest.resolveBase, revision: "x",
            artifacts: [ModelArtifact(path: "nested/file.bin", sha256: try LocalModelStore.sha256(of: body), sizeBytes: 8)],
            minimumRAMGB: 0, license: "x")
        let store = try scratch.store()
        let directory = try await store.ensureAvailable(manifest)

        let moved = scratch.root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: directory.appendingPathComponent("nested"), to: moved)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("nested"), withDestinationURL: moved)

        let report = await store.verify(manifest)
        #expect(report.corrupted.contains("nested"))
    }
}

struct InstallerTests {
    private func scratchFiles() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-model-store-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.bin")
        try Data("bytes".utf8).write(to: source)
        return (root, source, root.appendingPathComponent("out/destination.bin"))
    }

    @Test(arguments: [ENOTSUP, EXDEV])
    func cloningFallsBackToACopy(code: Int32) throws {
        let (root, source, destination) = try scratchFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try ModelInstaller.place(from: source, to: destination) { _, _ in
            errno = code
            return -1
        }
        #expect(result == .placed)
        #expect(try Data(contentsOf: destination) == Data("bytes".utf8))
    }

    @Test func anotherCloneFailureMeansTheSourceIsUnavailable() throws {
        let (root, source, destination) = try scratchFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try ModelInstaller.place(from: source, to: destination) { _, _ in
            errno = EACCES
            return -1
        }
        #expect(result == .unavailable)
    }

    @Test func aFullDiskIsNotMistakenForAnUnavailableSource() throws {
        let (root, source, destination) = try scratchFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: POSIXError.self) {
            try ModelInstaller.place(from: source, to: destination) { _, _ in
                errno = ENOSPC
                return -1
            }
        }
    }

    @Test func aRealCloneWorks() throws {
        let (root, source, destination) = try scratchFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try ModelInstaller.place(from: source, to: destination) == .placed)
        #expect(try Data(contentsOf: destination) == Data("bytes".utf8))
    }

    @Test func publishingNeverReplacesAModel() throws {
        let (root, _, _) = try scratchFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("new", isDirectory: true)
        let target = root.appendingPathComponent("final", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("file"))

        #expect(try ModelInstaller.publish(source, as: target) == .published)
        #expect(!FileManager.default.fileExists(atPath: source.path))

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        #expect(try ModelInstaller.publish(source, as: target) == .alreadyExists, "a non-empty target")

        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(try ModelInstaller.publish(source, as: empty) == .alreadyExists, "even an empty target")
    }

    @Test func replacingSwapsTheOldModelOutWhole() throws {
        let (root, _, _) = try scratchFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("new", isDirectory: true)
        let target = root.appendingPathComponent("final", isDirectory: true)
        for (directory, name) in [(source, "new"), (target, "old")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent(name))
        }
        try ModelInstaller.replace(target, with: source, trash: root.appendingPathComponent("trash"))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("new").path))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("old").path))
    }
}
