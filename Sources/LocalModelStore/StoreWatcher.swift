import Foundation
import os

/// Watches `models/` and `claims/`. Those may not exist yet, and watching a store must
/// not create it, so until then it watches the nearest existing ancestor and re-arms.
final class StoreWatcher: Sendable {
    private let layout: StoreLayout
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "local-model-store.watcher")
    private let sources = OSAllocatedUnfairLock<[String: DispatchSourceFileSystemObject]>(initialState: [:])

    init(layout: StoreLayout, onChange: @escaping @Sendable () -> Void) {
        self.layout = layout
        self.onChange = onChange
    }

    func start() {
        queue.async { self.rearm() }
    }

    func stop() {
        let current = sources.withLock { state in
            defer { state = [:] }
            return state
        }
        for source in current.values { source.cancel() }
    }

    private func targets() -> Set<String> {
        let wanted = [layout.models, layout.claims]
        return Set(wanted.map { url in
            var candidate = url
            while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
                candidate.deleteLastPathComponent()
            }
            return candidate.path
        })
    }

    private func rearm() {
        let wanted = targets()
        let existing = sources.withLock { Set($0.keys) }
        for path in existing.subtracting(wanted) {
            let source = sources.withLock { $0.removeValue(forKey: path) }
            source?.cancel()
        }
        for path in wanted.subtracting(existing) {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
            source.setEventHandler { [weak self] in
                self?.rearm()
                self?.onChange()
            }
            source.setCancelHandler { close(descriptor) }
            sources.withLock { $0[path] = source }
            source.resume()
        }
    }
}
