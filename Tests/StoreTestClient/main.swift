import Foundation
import LocalModelStore

// A second real process for the multiprocess tests. It installs through the
// public store API from a fixture upstream and logs what it does.
func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: "--\(name)"),
          index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func log(_ line: String) {
    guard let path = argument("log") else { return }
    let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return }
    _ = "\(line)\n".withCString { write(descriptor, $0, strlen($0)) }
    close(descriptor)
}

/// Serves artifact bytes from a directory and logs each request. With a hold
/// file, it serves nothing until that file exists, or only that one name with
/// `--hold-only`, so a test decides the timing.
final class FixtureUpstream: URLProtocol, @unchecked Sendable {
    // Read-only after launch; URLProtocol instances are created by URLSession.
    nonisolated(unsafe) static var directory = URL(fileURLWithPath: "/")
    nonisolated(unsafe) static var holdFile: String?
    nonisolated(unsafe) static var holdOnly: String?
    private let queue = DispatchQueue(label: "fixture-upstream")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        log("download \(url.path) \(getpid())")
        let file = Self.directory.appendingPathComponent(String(url.path.dropFirst()))
        guard let data = try? Data(contentsOf: file),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        queue.async { [self] in
            while let hold = Self.holdFile, Self.holdOnly == nil || Self.holdOnly == url.lastPathComponent,
                  !FileManager.default.fileExists(atPath: hold) {
                Thread.sleep(forTimeInterval: 0.01)
            }
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

guard let root = argument("root"), let manifestPath = argument("manifest"), let upstream = argument("upstream") else {
    fatalError("usage: store-test-client --root R --manifest M --upstream U [--log L] [--hold-file F] [--hold-only NAME] [--stall-ms N] [--consumer C] [--hold-lease] [--crash-after-publish]")
}
FixtureUpstream.directory = URL(fileURLWithPath: upstream, isDirectory: true)
FixtureUpstream.holdFile = argument("hold-file")
FixtureUpstream.holdOnly = argument("hold-only")

let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [FixtureUpstream.self]

var policy = LocalModelStore.WaitPolicy()
policy.pollInterval = .milliseconds(10)
if let stall = argument("stall-ms"), let milliseconds = Int(stall) {
    policy.stallTimeout = .milliseconds(milliseconds)
}
if CommandLine.arguments.contains("--crash-after-publish") {
    policy.afterPublish = { _exit(9) }
}
let store = try LocalModelStore(
    location: .directory(URL(fileURLWithPath: root, isDirectory: true)),
    consumer: StoreConsumer(bundleID: argument("consumer") ?? "com.example.client", displayName: "Client"),
    session: URLSession(configuration: configuration),
    waitPolicy: policy)

do {
    let directory = try await store.ensureAvailable(manifest) { event in
        if case .waitingForOtherProcess = event { log("waiting \(getpid())") }
    }
    log("installed \(getpid())")
    print(directory.path)
    if CommandLine.arguments.contains("--hold-lease") {
        let lease = try await store.lease(manifest)
        log("leased \(getpid())")
        withExtendedLifetime(lease) {
            while true { sleep(60) }
        }
    }
} catch {
    log("failed \(getpid()) \(error)")
    exit(1)
}
