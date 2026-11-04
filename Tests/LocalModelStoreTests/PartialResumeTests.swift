import Foundation
@testable import LocalModelStore
import os
import Testing

private let other = StoreConsumer(bundleID: "com.example.other", displayName: "Other")

private final class TestClock: Sendable {
    private let date = OSAllocatedUnfairLock(initialState: Date())
    var now: Date { date.withLock { $0 } }
    func advance(days: Double) { date.withLock { $0 += days * 24 * 60 * 60 } }
}

/// Answers every file except the last one, which never finishes, like a dropped connection.
private final class StallingUpstream: LocalUpstream, @unchecked Sendable {
    override func startLoading() {
        if request.url?.lastPathComponent != "vocab.json" { super.startLoading() }
    }
}

private extension Scratch {
    var key: String { manifest.storeKey }
    var weights: ModelArtifact { manifest.artifacts[0] }
    var vocab: ModelArtifact { manifest.artifacts[1] }
    var partialDirectory: URL { layout.partial(key) }

    func kept(_ artifact: ModelArtifact) -> URL {
        partialDirectory.appendingPathComponent(artifact.sha256)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func store(consumer: StoreConsumer = .test, clock: TestClock? = nil) throws -> LocalModelStore {
        try LocalModelStore(
            location: .directory(storeRoot), consumer: consumer, session: localSession(),
            waitPolicy: LocalModelStore.WaitPolicy(), now: { clock?.now ?? Date() })
    }

    /// Runs an install that fails on the last file, because upstream lost it.
    func dropAfterFirstFile(_ store: LocalModelStore) async throws {
        let file = upstream.appendingPathComponent(vocab.path)
        let aside = root.appendingPathComponent("vocab-aside")
        try FileManager.default.moveItem(at: file, to: aside)
        await #expect(throws: LocalModelStore.LocalModelStoreError.self) {
            try await store.ensureAvailable(manifest)
        }
        try FileManager.default.moveItem(at: aside, to: file)
    }

    func requestsAfter(_ count: Int) -> [String] {
        Array(requests.dropFirst(count))
    }
}

struct PartialResumeTests {
    @Test func aDroppedDownloadResumesAtTheNextFile() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store()

        try await scratch.dropAfterFirstFile(store)
        let attempted = scratch.requests.count
        try await store.ensureAvailable(scratch.manifest)

