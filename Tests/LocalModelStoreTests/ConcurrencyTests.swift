import Foundation
@testable import LocalModelStore
import os
import Testing

/// A scratch store plus a fixture upstream and manifest. Never touches a real store.
private struct Scratch {
    let root: URL
    let upstream: URL
    let manifest: ModelManifest
    let manifestFile: URL
    let log: URL
    let storeRoot: URL
    let holdFile: URL

    init(artifactBytes: Int = 4096) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-model-store-concurrency-\(UUID().uuidString)", isDirectory: true)
        upstream = root.appendingPathComponent("upstream", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        log = root.appendingPathComponent("events.log")
        manifestFile = root.appendingPathComponent("manifest.json")
        holdFile = root.appendingPathComponent("release-upstream")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)

        var artifacts: [ModelArtifact] = []
        for name in ["weights.bin", "vocab.json"] {
            let file = upstream.appendingPathComponent(name)
            try Data(repeating: 0x5A, count: artifactBytes).write(to: file)
            artifacts.append(
                ModelArtifact(path: name, sha256: try LocalModelStore.sha256(of: file), sizeBytes: artifactBytes))
        }
        manifest = ModelManifest(
            id: "fixture",
            displayName: "Fixture",
            folderName: "fixture",
            // A host per scratch keeps parallel tests from reading each other's files.
            resolveBase: try #require(URL(string: "https://\(UUID().uuidString).invalid")),
            revision: "rev1",
            artifacts: artifacts,
            minimumRAMGB: 0,
            license: "MIT")
        try JSONEncoder().encode(manifest).write(to: manifestFile)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A store in this process that downloads from this scratch's upstream.
    func store() -> LocalModelStore {
        if let host = manifest.resolveBase.host { LocalUpstream.register(upstream, host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalUpstream.self]
        return LocalModelStore(
            rootDirectory: storeRoot, consumer: .test, session: URLSession(configuration: configuration))
    }

    var events: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func downloads(of name: String) -> Int {
        events.filter { $0.hasPrefix("download /\(name) ") }.count
    }

    func releaseUpstream() throws {
        try Data().write(to: holdFile)
    }

    func client(held: Bool = false, stallMilliseconds: Int? = nil) throws -> Process {
        let process = Process()
        process.executableURL = try clientExecutable()
        var arguments = [
            "--root", storeRoot.path, "--manifest", manifestFile.path, "--upstream", upstream.path,
            "--log", log.path
        ]
        if held { arguments += ["--hold-file", holdFile.path] }
        if let stallMilliseconds { arguments += ["--stall-ms", String(stallMilliseconds)] }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        return process
    }

    func waitForEvent(prefix: String, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !events.contains(where: { $0.hasPrefix(prefix) }) {
            guard ContinuousClock.now < deadline else {
                Issue.record("No event starting with \(prefix): \(events)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func stagingEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: storeRoot.appendingPathComponent("staging").path)) ?? []
    }
}

private final class BundleAnchor {}

private func clientExecutable() throws -> URL {
    let products = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
    let url = products.appendingPathComponent("store-test-client")
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "missing \(url.path)")
    return url
}

private func finish(_ process: Process) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            process.waitUntilExit()
            continuation.resume()
        }
    }
}

/// Collects events synchronously, so their order is the order they were emitted.
private final class Events: Sendable {
    private let state = OSAllocatedUnfairLock<[LocalModelStore.InstallEvent]>(initialState: [])
    var all: [LocalModelStore.InstallEvent] { state.withLock { $0 } }
    func add(_ event: LocalModelStore.InstallEvent) { state.withLock { $0.append(event) } }
}

struct MultiprocessInstallTests {
    @Test func twoProcessesDownloadOnceAndBothSucceed() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let first = try scratch.client(held: true)
        try await scratch.waitForEvent(prefix: "download ")
        let second = try scratch.client()
        try await scratch.waitForEvent(prefix: "waiting ")
        try scratch.releaseUpstream()
        await finish(first)
        await finish(second)

