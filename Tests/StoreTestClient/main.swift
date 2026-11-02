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

/// Serves artifact bytes from a directory, in slow chunks when asked, and logs each request.
final class FixtureUpstream: URLProtocol, @unchecked Sendable {
    // Read-only after launch; URLProtocol instances are created by URLSession.
    nonisolated(unsafe) static var directory = URL(fileURLWithPath: "/")
    nonisolated(unsafe) static var chunkDelay: TimeInterval = 0
    private let queue = DispatchQueue(label: "fixture-upstream")
    private var stopped = false

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
            let chunk = max(1, data.count / 8)
            for start in stride(from: 0, to: data.count, by: chunk) where !stopped {
                Thread.sleep(forTimeInterval: Self.chunkDelay)
                client.urlProtocol(self, didLoad: data.subdata(in: start..<min(start + chunk, data.count)))
            }
            if !stopped { client.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        queue.async { [self] in stopped = true }
    }
}

guard let root = argument("root"), let manifestPath = argument("manifest"), let upstream = argument("upstream") else {
    fatalError("usage: store-test-client --root R --manifest M --upstream U [--log L] [--chunk-ms N] [--stall-ms N]")
}
FixtureUpstream.directory = URL(fileURLWithPath: upstream, isDirectory: true)
FixtureUpstream.chunkDelay = (Double(argument("chunk-ms") ?? "0") ?? 0) / 1000

let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [FixtureUpstream.self]

var policy = LocalModelStore.WaitPolicy()
policy.pollInterval = .milliseconds(10)
if let stall = argument("stall-ms"), let milliseconds = Int(stall) {
    policy.stallTimeout = .milliseconds(milliseconds)
}
let store = LocalModelStore(
    rootDirectory: URL(fileURLWithPath: root, isDirectory: true),
    consumer: StoreConsumer(bundleID: argument("consumer") ?? "com.example.client", displayName: "Client"),
    session: URLSession(configuration: configuration),
    waitPolicy: policy)

do {
    let directory = try await store.ensureAvailable(manifest) { event in
        if case .waitingForOtherProcess = event { log("waiting \(getpid())") }
    }
    log("installed \(getpid())")
    print(directory.path)
} catch {
    log("failed \(getpid()) \(error)")
    exit(1)
}
