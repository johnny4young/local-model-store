import Foundation
@testable import LocalModelStore
import os
import Testing

private let release = StoreConsumer(bundleID: "com.example.app", displayName: "App")
private let dev = StoreConsumer(bundleID: "com.example.app.dev", displayName: "App Dev")
private let other = StoreConsumer(bundleID: "com.example.other", displayName: "Other")

private final class TestClock: Sendable {
    private let date = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { date.withLock { $0 } }
    func advance(days: Double) { date.withLock { $0 += days * 24 * 60 * 60 } }
}

private extension Scratch {
    func store(_ consumer: StoreConsumer, clock: TestClock? = nil) throws -> LocalModelStore {
        var policy = LocalModelStore.WaitPolicy()
        policy.leaseTimeout = .milliseconds(100)
        return try LocalModelStore(
            location: .directory(storeRoot), consumer: consumer, session: localSession(), waitPolicy: policy,
            now: { clock?.now ?? Date() })
    }

    var modelExists: Bool {
        FileManager.default.fileExists(atPath: layout.model(manifest.storeKey).path)
    }

    func claim(_ consumer: StoreConsumer) -> URL {
        layout.claim(manifest.storeKey, bundleID: consumer.bundleID)
    }
}

struct ClaimTests {
    @Test func anInstallClaimsAndASecondAppClaimsWithoutDownloading() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try await scratch.store(release).ensureAvailable(scratch.manifest)
        let requests = scratch.requests.count
        try await scratch.store(other).ensureAvailable(scratch.manifest)

        #expect(scratch.requests.count == requests, "a model downloads once")
        #expect(FileManager.default.fileExists(atPath: scratch.claim(release).path))
        #expect(FileManager.default.fileExists(atPath: scratch.claim(other).path))
    }

    @Test func releaseAndDevAreSeparateConsumers() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try await scratch.store(release).ensureAvailable(scratch.manifest)
        let devStore = try scratch.store(dev)
        try await devStore.ensureAvailable(scratch.manifest)

        #expect(try await devStore.remove(scratch.manifest) == .keptForOthers(["App"]))
        #expect(scratch.modelExists)
        #expect(!FileManager.default.fileExists(atPath: scratch.claim(dev).path))
        #expect(try await scratch.store(release).remove(scratch.manifest) == .removed)
        #expect(!scratch.modelExists)
    }

    @Test func removingForAllAppsDropsEveryClaim() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try await scratch.store(release).ensureAvailable(scratch.manifest)
        let otherStore = try scratch.store(other)
        try await otherStore.ensureAvailable(scratch.manifest)

        #expect(try await otherStore.remove(scratch.manifest, scope: .allConsumers) == .removed)
        #expect(!scratch.modelExists)
        #expect(await otherStore.verifiedInstallation(scratch.manifest) == nil)
    }

    @Test func aClaimIsRefreshedAtMostOnceADay() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock()
        let store = try scratch.store(release, clock: clock)
        try await store.ensureAvailable(scratch.manifest)
        let claims = ClaimStore(layout: scratch.layout) { clock.now }
        let first = try #require(claims.all(scratch.manifest.storeKey).first)

        clock.advance(days: 0.5)
        try await store.ensureAvailable(scratch.manifest)
        #expect(claims.all(scratch.manifest.storeKey).first == first)

        clock.advance(days: 0.6)
        try await store.ensureAvailable(scratch.manifest)
        let refreshed = try #require(claims.all(scratch.manifest.storeKey).first)
        #expect(refreshed.lastUsedAt > first.lastUsedAt)
        #expect(refreshed.firstClaimedAt == first.firstClaimedAt)
    }

    @Test func claimFilesAreToleratedWhenTheyAreUnknownOrBroken() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store(release)
        try await store.ensureAvailable(scratch.manifest)
        let directory = scratch.claim(release).deletingLastPathComponent()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let newer = #"{"consumer":"future","displayName":"Future","firstClaimedAt":"2030-01-01T00:00:00Z","#
            + #""lastUsedAt":"2030-01-01T00:00:00Z","added":true}"#
        try Data(newer.utf8).write(to: directory.appendingPathComponent("future.json"))

        let entry = try #require(try await store.inventory().first)
        #expect(Set(entry.claimants) == ["App", "Future"], "the broken file is skipped, and the newer one is read")
        #expect(try await store.remove(scratch.manifest) == .keptForOthers(["Future"]))
    }

    @Test(arguments: ["", ".hidden", "a/b", "../x", "a b"])
    func anUnsafeBundleIDIsRejected(bundleID: String) throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        #expect(throws: LocalModelStore.LocalModelStoreError.self) {
            try LocalModelStore(
                location: .directory(scratch.storeRoot),
                consumer: StoreConsumer(bundleID: bundleID, displayName: "x"))
        }
    }
}