        #expect(first.terminationStatus == 0)
        #expect(second.terminationStatus == 0)
        for artifact in scratch.manifest.artifacts {
            #expect(scratch.downloads(of: artifact.path) == 1, "\(scratch.events)")
        }
        #expect(scratch.events.filter { $0.hasPrefix("installed ") }.count == 2)
        #expect(scratch.stagingEntries().isEmpty)
    }

    @Test func aKilledHolderReleasesTheLockAndItsWorkIsSwept() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let holder = try scratch.client(held: true)
        try await scratch.waitForEvent(prefix: "download ")
        kill(holder.processIdentifier, SIGKILL)
        await finish(holder)
        #expect(!scratch.stagingEntries().isEmpty, "the killed holder leaves its staging behind")

        let next = try scratch.client()
        await finish(next)
        #expect(next.terminationStatus == 0)
        #expect(scratch.stagingEntries().isEmpty, "the next install sweeps abandoned work")
        #expect(FileManager.default.fileExists(
            atPath: scratch.storeRoot.appendingPathComponent("locks/fixture@rev1.lock").path),
            "lock files are never deleted")
    }

    @Test func aStalledHolderIsRacedAndTheInstallStaysCorrect() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let stalled = try scratch.client(held: true)
        try await scratch.waitForEvent(prefix: "download ")
        kill(stalled.processIdentifier, SIGSTOP)
        defer {
            kill(stalled.processIdentifier, SIGKILL)
            stalled.waitUntilExit()
        }

        let waiter = try scratch.client(stallMilliseconds: 200)
        await finish(waiter)
        #expect(waiter.terminationStatus == 0, "\(scratch.events)")
        #expect(scratch.events.contains { $0.hasPrefix("waiting ") })

        let store = LocalModelStore(rootDirectory: scratch.storeRoot, consumer: .test)
        #expect(await store.verify(scratch.manifest).isComplete)
    }
}

struct InstallLockTests {
    @Test func cancellingAWaitDownloadsNothingAndLeavesNoWork() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.storeRoot.appendingPathComponent("locks/fixture@rev1.lock")
        guard case .acquired(let holder) = try FileLock.tryExclusive(at: url) else {
            Issue.record("The test must hold the lock")
            return
        }
        let events = Events()
        var policy = LocalModelStore.WaitPolicy()
        policy.pollInterval = .milliseconds(5)
        let store = LocalModelStore(
            rootDirectory: scratch.storeRoot, consumer: .test, session: .shared, waitPolicy: policy)
        let manifest = scratch.manifest
        let install = Task {
            try await store.ensureAvailable(manifest) { events.add($0) }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !events.all.contains(where: { if case .waitingForOtherProcess = $0 { true } else { false } }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        install.cancel()
        await #expect(throws: CancellationError.self) { try await install.value }
        #expect(scratch.stagingEntries().isEmpty)
        withExtendedLifetime(holder) {}
    }

    @Test func locksAreClosedOnExecAndExclusive() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.storeRoot.appendingPathComponent("locks/x.lock")
        guard case .acquired(let lock) = try FileLock.tryExclusive(at: url) else {
            Issue.record("The first holder must acquire")
            return
        }
        #expect(fcntl(lock.descriptor, F_GETFD) & FD_CLOEXEC != 0)
        guard case .busy = try FileLock.tryExclusive(at: url) else {
            Issue.record("A second open must see the lock as busy")
            return
        }
        withExtendedLifetime(lock) {}
    }

    @Test func anUnsupportedVolumeStillGetsAStagingDirectory() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let staging = try StagingDirectory(root: scratch.storeRoot) { _ in .unsupported }
        #expect(FileManager.default.fileExists(atPath: staging.url.path))
        staging.remove()
    }

    @Test func aNewHolderClearsAFinishedHoldersProgress() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.storeRoot.appendingPathComponent("locks/fixture@rev1.lock")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"completedBytes":99,"totalBytes":100}"#.utf8).write(to: url)
        let contents = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let store = scratch.store()
        try await store.ensureAvailable(scratch.manifest) { event in
            guard case .verifying = event, let data = try? Data(contentsOf: url) else { return }
            contents.withLock { $0.append(data) }
        }
        let seen = contents.withLock { $0 }
        #expect(seen.count == 3, "start, after the lock, and the final pass")
        #expect(seen[0] != Data())
        #expect(seen[1] == Data(), "once the lock is held, old progress must be gone")
    }

    @Test func aSweepKeepsLiveWorkAndRemovesOrphans() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let live = try StagingDirectory(root: scratch.storeRoot)
        defer { live.remove() }
        let orphan = scratch.storeRoot.appendingPathComponent("staging/orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        StagingDirectory.sweep(root: scratch.storeRoot)

        #expect(FileManager.default.fileExists(atPath: live.url.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }
}