        #expect(scratch.requestsAfter(attempted) == [scratch.vocab.path])
        #expect(await store.verify(scratch.manifest).isComplete)
    }

    @Test func aCancelledDownloadResumesAtTheNextFile() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        _ = try scratch.store()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StallingUpstream.self]
        let stalling = try LocalModelStore(
            location: .directory(scratch.storeRoot), consumer: .test, session: URLSession(configuration: configuration))

        let install = Task { try await stalling.ensureAvailable(scratch.manifest) }
        let deadline = ContinuousClock.now + .seconds(30)
        while !scratch.exists(scratch.kept(scratch.weights)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        install.cancel()
        await #expect(throws: (any Error).self) { try await install.value }
        let attempted = scratch.requests.count
        try await scratch.store().ensureAvailable(scratch.manifest)

        #expect(scratch.requestsAfter(attempted) == [scratch.vocab.path])
    }

    @Test func anotherAppResumesWhatTheFirstOneDownloaded() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }

        try await scratch.dropAfterFirstFile(try scratch.store())
        let attempted = scratch.requests.count
        try await scratch.store(consumer: other).ensureAvailable(scratch.manifest)

        #expect(scratch.requestsAfter(attempted) == [scratch.vocab.path])
    }

    @Test func anInstallLeavesNothingBehind() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store()

        try await scratch.dropAfterFirstFile(store)
        #expect(scratch.exists(scratch.kept(scratch.weights)))
        try await store.ensureAvailable(scratch.manifest)

        #expect(!scratch.exists(scratch.partialDirectory))
    }

    @Test func aModelAlreadyInstalledClearsWhatACrashLeft() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try await scratch.store().ensureAvailable(scratch.manifest)
        try FileManager.default.createDirectory(at: scratch.partialDirectory, withIntermediateDirectories: true)
        try Data("left".utf8).write(to: scratch.kept(scratch.weights))

        try await scratch.store(consumer: other).ensureAvailable(scratch.manifest)

        #expect(!scratch.exists(scratch.partialDirectory))
    }

    @Test func aRepairUsesWhatItKept() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store()
        try await store.ensureAvailable(scratch.manifest)
        let payload = scratch.layout.payload(scratch.key)
        let bytes = try Data(contentsOf: payload.appendingPathComponent(scratch.weights.path))
        try FileManager.default.createDirectory(at: scratch.partialDirectory, withIntermediateDirectories: true)
        try bytes.write(to: scratch.kept(scratch.weights))
        let weights = payload.appendingPathComponent(scratch.weights.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: weights.path)
        try Data("damaged".utf8).write(to: weights)
        let attempted = scratch.requests.count

        try await store.ensureAvailable(scratch.manifest)

        #expect(scratch.requestsAfter(attempted).isEmpty)
        #expect(await store.verify(scratch.manifest).isComplete)
    }

    @Test func aKeptFileWithBadBytesIsDiscardedAndDownloadedAgain() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store()
        try await scratch.dropAfterFirstFile(store)
        try Data("tampered".utf8).write(to: scratch.kept(scratch.weights))
        let upstreamFile = scratch.upstream.appendingPathComponent(scratch.vocab.path)
        let aside = scratch.root.appendingPathComponent("vocab-aside")
        try FileManager.default.moveItem(at: upstreamFile, to: aside)
        let attempted = scratch.requests.count

        await #expect(throws: LocalModelStore.LocalModelStoreError.self) {
            try await store.ensureAvailable(scratch.manifest)
        }

        #expect(scratch.requestsAfter(attempted) == [scratch.weights.path, scratch.vocab.path])
        let kept = try Data(contentsOf: scratch.kept(scratch.weights))
        #expect(kept.count == scratch.weights.sizeBytes, "the bad copy gives way to the fresh one")
    }

    @Test func aFileThatFailsItsHashIsNeverKept() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store()
        try Data(repeating: 0x00, count: scratch.weights.sizeBytes)
            .write(to: scratch.upstream.appendingPathComponent(scratch.weights.path))

        await #expect(throws: LocalModelStore.LocalModelStoreError.self) {
            try await store.ensureAvailable(scratch.manifest)
        }

        #expect(!scratch.exists(scratch.kept(scratch.weights)))
    }

    @Test func aSymlinkForTheDirectoryIsNeitherReadNorWrittenThrough() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let outside = scratch.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: scratch.upstream.appendingPathComponent(scratch.weights.path),
            to: outside.appendingPathComponent(scratch.weights.sha256))
        try FileManager.default.createDirectory(at: scratch.layout.partials, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scratch.partialDirectory, withDestinationURL: outside)
        let store = try scratch.store()

        try await store.ensureAvailable(scratch.manifest)

        #expect(scratch.requests == [scratch.weights.path, scratch.vocab.path], "nothing came through the link")
        let contents = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        #expect(contents == [scratch.weights.sha256], "nothing was written or deleted through the link")
    }

    @Test func anInstallThatCannotKeepFilesStillSucceeds() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try FileManager.default.createDirectory(at: scratch.layout.partials, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: scratch.partialDirectory)
        let store = try scratch.store()

        try await store.ensureAvailable(scratch.manifest)

        #expect(await store.verify(scratch.manifest).isComplete)
    }

    /// Real non-APFS volumes, where a kept copy would cost a second set of bytes.
    @Test(arguments: ["HFS+", "ExFAT"])
    func aVolumeWithoutClonesKeepsNothingAndStillInstalls(fileSystem: String) async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let image = scratch.root.appendingPathComponent("volume.dmg")
        let mount = scratch.root.appendingPathComponent("mount", isDirectory: true)
        try run("/usr/bin/hdiutil", "create", "-quiet", "-size", "128m", "-fs", fileSystem, "-volname", "LMSTest", image.path)
        try run("/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path)
        defer { try? run("/usr/bin/hdiutil", "detach", "-quiet", "-force", mount.path) }
        let storeRoot = mount.appendingPathComponent("store", isDirectory: true)
        let store = try LocalModelStore(
            location: .directory(storeRoot), consumer: .test, session: scratch.localSession())

        try await scratch.dropAfterFirstFile(store)
        let kept = StoreLayout(root: storeRoot).partial(scratch.key).appendingPathComponent(scratch.weights.sha256)
        #expect(!scratch.exists(kept))

        try await store.ensureAvailable(scratch.manifest)
        #expect(await store.verify(scratch.manifest).isComplete)
    }

    @Test func aFailedInstallHasReleasedItsLockWhenItReturns() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store()

        for _ in 0..<50 {
            try await scratch.dropAfterFirstFile(store)
            let attempt = try FileLock.tryExclusive(at: scratch.lockFile)
            guard case .acquired = attempt else {
                Issue.record("The lock outlived the install")
                return
            }
        }
    }

    @Test func removingAModelAlsoDropsWhatItKept() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store()
        try await scratch.dropAfterFirstFile(store)

        let outcome = try await store.remove(scratch.manifest)

        #expect(outcome == .removed)
        #expect(!scratch.exists(scratch.partialDirectory))
    }

    @Test func aLaterAttemptRestartsTheGrace() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock()
        let store = try scratch.store(clock: clock)
        try await scratch.dropAfterFirstFile(store)
        clock.advance(days: 13)
        try await scratch.dropAfterFirstFile(store)
        clock.advance(days: 13)

        _ = try await store.collectGarbage()

        #expect(scratch.exists(scratch.kept(scratch.weights)))
    }

    @Test func collectionDropsKeptFilesOnlyAfterTheGrace() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock()
        let store = try scratch.store(clock: clock)
        try await scratch.dropAfterFirstFile(store)

        clock.advance(days: 13)
        _ = try await store.collectGarbage()
        #expect(scratch.exists(scratch.kept(scratch.weights)))

        clock.advance(days: 2)
        _ = try await store.collectGarbage()
        #expect(!scratch.exists(scratch.partialDirectory))
    }

    @Test func collectionLeavesKeptFilesWhileAnInstallRuns() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock()
        let store = try scratch.store(clock: clock)
        try await scratch.dropAfterFirstFile(store)
        clock.advance(days: 15)
        let held = try FileLock.tryExclusive(at: scratch.lockFile)

        _ = try await store.collectGarbage()

        #expect(scratch.exists(scratch.kept(scratch.weights)))
        withExtendedLifetime(held) {}
    }

    @Test func collectionDropsWhatACrashLeftBesideAClaimedModel() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock()
        let store = try scratch.store(clock: clock)
        try await store.ensureAvailable(scratch.manifest)
        try FileManager.default.createDirectory(at: scratch.partialDirectory, withIntermediateDirectories: true)
        try Data("left".utf8).write(to: scratch.kept(scratch.weights))

        clock.advance(days: 15)
        _ = try await store.collectGarbage()

        #expect(!scratch.exists(scratch.partialDirectory))
        #expect(await store.verify(scratch.manifest).isComplete, "the model stays")
    }

    @Test func collectionNeverDeletesThroughASymlink() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock()
        let store = try scratch.store(clock: clock)
        try await scratch.dropAfterFirstFile(store)
        let outside = scratch.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let precious = outside.appendingPathComponent("precious")
        try Data("keep".utf8).write(to: precious)
        try FileManager.default.createSymbolicLink(
            at: scratch.layout.partials.appendingPathComponent("linked"), withDestinationURL: outside)

        clock.advance(days: 15)
        _ = try await store.collectGarbage()

        #expect(scratch.exists(precious))
    }
}
