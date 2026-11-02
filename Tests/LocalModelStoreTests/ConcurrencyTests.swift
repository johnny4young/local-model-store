import Foundation
@testable import LocalModelStore
import Testing

/// A scratch store plus a fixture upstream and manifest. Never touches a real store.
private struct Scratch {
    let root: URL
    let upstream: URL
    let manifest: ModelManifest
    let manifestFile: URL
    let log: URL
    let storeRoot: URL

    init(artifactBytes: Int = 4096) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-model-store-concurrency-\(UUID().uuidString)", isDirectory: true)
        upstream = root.appendingPathComponent("upstream", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        log = root.appendingPathComponent("events.log")
        manifestFile = root.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)

        var artifacts: [ModelArtifact] = []
        for name in ["weights.bin", "vocab.json"] {
            let file = upstream.appendingPathComponent(name)
            try Data((0..<artifactBytes).map { UInt8($0 % 251) }).write(to: file)
            artifacts.append(
                ModelArtifact(path: name, sha256: try LocalModelStore.sha256(of: file), sizeBytes: artifactBytes))
        }
        manifest = ModelManifest(
            id: "fixture",
            displayName: "Fixture",
            folderName: "fixture",
            resolveBase: try #require(URL(string: "https://fixture.invalid")),
            revision: "rev1",
            artifacts: artifacts,
            minimumRAMGB: 0,
            license: "MIT")
        try JSONEncoder().encode(manifest).write(to: manifestFile)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    var events: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func downloads(of name: String) -> Int {
        events.filter { $0.hasPrefix("download /\(name) ") }.count
    }

    func client(chunkMilliseconds: Int = 0, stallMilliseconds: Int? = nil) throws -> Process {
        let process = Process()
        process.executableURL = try clientExecutable()
        var arguments = [
            "--root", storeRoot.path, "--manifest", manifestFile.path, "--upstream", upstream.path,
            "--log", log.path, "--chunk-ms", String(chunkMilliseconds)
        ]
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

private actor Events {
    private(set) var all: [LocalModelStore.InstallEvent] = []
    func add(_ event: LocalModelStore.InstallEvent) { all.append(event) }
}

struct MultiprocessInstallTests {
    @Test func twoProcessesDownloadOnceAndBothSucceed() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let first = try scratch.client(chunkMilliseconds: 40)
        try await scratch.waitForEvent(prefix: "download ")
        let second = try scratch.client(chunkMilliseconds: 40)
        await finish(first)
        await finish(second)

        #expect(first.terminationStatus == 0)
        #expect(second.terminationStatus == 0)
        for artifact in scratch.manifest.artifacts {
            #expect(scratch.downloads(of: artifact.path) == 1, "\(scratch.events)")
        }
        #expect(scratch.events.contains { $0.hasPrefix("waiting ") }, "the second process must wait")
        #expect(scratch.events.filter { $0.hasPrefix("installed ") }.count == 2)
        #expect(scratch.stagingEntries().isEmpty)
    }

    @Test func aKilledHolderReleasesTheLockAndItsWorkIsSwept() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let holder = try scratch.client(chunkMilliseconds: 2_000)
        try await scratch.waitForEvent(prefix: "download ")
        holder.terminate()
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
        let stalled = try scratch.client(chunkMilliseconds: 2_000)
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
            try await store.ensureAvailable(manifest) { event in Task { await events.add(event) } }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while await !events.all.contains(where: { if case .waitingForOtherProcess = $0 { true } else { false } }),
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalUpstream.self]
        LocalUpstream.register(scratch.upstream, for: scratch.manifest.id)
        let manifest = scratch.manifest
        let store = LocalModelStore(
            rootDirectory: scratch.storeRoot, consumer: .test, session: URLSession(configuration: configuration))
        let directory = try await store.ensureAvailable(manifest)
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

    @Test func downloadsReportByteProgress() async throws {
        let scratch = try Scratch(artifactBytes: 256 * 1024)
        defer { scratch.cleanUp() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalUpstream.self]
        LocalUpstream.register(scratch.upstream, for: scratch.manifest.id)
        let store = LocalModelStore(
            rootDirectory: scratch.storeRoot, consumer: .test, session: URLSession(configuration: configuration))
        let events = Events()
        try await store.ensureAvailable(scratch.manifest) { event in Task { await events.add(event) } }
        try await Task.sleep(for: .milliseconds(50))
        let all = await events.all
        #expect(all.first == .verifying)
        let downloaded = all.compactMap { event -> Int? in
            if case .downloading(let progress) = event { progress.completedBytes } else { nil }
        }
        #expect(downloaded.contains { $0 > 0 && $0 < scratch.manifest.totalSizeBytes }, "\(downloaded)")
    }
}

private final class LocalUpstream: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var directories: [URL] = []

    static func register(_ directory: URL, for _: String) {
        lock.withLock { directories.append(directory) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let candidates = Self.lock.withLock { Self.directories }
        let data = candidates.lazy.compactMap { try? Data(contentsOf: $0.appendingPathComponent(url.lastPathComponent)) }.last
        guard let data, let response = HTTPURLResponse(
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