struct FingerprintTests {
    private func installed() async throws -> (Scratch, LocalModelStore, URL) {
        let scratch = try Scratch()
        let store = scratch.store()
        let directory = try await store.ensureAvailable(scratch.manifest)
        return (scratch, store, directory)
    }

    @Test func unchangedFilesAreNotRehashedAndAnyEditIs() async throws {
        let (scratch, store, directory) = try await installed()
        defer { scratch.cleanUp() }
        let manifest = scratch.manifest
        let inspections = await store.fullInspectionCount
        #expect(await store.verifiedInstallation(manifest) != nil)
        #expect(await store.fullInspectionCount == inspections)

        // Same inode, length and exact mtime: only ctime can reveal this edit.
        let file = directory.appendingPathComponent("weights.bin")
        var before = stat()
        #expect(lstat(file.path, &before) == 0)
        var bytes = try Data(contentsOf: file)
        bytes[0] ^= 0xFF
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: bytes)
        try handle.close()
        let times = [before.st_atimespec, before.st_mtimespec]
        #expect(utimensat(AT_FDCWD, file.path, times, 0) == 0)
        var after = stat()
        #expect(lstat(file.path, &after) == 0)
        #expect(after.st_ino == before.st_ino && after.st_size == before.st_size)
        #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)

        #expect(await store.fingerprintIsCurrent(manifest) == false)
        #expect(await store.verifiedInstallation(manifest) == nil)
    }

    @Test func aSymlinkAtAnArtifactPathIsNotVerified() async throws {
        let (scratch, store, directory) = try await installed()
        defer { scratch.cleanUp() }
        let manifest = scratch.manifest
        let file = directory.appendingPathComponent("weights.bin")
        let elsewhere = scratch.root.appendingPathComponent("elsewhere.bin")
        try FileManager.default.moveItem(at: file, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)

        let report = await store.verify(manifest)
        #expect(report.corrupted == ["weights.bin"])
    }

    @Test func aFailedHTTPStatusIsADownloadFailureNotCorruption() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitedUpstream.self]
        let store = LocalModelStore(
            rootDirectory: scratch.storeRoot, consumer: .test, session: URLSession(configuration: configuration))
        do {
            try await store.ensureAvailable(scratch.manifest)
            Issue.record("A 429 must fail the install")
        } catch let error as LocalModelStore.LocalModelStoreError {
            guard case .downloadFailed(_, let underlying) = error else {
                Issue.record("Expected downloadFailed, got \(error)")
                return
            }
            #expect(underlying == "HTTP 429")
        }
    }

    /// Runs over real HTTP, because `URLProtocol` stubs and URLSession's delegate
    /// callbacks do not behave the way a real transfer does.
    @Test func aRealHTTPDownloadReportsBytesInsideAnArtifact() async throws {
        let artifactBytes = 3 << 20
        let scratch = try Scratch(artifactBytes: artifactBytes)
        defer { scratch.cleanUp() }
        let server = try await LoopbackServer(root: scratch.upstream, pause: .milliseconds(800))
        defer { server.stop() }
        let manifest = scratch.manifest.served(from: try #require(URL(string: "http://127.0.0.1:\(server.port)")))
        let store = LocalModelStore(
            rootDirectory: scratch.storeRoot, consumer: .test, session: URLSession(configuration: .ephemeral))

        let events = Events()
        try await store.ensureAvailable(manifest) { events.add($0) }

        let all = events.all
        #expect(all.first == .verifying)
        #expect(all.last == .verifying, "the final hash pass is never reported as a download")
        let downloaded = all.compactMap { event -> Int? in
            if case .downloading(let progress) = event { progress.completedBytes } else { nil }
        }
        // Artifact boundaries are reported without any byte count, so only a value
        // inside an artifact proves bytes are reported.
        #expect(downloaded.contains { $0 % artifactBytes != 0 }, "\(downloaded)")
        #expect(await store.verify(manifest).isComplete)
    }

    @Test func cancellingARealDownloadThrowsCancellation() async throws {
        let scratch = try Scratch(artifactBytes: 3 << 20)
        defer { scratch.cleanUp() }
        let server = try await LoopbackServer(root: scratch.upstream, pause: .seconds(60))
        defer { server.stop() }
        let manifest = scratch.manifest.served(from: try #require(URL(string: "http://127.0.0.1:\(server.port)")))
        let store = LocalModelStore(
            rootDirectory: scratch.storeRoot, consumer: .test, session: URLSession(configuration: .ephemeral))

        let events = Events()
        let install = Task { try await store.ensureAvailable(manifest) { events.add($0) } }
        let deadline = ContinuousClock.now + .seconds(20)
        while !events.all.contains(where: { if case .downloading = $0 { true } else { false } }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        install.cancel()
        await #expect(throws: CancellationError.self) { try await install.value }
        #expect(scratch.stagingEntries().isEmpty)
    }

    @Test func cancellingDuringTheFinalPassIsNotReportedAsCorruption() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = scratch.store()
        let manifest = scratch.manifest
        let install = Task {
            try await store.ensureAvailable(manifest) { event in
                // Called on the installing task, right before the final hash pass.
                if case .downloading(let progress) = event, progress.currentPath.isEmpty {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        await #expect(throws: CancellationError.self) { try await install.value }
    }

    @Test func evidenceForOnePinSetSaysNothingAboutAnother() async throws {
        let (scratch, store, _) = try await installed()
        defer { scratch.cleanUp() }
        let original = scratch.manifest
        let repinned = ModelManifest(
            id: original.id,
            displayName: original.displayName,
            folderName: original.folderName,
            resolveBase: original.resolveBase,
            revision: original.revision,
            artifacts: original.artifacts.map {
                ModelArtifact(path: $0.path, sha256: String(repeating: "0", count: 64), sizeBytes: $0.sizeBytes)
            },
            minimumRAMGB: original.minimumRAMGB,
            license: original.license)

        #expect(await store.verifiedInstallation(original) != nil)
        #expect(await store.verifiedInstallation(repinned) == nil)

        let lifecycle = VerifiedModelLifecycle(store: store)
        #expect(await lifecycle.installation(for: original) != nil)
        #expect(await lifecycle.installation(for: repinned) == nil)
    }

    @Test func aFileRemovedWhileHashingIsNotVerified() async throws {
        let (scratch, _, directory) = try await installed()
        defer { scratch.cleanUp() }
        let file = directory.appendingPathComponent("weights.bin")

        let inspection = LocalModelStore.inspectFiles(of: scratch.manifest, at: directory) {
            try? FileManager.default.removeItem(at: file)
        }

        #expect(inspection.report.missing == ["weights.bin"])
        #expect(inspection.fingerprints == nil)
    }

    @Test func aFileReplacedWhileHashingIsNotVerified() async throws {
        let (scratch, _, directory) = try await installed()
        defer { scratch.cleanUp() }
        let file = directory.appendingPathComponent("vocab.json")

        let inspection = LocalModelStore.inspectFiles(of: scratch.manifest, at: directory) {
            try? Data(repeating: 0, count: 4096).write(to: file, options: .atomic)
        }

        #expect(inspection.report.corrupted == ["vocab.json"])
        #expect(inspection.fingerprints == nil)
    }

    @Test func aDanglingSymlinkIsRepairedInPlace() async throws {
        let (scratch, store, directory) = try await installed()
        defer { scratch.cleanUp() }
        let file = directory.appendingPathComponent("weights.bin")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
            at: file, withDestinationURL: scratch.root.appendingPathComponent("does-not-exist"))

        try await store.ensureAvailable(scratch.manifest)

        #expect(await store.verify(scratch.manifest).isComplete)
        #expect(!FileManager.default.fileExists(atPath: scratch.root.appendingPathComponent("does-not-exist").path))
    }
}

private final class LocalUpstream: URLProtocol, @unchecked Sendable {
    private static let directories = OSAllocatedUnfairLock<[String: URL]>(initialState: [:])

    static func register(_ directory: URL, host: String) {
        directories.withLock { $0[host] = directory }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let directory = url.host.flatMap { host in Self.directories.withLock { $0[host] } }
        guard let data = directory.flatMap({ try? Data(contentsOf: $0.appendingPathComponent(url.lastPathComponent)) }),
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": String(data.count)]) else {
            client.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data.prefix(data.count / 2))
        client.urlProtocol(self, didLoad: data.suffix(from: data.count / 2))
        client.urlProtocolDidFinishLoading(self)
    }
}

private final class RateLimitedUpstream: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client,
              let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: nil) else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data("Too many requests".utf8))
        client.urlProtocolDidFinishLoading(self)
    }
}