struct RepinTests {
    private func repinned(_ manifest: ModelManifest) -> ModelManifest {
        ModelManifest(
            id: manifest.id, displayName: manifest.displayName, resolveBase: manifest.resolveBase, revision: "rev2",
            artifacts: manifest.artifacts, minimumRAMGB: 0, license: "MIT")
    }

    @Test func aRetiredClaimProtectsForTheGraceAndARollbackRestoresIt() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock()
        let store = try scratch.store(release, clock: clock)
        try await store.ensureAvailable(scratch.manifest)
        let next = repinned(scratch.manifest)
        try await store.ensureAvailable(next)
        try await store.reconcileClaims(keeping: [next])

        clock.advance(days: 13.9)
        #expect(try await store.collectGarbage().removed.isEmpty)
        #expect(scratch.modelExists)

        // A rollback within the grace downloads nothing and clears the retirement.
        let requests = scratch.requests.count
        try await store.ensureAvailable(scratch.manifest)
        try await store.reconcileClaims(keeping: [scratch.manifest, next])
        #expect(scratch.requests.count == requests)
        clock.advance(days: 30)
        #expect(try await store.collectGarbage().removed.isEmpty)
        #expect(scratch.modelExists)
    }

    @Test func aRetiredClaimPastTheGraceLetsTheModelGo() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock()
        let store = try scratch.store(release, clock: clock)
        try await store.ensureAvailable(scratch.manifest)
        let next = repinned(scratch.manifest)
        try await store.ensureAvailable(next)
        try await store.reconcileClaims(keeping: [next])

        clock.advance(days: 14)
        let report = try await store.collectGarbage()

        #expect(report.removed == [scratch.manifest.storeKey])
        #expect(!scratch.modelExists)
        #expect(await store.verify(next).isComplete, "the current pin stays")
    }

    @Test func anotherAppsRetiredClaimStillProtectsDuringTheGrace() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock()
        let store = try scratch.store(release, clock: clock)
        let otherStore = try scratch.store(other, clock: clock)
        try await store.ensureAvailable(scratch.manifest)
        try await otherStore.ensureAvailable(scratch.manifest)
        try await otherStore.reconcileClaims(keeping: [])

        #expect(try await store.remove(scratch.manifest) == .keptForOthers(["Other"]))
        clock.advance(days: 14)
        #expect(try await store.collectGarbage().removed == [scratch.manifest.storeKey])
    }

    @Test func aRetiredClaimPastTheGraceDoesNotBlockARemoval() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let clock = TestClock()
        let store = try scratch.store(release, clock: clock)
        let otherStore = try scratch.store(other, clock: clock)
        try await store.ensureAvailable(scratch.manifest)
        try await otherStore.ensureAvailable(scratch.manifest)
        try await otherStore.reconcileClaims(keeping: [])

        clock.advance(days: 14)
        #expect(try await store.remove(scratch.manifest) == .removed)
    }
}

struct LeaseTests {
    @Test func aLeaseDefersRemovalUntilItIsReleased() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store(release)
        try await store.ensureAvailable(scratch.manifest)
        var lease: LocalModelStore.ModelLease? = try await store.lease(scratch.manifest)
        #expect(lease?.directory == (try await store.directory(for: scratch.manifest)))

        #expect(try await store.remove(scratch.manifest) == .deferred)
        #expect(scratch.modelExists)
        #expect(try await store.collectGarbage().inUse == [scratch.manifest.storeKey])

        lease = nil
        #expect(try await store.collectGarbage().removed == [scratch.manifest.storeKey])
        #expect(!scratch.modelExists)
    }

    @Test func aModelThatIsNotVerifiedCannotBeLeased() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store(release)
        await #expect(throws: LocalModelStore.LocalModelStoreError.self) { try await store.lease(scratch.manifest) }
        #expect(!FileManager.default.fileExists(atPath: scratch.storeRoot.path), "a failed lease creates nothing")

        let directory = try await store.ensureAvailable(scratch.manifest)
        try Data("bad".utf8).write(to: directory.appendingPathComponent("weights.bin"), options: .atomic)
        await #expect(throws: LocalModelStore.LocalModelStoreError.self) { try await store.lease(scratch.manifest) }
    }

    @Test func aLeaseWaitsOutADeletionAndThenGivesUp() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store(release)
        try await store.ensureAvailable(scratch.manifest)
        guard case .acquired(let deleter) = try FileLock.tryExclusive(at: scratch.layout.useLock(scratch.manifest.storeKey)) else {
            Issue.record("The test must hold the use lock")
            return
        }
        await #expect(throws: LocalModelStore.LocalModelStoreError.self) { try await store.lease(scratch.manifest) }
        withExtendedLifetime(deleter) {}
    }
}

