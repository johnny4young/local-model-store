import Foundation
@testable import LocalModelStore
import Network

extension ModelManifest {
    func served(from base: URL) -> ModelManifest {
        ModelManifest(
            id: id, displayName: displayName, resolveBase: base, revision: revision,
            artifacts: artifacts, minimumRAMGB: minimumRAMGB, license: license)
    }
}

/// A minimal HTTP/1.1 file server on loopback. It sends half of each file, pauses
/// and sends the rest, so a test can see bytes arrive inside one artifact.
final class LoopbackServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-server")
    private let root: URL
    private let pause: Duration
    let port: UInt16

    init(root: URL, pause: Duration) async throws {
        self.root = root
        self.pause = pause
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        let queue = queue
        port = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [root, pause] connection in
                Self.serve(connection, root: root, pause: pause, queue: queue)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private static func serve(_ connection: NWConnection, root: URL, pause: Duration, queue: DispatchQueue) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            guard let body = try? Data(contentsOf: root.appendingPathComponent(String(path.dropFirst()))) else {
                connection.send(
                    content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            let half = body.count / 2
            connection.send(content: Data(head.utf8) + body.prefix(half), completion: .contentProcessed { _ in
                Task {
                    try? await Task.sleep(for: pause)
                    connection.send(
                        content: body.suffix(from: half),
                        completion: .contentProcessed { _ in connection.cancel() })
                }
            })
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
