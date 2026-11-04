import Foundation
import os

/// Downloads one file and reports its byte count. It polls the task because
/// `URLSession.download(from:delegate:)` never calls `didWriteData`, and a waiter
/// without byte progress would take a slow holder for a stalled one.
enum ArtifactDownload {
    private static let pollInterval: Duration = .milliseconds(250)
    private static let reportingStep: Int64 = 1 << 20

    private enum TaskState {
        case notStarted
        case running(URLSessionDownloadTask)
        case cancelled
    }

    /// Moves the file to `destination` before returning, because URLSession
    /// deletes its temporary file when the completion handler ends.
    static func run(
        session: URLSession,
        from source: URL,
        to destination: URL,
        onBytes: @escaping @Sendable (Int) -> Void
    ) async throws -> URLResponse {
        let state = OSAllocatedUnfairLock<TaskState>(initialState: .notStarted)
        let watcher = Task.detached {
            var reported: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard case .running(let task) = state.withLock({ $0 }) else { continue }
                let received = task.countOfBytesReceived
                if received - reported >= reportingStep {
                    reported = received
                    onBytes(Int(received))
                }
            }
        }
        let outcome: Result<URLResponse, any Error>
        do {
            outcome = .success(try await transfer(session: session, from: source, to: destination, state: state))
        } catch {
            outcome = .failure(error)
        }
        // Waited for, so no report lands after this returns, when another process may
        // hold the lock those reports are written to.
        watcher.cancel()
        await watcher.value
        return try outcome.get()
    }

    private static func transfer(
        session: URLSession,
        from source: URL,
        to destination: URL,
        state: OSAllocatedUnfairLock<TaskState>
    ) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: source) { location, response, error in
                    continuation.resume(
                        with: Result {
                            if let error { throw error }
                            guard let location, let response else { throw URLError(.badServerResponse) }
                            try FileManager.default.moveItem(at: location, to: destination)
                            return response
                        })
                }
                let cancelled = state.withLock { current -> Bool in
                    if case .cancelled = current { return true }
                    current = .running(task)
                    return false
                }
                if cancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            let running = state.withLock { current -> URLSessionDownloadTask? in
                defer { current = .cancelled }
                if case .running(let task) = current { return task }
                return nil
            }
            running?.cancel()
        }
    }
}
