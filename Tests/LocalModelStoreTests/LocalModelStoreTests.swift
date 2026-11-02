import Foundation
@testable import LocalModelStore
import XCTest

extension StoreConsumer {
    static let test = StoreConsumer(bundleID: "com.example.test", displayName: "Test")
}

final class LocalModelStoreTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-model-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    func testStoreKeepsTheExplicitConsumer() {
        let store = LocalModelStore(rootDirectory: workspace, consumer: .test)
        XCTAssertEqual(store.consumer, .test)
    }

    func testSHA256MatchesKnownVector() throws {
        let file = workspace.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(
            try LocalModelStore.sha256(of: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// End-to-end offline: "downloads" from file:// URLs, verifies, installs.
    func testEnsureAvailableDownloadsAndVerifies() async throws {
        let (manifest, _) = try makeFixtureModel()
        let store = LocalModelStore(rootDirectory: workspace.appendingPathComponent("store"), consumer: .test)

        let directory = try await store.ensureAvailable(manifest)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("bundle.mlmodelc/weights/weight.bin").path))

        let report = await store.verify(manifest)
        XCTAssertTrue(report.isComplete)
        let installation = await store.verifiedInstallation(manifest)
        XCTAssertEqual(installation?.directory, directory)
        XCTAssertEqual(installation?.manifestRevision, manifest.revision)
        XCTAssertEqual(installation?.artifactBytes, Int64(manifest.totalSizeBytes))
    }

    func testVerifyDetectsMissingAndCorrupted() async throws {
        let (manifest, _) = try makeFixtureModel()
        let store = LocalModelStore(rootDirectory: workspace.appendingPathComponent("store"), consumer: .test)
        let directory = try await store.ensureAvailable(manifest)

        // Corrupt one file, delete another.
        try Data("tampered".utf8).write(
            to: directory.appendingPathComponent("bundle.mlmodelc/weights/weight.bin"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("vocab.json"))

        let report = await store.verify(manifest)
        XCTAssertEqual(report.corrupted, ["bundle.mlmodelc/weights/weight.bin"])
        XCTAssertEqual(report.missing, ["vocab.json"])
        XCTAssertFalse(report.isComplete)
        let corruptedInstallation = await store.verifiedInstallation(manifest)
        XCTAssertNil(corruptedInstallation)

        // A second ensureAvailable heals both.
        _ = try await store.ensureAvailable(manifest)
        let healed = await store.verify(manifest)
        XCTAssertTrue(healed.isComplete)
        let healedInstallation = await store.verifiedInstallation(manifest)
        XCTAssertNotNil(healedInstallation)
        let weightDirectory = directory
            .appendingPathComponent("bundle.mlmodelc/weights")
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: weightDirectory.path)
            .filter { $0.contains(".download-") }
        XCTAssertTrue(leftovers.isEmpty, "atomic repair must remove sibling staging files")
    }

    func testVerifiedLifecycleCachesOnlySuccessAndSupportsExplicitReverification() async throws {
        let (manifest, _) = try makeFixtureModel()
        let store = LocalModelStore(rootDirectory: workspace.appendingPathComponent("store"), consumer: .test)
        let lifecycle = VerifiedModelLifecycle(store: store)

        let missing = await lifecycle.installation(for: manifest)
        XCTAssertNil(missing)
        let installed = try await lifecycle.install(manifest)
        XCTAssertEqual(installed.manifestRevision, manifest.revision)

        let repeated = await lifecycle.installation(for: manifest)
        XCTAssertEqual(repeated, installed)
        let inspections = await store.fullInspectionCount
        let unchanged = await lifecycle.installation(for: manifest)
        XCTAssertEqual(unchanged, installed)
        let inspectionsAfter = await store.fullInspectionCount
        XCTAssertEqual(inspectionsAfter, inspections, "unchanged files must not be re-hashed")
        let forced = await lifecycle.installation(for: manifest, forceVerification: true)
        XCTAssertEqual(forced, installed)
        let inspectionsAfterForce = await store.fullInspectionCount
        XCTAssertEqual(inspectionsAfterForce, inspections + 1, "a forced check must hash the files again")

        try Data("tampered".utf8).write(
            to: installed.directory
                .appendingPathComponent("bundle.mlmodelc/weights/weight.bin"))
        let corrupted = await lifecycle.installation(for: manifest)
        XCTAssertNil(corrupted, "a changed file must drop process evidence without a forced check")

        let healed = try await lifecycle.install(manifest)
        XCTAssertEqual(healed.directory, installed.directory)
        try await lifecycle.remove(manifest)
        let removed = await lifecycle.installation(for: manifest)
        XCTAssertNil(removed)
    }

    func testVerifiedLifecycleDiscardsEvidenceSupersededByInvalidation() async throws {
        let (manifest, _) = try makeFixtureModel()
        let firstVerificationStarted = Gate()
        let releaseFirstVerification = Gate()
        let calls = CallCounter()
        let evidence = LocalModelStore.VerifiedInstallation(
            manifestID: manifest.id,
            manifestRevision: manifest.revision,
            directory: workspace.appendingPathComponent("verified"),
            artifactBytes: Int64(manifest.totalSizeBytes))
        let lifecycle = VerifiedModelLifecycle(
            verifyInstallation: { _ in
                let call = await calls.next()
                if call == 1 {
                    await firstVerificationStarted.open()
                    await releaseFirstVerification.wait()
                    return evidence
                }
                return nil
            },
            installModel: { _, _ in evidence },
            removeModel: { _ in })

        let request = Task {
            await lifecycle.installation(
                for: manifest,
                forceVerification: true)
        }
        await firstVerificationStarted.wait()
        await lifecycle.invalidate(manifest)
        await releaseFirstVerification.open()

        let current = await request.value
        XCTAssertNil(current, "a waiter must not receive superseded installation evidence")
        let callCount = await calls.value
        XCTAssertEqual(callCount, 2, "the waiter must re-check current state after invalidation")
    }

    func testVerifiedLifecycleForcedVerificationSupersedesAnOlderCheck() async throws {
        let (manifest, _) = try makeFixtureModel()
        let firstVerificationStarted = Gate()
        let secondVerificationStarted = Gate()
        let releaseFirstVerification = Gate()
        let releaseSecondVerification = Gate()
        let calls = CallCounter()
        let obsoleteEvidence = LocalModelStore.VerifiedInstallation(
            manifestID: manifest.id,
            manifestRevision: manifest.revision,
            directory: workspace.appendingPathComponent("obsolete"),
            artifactBytes: Int64(manifest.totalSizeBytes))
        let lifecycle = VerifiedModelLifecycle(
            verifyInstallation: { _ in
                let call = await calls.next()
                if call == 1 {
                    await firstVerificationStarted.open()
                    await releaseFirstVerification.wait()
                    return obsoleteEvidence
                }
                await secondVerificationStarted.open()
                await releaseSecondVerification.wait()
                return nil
            },
            installModel: { _, _ in obsoleteEvidence },
            removeModel: { _ in })

        let first = Task {
            await lifecycle.installation(
                for: manifest,
                forceVerification: true)
        }
        await firstVerificationStarted.wait()
        let second = Task {
            await lifecycle.installation(
                for: manifest,
                forceVerification: true)
        }
        await secondVerificationStarted.wait()
        await releaseFirstVerification.open()
        await releaseSecondVerification.open()

        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertNil(firstResult, "the original waiter must join the forced current check")
        XCTAssertNil(secondResult)
        let callCount = await calls.value
        XCTAssertGreaterThanOrEqual(callCount, 2)
        XCTAssertLessThanOrEqual(
            callCount,
            3,
            "a superseded waiter may perform one uncached confirmation after the current nil result")
    }

    func testVerifiedLifecycleSerializesInstallAndRemoveForOneManifest() async throws {
        let (manifest, _) = try makeFixtureModel()
        let installStarted = Gate()
        let releaseInstall = Gate()
        let events = Recorder()
        let evidence = LocalModelStore.VerifiedInstallation(
            manifestID: manifest.id,
            manifestRevision: manifest.revision,
            directory: workspace.appendingPathComponent("verified"),
            artifactBytes: Int64(manifest.totalSizeBytes))
        let lifecycle = VerifiedModelLifecycle(
            verifyInstallation: { _ in nil },
            installModel: { _, _ in
                await events.add("install-start")
                await installStarted.open()
                await releaseInstall.wait()
                await events.add("install-end")
                return evidence
            },
            removeModel: { _ in
                await events.add("remove")
            })

        let install = Task { try await lifecycle.install(manifest) }
        await installStarted.wait()
        let remove = Task { try await lifecycle.remove(manifest) }
        for _ in 0..<10 { await Task.yield() }
        let beforeRelease = await events.events
        XCTAssertEqual(beforeRelease, ["install-start"])

        await releaseInstall.open()
        _ = try await install.value
        try await remove.value

        let finalEvents = await events.events
        XCTAssertEqual(finalEvents, ["install-start", "install-end", "remove"])
        let current = await lifecycle.installation(for: manifest)
        XCTAssertNil(current, "the later removal must remain the current lifecycle truth")
    }

    func testVerifiedLifecycleReportsInstallThatCommittedAfterCancellation() async throws {
        let (manifest, _) = try makeFixtureModel()
        let installStarted = Gate()
        let releaseCommittedInstall = Gate()
        let evidence = LocalModelStore.VerifiedInstallation(
            manifestID: manifest.id,
            manifestRevision: manifest.revision,
            directory: workspace.appendingPathComponent("verified"),
            artifactBytes: Int64(manifest.totalSizeBytes))
        let lifecycle = VerifiedModelLifecycle(
            verifyInstallation: { _ in nil },
            installModel: { _, _ in
                await installStarted.open()
                await releaseCommittedInstall.wait()
                return evidence
            },
            removeModel: { _ in })

        let install = Task { try await lifecycle.install(manifest) }
        await installStarted.wait()
        install.cancel()
        await releaseCommittedInstall.open()

        let result = try await install.value
        XCTAssertEqual(result, evidence)
        let current = await lifecycle.installation(for: manifest)
        XCTAssertEqual(
            current,
            evidence,
            "late cancellation must not report failure after filesystem publication")
    }

    func testChecksumMismatchRejectsDownload() async throws {
        let (manifest, source) = try makeFixtureModel()
        // Attacker swaps the upstream file after we pinned its hash — same
        // byte count on purpose, so only the sha256 check can catch it.
        let original = try Data(contentsOf: source.appendingPathComponent("vocab.json"))
        try Data(repeating: UInt8(ascii: "x"), count: original.count).write(
            to: source.appendingPathComponent("vocab.json"))

        let store = LocalModelStore(rootDirectory: workspace.appendingPathComponent("store"), consumer: .test)
        do {
            _ = try await store.ensureAvailable(manifest)
            XCTFail("expected checksumMismatch")
        } catch let error as LocalModelStore.LocalModelStoreError {
            guard case .checksumMismatch(let path, _, _) = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
            XCTAssertEqual(path, "vocab.json")
        }

        // The rejected file must not be installed.
        let installed = await store.directory(for: manifest)
            .appendingPathComponent("vocab.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
    }

    /// Two-artifact fixture "repo" served over file:// URLs.
    private func makeFixtureModel() throws -> (ModelManifest, sourceDirectory: URL) {
        let source = workspace.appendingPathComponent("upstream", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("bundle.mlmodelc/weights"),
            withIntermediateDirectories: true)

        let weight = Data((0..<4096).map { UInt8($0 % 251) })
        let vocab = Data(#"{"0": "▁hola"}"#.utf8)
        try weight.write(to: source.appendingPathComponent("bundle.mlmodelc/weights/weight.bin"))
        try vocab.write(to: source.appendingPathComponent("vocab.json"))

        let manifest = ModelManifest(
            id: "fixture",
            displayName: "Fixture",
            folderName: "fixture-model",
            resolveBase: source,
            revision: "test",
            artifacts: [
                ModelArtifact(
                    path: "bundle.mlmodelc/weights/weight.bin",
                    sha256: try LocalModelStore.sha256(
                        of: source.appendingPathComponent("bundle.mlmodelc/weights/weight.bin")),
                    sizeBytes: weight.count),
                ModelArtifact(
                    path: "vocab.json",
                    sha256: try LocalModelStore.sha256(of: source.appendingPathComponent("vocab.json")),
                    sizeBytes: vocab.count),
            ],
            minimumRAMGB: 1,
            license: "MIT"
        )
        return (manifest, source)
    }
}

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor Recorder {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

private actor CallCounter {
    private(set) var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}