struct InventoryAndGarbageTests {
    @Test func theInventoryListsModelsClaimsAndUse() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store(release)
        try await store.ensureAvailable(scratch.manifest)
        try await scratch.store(other).ensureAvailable(scratch.manifest)

        var entry = try #require(try await store.inventory().first)
        #expect(entry.key == scratch.manifest.storeKey)
        #expect(entry.id == scratch.manifest.id)
        #expect(entry.logicalBytes == scratch.manifest.totalSizeBytes)
        #expect(Set(entry.claimants) == ["App", "Other"])
        #expect(entry.isClaimedByThisConsumer)
        #expect(entry.isInUse == false)

        let lease = try await store.lease(scratch.manifest)
        entry = try #require(try await store.inventory().first)
        #expect(entry.isInUse)
        withExtendedLifetime(lease) {}
    }

    @Test func aFolderWithoutAManifestStillShowsUpAndCanBeCollected() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store(release)
        let unknown = scratch.layout.model("unknown")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)

        let entry = try #require(try await store.inventory().first)
        #expect(entry.key == "unknown" && entry.id == nil && entry.logicalBytes == nil)
        #expect(try await store.collectGarbage().removed == ["unknown"])
    }

    @Test func aSymlinkInModelsIsNeverFollowedOrDeletedThrough() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let precious = scratch.root.appendingPathComponent("precious", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: precious.appendingPathComponent("file"))
        try FileManager.default.createDirectory(at: scratch.layout.models, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: scratch.layout.model("link"), withDestinationURL: precious)

        let store = try scratch.store(release)
        #expect(try await store.inventory().isEmpty)
        _ = try await store.collectGarbage()
        #expect(FileManager.default.fileExists(atPath: precious.appendingPathComponent("file").path))
    }

    @Test func garbageCollectionSkipsAModelBeingInstalledAndClearsLeftovers() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store(release)
        try await store.ensureAvailable(scratch.manifest)
        try await store.reconcileClaims(keeping: [])
        let key = scratch.manifest.storeKey
        let doomed = scratch.layout.trash.appendingPathComponent("left", isDirectory: true)
        try FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: true)
        let orphanClaims = scratch.layout.claims.appendingPathComponent("gone", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanClaims, withIntermediateDirectories: true)

        guard case .acquired(let installer) = try FileLock.tryExclusive(at: scratch.layout.installLock(key)) else {
            Issue.record("The test must hold the install lock")
            return
        }
        let report = try await store.collectGarbage()
        #expect(report.inUse == [key])
        #expect(scratch.modelExists)
        #expect(!FileManager.default.fileExists(atPath: doomed.path))
        #expect(!FileManager.default.fileExists(atPath: orphanClaims.path))
        withExtendedLifetime(installer) {}
    }

    @Test func removingWhileAnotherProcessInstallsIsDeferred() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store(release)
        try await store.ensureAvailable(scratch.manifest)
        guard case .acquired(let installer) = try FileLock.tryExclusive(
            at: scratch.layout.installLock(scratch.manifest.storeKey)) else {
            Issue.record("The test must hold the install lock")
            return
        }
        #expect(try await store.remove(scratch.manifest) == .deferred)
        #expect(!FileManager.default.fileExists(atPath: scratch.claim(release).path), "the claim still goes")
        #expect(scratch.modelExists)
        withExtendedLifetime(installer) {}
    }
}

struct ChangeNotificationTests {
    private func next(_ stream: AsyncStream<Void>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    @Test func anInstallInAnotherStoreFiresWithoutTheWatcherCreatingAnything() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try FileManager.default.createDirectory(at: scratch.root, withIntermediateDirectories: true)
        let watcher = try scratch.store(release)
        let stream = watcher.changes()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: scratch.storeRoot.path), "watching creates nothing")

        try await scratch.store(other).ensureAvailable(scratch.manifest)
        #expect(await next(stream))
    }

    @Test func aClaimChangeFires() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = try scratch.store(release)
        try await store.ensureAvailable(scratch.manifest)
        let stream = store.changes()
        try await Task.sleep(for: .milliseconds(100))

        try await scratch.store(other).ensureAvailable(scratch.manifest)
        #expect(await next(stream))
    }
}

