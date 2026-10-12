import Foundation
import TickRestCore

/// One ordered writer for both deferred appearance edits and explicit saves.
/// Encoding and disk I/O run off the UI thread. A flush supersedes pending
/// edits, waits for any in-flight save, and cannot be overwritten by older data.
final class DebouncedStateWriter {
    private let queue = DispatchQueue(label: "tickrest.state-writer", qos: .utility)
    private let delay: TimeInterval
    private let save: (SavedData) throws -> Void
    private var pending: DispatchWorkItem?
    private var generation = 0

    init(delay: TimeInterval = 0.35, save: @escaping (SavedData) throws -> Void) {
        self.delay = delay; self.save = save
    }

    func schedule(_ data: SavedData, onError: @escaping (Error) -> Void) {
        queue.async { [self] in
            generation += 1
            let expected = generation
            pending?.cancel()
            let task = DispatchWorkItem { [weak self] in
                guard let self, generation == expected else { return }
                pending = nil
                do { try save(data) }
                catch { DispatchQueue.main.async { onError(error) } }
            }
            pending = task
            queue.asyncAfter(deadline: .now() + delay, execute: task)
        }
    }

    func flush(_ data: SavedData) throws {
        try queue.sync {
            generation += 1; pending?.cancel(); pending = nil
            try save(data)
        }
    }
}
