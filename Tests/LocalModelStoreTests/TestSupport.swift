import Foundation
@testable import LocalModelStore
import os
import Testing

extension StoreConsumer {
    static let test = StoreConsumer(bundleID: "com.example.test", displayName: "Test")
}

/// A scratch store plus a fixture upstream and manifest. Never touches a real store.
struct Scratch {
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
        for (fill, name) in [(UInt8(0x5A), "weights.bin"), (UInt8(0xA5), "vocab.json")] {
            let file = upstream.appendingPathComponent(name)
            try Data(repeating: fill, count: artifactBytes).write(to: file)
            artifacts.append(
                ModelArtifact(path: name, sha256: try LocalModelStore.sha256(of: file), sizeBytes: artifactBytes))
        }
        manifest = ModelManifest(
            id: "fixture",
            displayName: "Fixture",
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
    func store() throws -> LocalModelStore {
        if let host = manifest.resolveBase.host { LocalUpstream.register(upstream, host: host) }
        return try LocalModelStore(location: .directory(storeRoot), consumer: .test, session: localSession())
    }

    func localSession() -> URLSession {
        if let host = manifest.resolveBase.host { LocalUpstream.register(upstream, host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalUpstream.self]
        return URLSession(configuration: configuration)
    }

    var requests: [String] {
        manifest.resolveBase.host.map { LocalUpstream.requests(host: $0) } ?? []
    }

    var layout: StoreLayout { StoreLayout(root: storeRoot) }
    var lockFile: URL { layout.installLock(manifest.storeKey) }

    var events: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func downloads(of name: String) -> Int {
        events.filter { $0.hasPrefix("download /\(name) ") }.count
    }

    func releaseUpstream() throws {
        try Data().write(to: holdFile)
    }

    func client(held: Bool = false, stallMilliseconds: Int? = nil, extra: [String] = []) throws -> Process {
        let process = Process()
        process.executableURL = try clientExecutable()
        var arguments = [
            "--root", storeRoot.path, "--manifest", manifestFile.path, "--upstream", upstream.path,
            "--log", log.path
        ]
        if held { arguments += ["--hold-file", holdFile.path] }
        if let stallMilliseconds { arguments += ["--stall-ms", String(stallMilliseconds)] }
        process.arguments = arguments + extra
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
        let staging = layout.version.appendingPathComponent("staging")
        return (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
    }
}

private final class BundleAnchor {}

private func clientExecutable() throws -> URL {
    let products = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
    let url = products.appendingPathComponent("store-test-client")
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "missing \(url.path)")
    return url
}

private func run(_ tool: String, _ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "\(tool) \(arguments)")
}

/// A real volume from a disk image, for file systems with no `clonefile` and,
/// as on exFAT, no `RENAME_EXCL` or `RENAME_SWAP`.
struct ScratchVolume {
    let mount: URL

    init(fileSystem: String, in root: URL) throws {
        let image = root.appendingPathComponent("volume.dmg")
        mount = root.appendingPathComponent("mount", isDirectory: true)
        try run("/usr/bin/hdiutil", "create", "-quiet", "-size", "128m", "-fs", fileSystem, "-volname", "LMSTest", image.path)
        try run("/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path)
    }

    func detach() {
        try? run("/usr/bin/hdiutil", "detach", "-quiet", "-force", mount.path)
    }
}

final class TestClock: Sendable {
    private let date: OSAllocatedUnfairLock<Date>
    var now: Date { date.withLock { $0 } }

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        date = OSAllocatedUnfairLock(initialState: start)
    }

    func advance(days: Double) { date.withLock { $0 += days * 24 * 60 * 60 } }
}

func finish(_ process: Process) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            process.waitUntilExit()
            continuation.resume()
        }
    }
}

/// Collects events synchronously, so their order is the order they were emitted.
final class Events: Sendable {
    private let state = OSAllocatedUnfairLock<[LocalModelStore.InstallEvent]>(initialState: [])
    var all: [LocalModelStore.InstallEvent] { state.withLock { $0 } }
    func add(_ event: LocalModelStore.InstallEvent) { state.withLock { $0.append(event) } }
}

class LocalUpstream: URLProtocol, @unchecked Sendable {
    private static let directories = OSAllocatedUnfairLock<[String: URL]>(initialState: [:])
    private static let seen = OSAllocatedUnfairLock<[String: [String]]>(initialState: [:])

    static func requests(host: String) -> [String] {
        seen.withLock { $0[host] ?? [] }
    }

    static func record(_ url: URL) {
        if let host = url.host { seen.withLock { $0[host, default: []].append(String(url.path.dropFirst())) } }
    }

    static func register(_ directory: URL, host: String) {
        directories.withLock { $0[host] = directory }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.record(url)
        let directory = url.host.flatMap { host in Self.directories.withLock { $0[host] } }
        guard let data = directory.flatMap({ try? Data(contentsOf: $0.appendingPathComponent(String(url.path.dropFirst()))) }),
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

final class RateLimitedUpstream: URLProtocol, @unchecked Sendable {
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
