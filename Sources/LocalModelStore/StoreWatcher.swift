import Foundation
import os

/// Watches `models/` and `claims/`. Those may not exist yet, and watching a store must
/// not create it, so until then it watches the nearest existing ancestor and re-arms.
final class StoreWatcher: Sendable {
    private struct State {
        var isStopped = false
        var sources: [String: DispatchSourceFileSystemObject] = [:]
    }

    private let layout: StoreLayout
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "local-model-store.watcher")
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(layout: StoreLayout, onChange: @escaping @Sendable () -> Void) {
        self.layout = layout
        self.onChange = onChange
    }

    /// Armed before returning, so a change right after subscribing is never missed.
    func start() {
        queue.sync { rearm() }
    }

    func stop() {
        let current = state.withLock { state in
            state.isStopped = true
            defer { state.sources = [:] }
            return state.sources
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

    /// Checks again after arming: a directory that appears while an ancestor's source
    /// is being set up fires no event, and the watcher would stay on the ancestor.
    private func rearm() {
        for _ in 0..<8 {
            let wanted = targets()
            let current = state.withLock { $0.isStopped ? nil : Set($0.sources.keys) }
            guard let current, current != wanted else { return }
            for path in current.subtracting(wanted) { drop(path) }
            for path in wanted.subtracting(current) { watch(path) }
        }
    }

    private func drop(_ path: String) {
        state.withLock { $0.sources.removeValue(forKey: path) }?.cancel()
    }

    private func watch(_ path: String) {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            // The descriptor follows the old inode, so a replaced directory needs a new one.
            if !source.data.isDisjoint(with: [.rename, .delete]) { self.drop(path) }
            self.rearm()
            self.onChange()
        }
        source.setCancelHandler { close(descriptor) }
        // After `stop()`, a queued event must not leave a source nobody will cancel.
        let added = state.withLock { state -> Bool in
            guard !state.isStopped else { return false }
            state.sources[path] = source
            return true
        }
        source.resume()
        if !added { source.cancel() }
    }
}