struct AcceptanceTests {
    @Test func aCrashRightAfterPublishLeavesAUsableModel() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let crashing = try scratch.client(extra: ["--crash-after-publish"])
        await finish(crashing)
        #expect(crashing.terminationStatus == 9)
        #expect(scratch.modelExists)
        let requests = scratch.events.filter { $0.hasPrefix("download ") }.count

        let next = try scratch.client()
        await finish(next)
        #expect(next.terminationStatus == 0)
        #expect(scratch.events.filter { $0.hasPrefix("download ") }.count == requests, "nothing is downloaded again")
        #expect(scratch.stagingEntries().isEmpty)
    }

    @Test func aLeaseInAnotherProcessProtectsTheModelUntilThatProcessDies() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let reader = try scratch.client(extra: ["--hold-lease", "--consumer", other.bundleID])
        defer { kill(reader.processIdentifier, SIGKILL) }
        try await scratch.waitForEvent(prefix: "leased ")

        let store = try scratch.store(release)
        let report = try await store.collectGarbage()
        #expect(report.removed.isEmpty, "a claim and a lease both protect it")

        #expect(try await store.remove(scratch.manifest, scope: .allConsumers) == .deferred)
        #expect(scratch.modelExists)
        #expect(try await store.collectGarbage().inUse == [scratch.manifest.storeKey])

        kill(reader.processIdentifier, SIGKILL)
        await finish(reader)
        #expect(try await store.collectGarbage().removed == [scratch.manifest.storeKey])
    }

    @Test func aRepairWorksWhileAnotherProcessHasTheModelLeased() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let reader = try scratch.client(extra: ["--hold-lease", "--consumer", other.bundleID])
        defer { kill(reader.processIdentifier, SIGKILL) }
        try await scratch.waitForEvent(prefix: "leased ")

        let store = try scratch.store(release)
        let directory = try await store.directory(for: scratch.manifest)
        try Data("bad".utf8).write(to: directory.appendingPathComponent("weights.bin"), options: .atomic)
        try await store.ensureAvailable(scratch.manifest)

        #expect(await store.verify(scratch.manifest).isComplete)
        #expect(reader.isRunning)
    }

    /// Runs on a real non-APFS volume, where there is no `clonefile` and renames
    /// may lack `RENAME_EXCL` and `RENAME_SWAP`.
    @Test func aStoreAndItsSeedsWorkAcrossVolumes() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let image = scratch.root.appendingPathComponent("volume.dmg")
        let mount = scratch.root.appendingPathComponent("mount", isDirectory: true)
        try run("/usr/bin/hdiutil", "create", "-quiet", "-size", "128m", "-fs", "HFS+", "-volname", "LMSTest", image.path)
        try run("/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path)
        defer { try? run("/usr/bin/hdiutil", "detach", "-quiet", "-force", mount.path) }

        // The store is on the other volume, and the seed is on this one.
        let storeRoot = mount.appendingPathComponent("store", isDirectory: true)
        let store = try LocalModelStore(
            location: .directory(storeRoot), consumer: release, session: scratch.localSession())
        let seed = scratch.root.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.copyItem(at: scratch.upstream, to: seed)
        try FileManager.default.removeItem(at: seed.appendingPathComponent("vocab.json"))

        let directory = try await store.ensureAvailable(scratch.manifest, seeds: [seed])
        #expect(scratch.requests == ["vocab.json"], "the seed crosses volumes by copy")
        #expect(await store.verify(scratch.manifest).isComplete)

        // Second install on that volume publishes and repairs there too.
        try Data("bad".utf8).write(to: directory.appendingPathComponent("weights.bin"), options: .atomic)
        try await store.ensureAvailable(scratch.manifest)
        #expect(await store.verify(scratch.manifest).isComplete)
        #expect(try await store.remove(scratch.manifest) == .removed)
        #expect(await store.verify(scratch.manifest).isComplete == false)

        // And the reverse: a store on this volume, seeded from the other one.
        let outsideSeed = mount.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.copyItem(at: scratch.upstream, to: outsideSeed)
        let local = try scratch.store(other)
        let before = scratch.requests.count
        try await local.ensureAvailable(scratch.manifest, seeds: [outsideSeed])
        #expect(scratch.requests.count == before)
        #expect(await local.verify(scratch.manifest).isComplete)
    }

    private func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(tool) \(arguments)")
    }
}
