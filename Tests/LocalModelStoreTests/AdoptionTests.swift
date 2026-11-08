import Foundation
@testable import LocalModelStore
import Testing

struct AdoptionTests {
    private let installer = StoreConsumer(bundleID: "com.example.installer", displayName: "Installer")
    private let adopter = StoreConsumer(bundleID: "com.example.adopter", displayName: "Adopter")

    private func store(_ scratch: Scratch, consumer: StoreConsumer) throws -> LocalModelStore {
        try LocalModelStore(location: .directory(scratch.storeRoot), consumer: consumer, session: scratch.localSession())
    }

    @Test func anotherAppClaimsAnInstalledModelWithoutDownloading() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let first = try store(scratch, consumer: installer)
        try await first.ensureAvailable(scratch.manifest)
        let requests = scratch.requests
        let second = try store(scratch, consumer: adopter)

        let installation = try #require(await second.claimInstalled(scratch.manifest))

        #expect(installation.directory == (try await first.directory(for: scratch.manifest)))
        #expect(scratch.requests == requests)
        #expect(try await first.remove(scratch.manifest) == .keptForOthers(["Adopter"]))
        #expect(await second.verifiedInstallation(scratch.manifest) != nil)
    }

    @Test func anActiveClaimIsNotRewrittenOnEveryAdoption() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try await store(scratch, consumer: installer).ensureAvailable(scratch.manifest)
        let second = try store(scratch, consumer: adopter)
        #expect(try await second.claimInstalled(scratch.manifest) != nil)
        let claim = scratch.layout.claim(scratch.manifest.storeKey, bundleID: adopter.bundleID)
        let before = FileFingerprint.read(claim)
        let requests = scratch.requests

        #expect(try await second.claimInstalled(scratch.manifest) != nil)

        #expect(FileFingerprint.read(claim) == before)
        #expect(scratch.requests == requests)
    }

    @Test func aMissingInstallationCreatesNothingAndDownloadsNothing() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let second = try store(scratch, consumer: adopter)

        #expect(try await second.claimInstalled(scratch.manifest) == nil)

        #expect(scratch.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: scratch.storeRoot.path))
    }

    @Test func aCorruptInstallationIsNeitherRepairedNorClaimed() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let first = try store(scratch, consumer: installer)
        let directory = try await first.ensureAvailable(scratch.manifest)
        let artifact = directory.appendingPathComponent("weights.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: artifact.path)
        let damaged = Data(repeating: 0, count: 4096)
        try damaged.write(to: artifact)
        let requests = scratch.requests
        let second = try store(scratch, consumer: adopter)

        #expect(try await second.claimInstalled(scratch.manifest) == nil)

        #expect(scratch.requests == requests)
        #expect(try Data(contentsOf: artifact) == damaged)
        #expect(!FileManager.default.fileExists(
            atPath: scratch.layout.claim(scratch.manifest.storeKey, bundleID: adopter.bundleID).path))
    }

    @Test func adoptionRestoresARetiredClaimWithoutDownloading() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let second = try store(scratch, consumer: adopter)
        try await second.ensureAvailable(scratch.manifest)
        try await second.reconcileClaims(keeping: [])
        let claims = ClaimStore(layout: scratch.layout, now: { Date() })
        #expect(claims.isRetired(scratch.manifest.storeKey, consumer: adopter))
        let requests = scratch.requests

        #expect(try await second.claimInstalled(scratch.manifest) != nil)

        #expect(claims.isActive(scratch.manifest.storeKey, consumer: adopter))
        #expect(scratch.requests == requests)
    }

    @Test func aBusyInstallDoesNotWriteAClaim() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try await store(scratch, consumer: installer).ensureAvailable(scratch.manifest)
        guard case .acquired(let held) = try FileLock.tryExclusive(at: scratch.lockFile) else {
            Issue.record("The test must hold the install lock")
            return
        }
        let second = try store(scratch, consumer: adopter)
        let requests = scratch.requests

        do {
            _ = try await second.claimInstalled(scratch.manifest)
            Issue.record("An adoption must not bypass a busy install lock")
        } catch LocalModelStore.LocalModelStoreError.busy(let id) {
            #expect(id == scratch.manifest.id)
        }
        #expect(!FileManager.default.fileExists(
            atPath: scratch.layout.claim(scratch.manifest.storeKey, bundleID: adopter.bundleID).path))
        #expect(scratch.requests == requests)
        held.unlock()
        #expect(try await second.claimInstalled(scratch.manifest) != nil)
    }

    @Test func aClaimWriteFailureIsReportedWithoutDownloading() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try await store(scratch, consumer: installer).ensureAvailable(scratch.manifest)
        let claim = scratch.layout.claim(scratch.manifest.storeKey, bundleID: adopter.bundleID)
        try FileManager.default.createDirectory(at: claim, withIntermediateDirectories: true)
        let requests = scratch.requests
        let second = try store(scratch, consumer: adopter)

        await #expect(throws: (any Error).self) { try await second.claimInstalled(scratch.manifest) }

        #expect(scratch.requests == requests)
        #expect(await second.verifiedInstallation(scratch.manifest) != nil)
    }

    @Test func aCancelledAdoptionDoesNotCreateAClaim() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try await store(scratch, consumer: installer).ensureAvailable(scratch.manifest)
        let requests = scratch.requests
        let second = try store(scratch, consumer: adopter)
        let manifest = scratch.manifest
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await second.claimInstalled(manifest)
        }

        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(scratch.requests == requests)
        #expect(!FileManager.default.fileExists(
            atPath: scratch.layout.claim(scratch.manifest.storeKey, bundleID: adopter.bundleID).path))
    }
}
