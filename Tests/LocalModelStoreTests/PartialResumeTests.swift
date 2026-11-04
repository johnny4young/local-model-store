import Foundation
@testable import LocalModelStore
import Testing

private let other = StoreConsumer(bundleID: "com.example.other", displayName: "Other")

/// Answers every file except the last one, which never finishes, like a dropped connection.
/// It adds no state to `LocalUpstream`, which guards its own.
private final class StallingUpstream: LocalUpstream, @unchecked Sendable {
    override func startLoading() {
        guard let url = request.url, url.lastPathComponent == "vocab.json" else {
            super.startLoading()
            return
        }
        Self.record(url)
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
        while !scratch.requests.contains(scratch.vocab.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(scratch.requests.contains(scratch.vocab.path), "the second transfer is running")
        install.cancel()
        await #expect(throws: CancellationError.self) { try await install.value }
        let attempted = scratch.requests.count
        try await scratch.store().ensureAvailable(scratch.manifest)

        #expect(scratch.requestsAfter(attempted) == [scratch.vocab.path])
    }

    @Test func aKilledProcessResumesAtTheNextFile() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let holder = try scratch.client(held: true, extra: ["--hold-only", scratch.vocab.path])
        try await scratch.waitForEvent(prefix: "download /\(scratch.vocab.path) ")
        kill(holder.processIdentifier, SIGKILL)
        await finish(holder)

        let next = try scratch.client()
        await finish(next)

        #expect(next.terminationStatus == 0, "\(scratch.events)")
        #expect(scratch.downloads(of: scratch.weights.path) == 1)
        #expect(scratch.downloads(of: scratch.vocab.path) == 2)
        #expect(!scratch.exists(scratch.partialDirectory))
    }

    @Test func aResumedInstallReportsProgressOfTheWholeModel() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store()
        try await scratch.dropAfterFirstFile(store)
        let events = Events()

        try await store.ensureAvailable(scratch.manifest) { events.add($0) }

        let reports = events.all.compactMap { event -> LocalModelStore.DownloadProgress? in
            if case .downloading(let progress) = event { progress } else { nil }
        }
        #expect(reports.first?.completedBytes == scratch.weights.sizeBytes)
        #expect(reports.first?.totalBytes == scratch.manifest.totalSizeBytes)
        #expect(reports.last?.fraction == 1)
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

    @Test func aClaimedModelAlsoClearsWhatItNoLongerNeeds() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store()
        try await store.ensureAvailable(scratch.manifest)
        try FileManager.default.createDirectory(at: scratch.partialDirectory, withIntermediateDirectories: true)
        try Data("left".utf8).write(to: scratch.kept(scratch.weights))

        try await store.ensureAvailable(scratch.manifest)

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
        try Data(repeating: 0x00, count: scratch.weights.sizeBytes).write(to: scratch.kept(scratch.weights))
        let attempted = scratch.requests.count

        try await scratch.dropAfterFirstFile(store)

        #expect(scratch.requestsAfter(attempted) == [scratch.weights.path, scratch.vocab.path])
        let kept = try LocalModelStore.sha256(of: scratch.kept(scratch.weights))
        #expect(kept == scratch.weights.sha256, "the bad copy gives way to the fresh one")
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

    @Test func aSymlinkForThePartialRootIsNeverUsed() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock(start: Date())
        let outside = scratch.root.appendingPathComponent("outside", isDirectory: true)
        let foreign = outside.appendingPathComponent(scratch.key, isDirectory: true)
        let bad = foreign.appendingPathComponent(scratch.weights.sha256)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("not the weights".utf8).write(to: bad)
        try FileManager.default.createDirectory(at: scratch.layout.version, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scratch.layout.partials, withDestinationURL: outside)
        let store = try scratch.store(clock: clock)

        try await store.ensureAvailable(scratch.manifest)
        clock.advance(days: 15)
        _ = try await store.collectGarbage()
        _ = try await store.remove(scratch.manifest)

        #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path) == [scratch.weights.sha256])
        #expect(scratch.exists(bad), "nothing was deleted through the link")
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
        let volume = try ScratchVolume(fileSystem: fileSystem, in: scratch.root)
        defer { volume.detach() }
        let storeRoot = volume.mount.appendingPathComponent("store", isDirectory: true)
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
        let clock = TestClock(start: Date())
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
        let clock = TestClock(start: Date())
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
        let clock = TestClock(start: Date())
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
        let clock = TestClock(start: Date())
        let store = try scratch.store(clock: clock)
        try await store.ensureAvailable(scratch.manifest)
        try FileManager.default.createDirectory(at: scratch.partialDirectory, withIntermediateDirectories: true)
        try Data("left".utf8).write(to: scratch.kept(scratch.weights))

        clock.advance(days: 15)
        _ = try await store.collectGarbage()

        #expect(!scratch.exists(scratch.partialDirectory))
        #expect(await store.verify(scratch.manifest).isComplete, "the model stays")
    }

    @Test func collectingAModelAlsoDropsWhatItKept() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock(start: Date())
        let store = try scratch.store(clock: clock)
        try await store.ensureAvailable(scratch.manifest)
        try await store.reconcileClaims(keeping: [])
        clock.advance(days: 15)
        try FileManager.default.createDirectory(at: scratch.partialDirectory, withIntermediateDirectories: true)
        try Data("left".utf8).write(to: scratch.kept(scratch.weights))
        try FileManager.default.setAttributes([.modificationDate: clock.now], ofItemAtPath: scratch.partialDirectory.path)

        let report = try await store.collectGarbage()

        #expect(report.removed == [scratch.key])
        #expect(!scratch.exists(scratch.partialDirectory), "the model took them along, inside their grace")
    }

    @Test func collectionNeverDeletesThroughASymlink() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock(start: Date())
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
