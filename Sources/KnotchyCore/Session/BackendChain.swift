import Synchronization

/// Runs async jobs one at a time, in order, so backend operations never overlap.
@MainActor
final class BackendChain {
    private var tail: Task<Void, Never>?
    private(set) var isClosed = false

    func enqueue(_ job: @escaping @MainActor () async -> Void) {
        guard !isClosed else { return }
        let previous = tail
        tail = Task {
            await previous?.value
            guard !self.isClosed else { return }
            await job()
        }
    }

    func close() {
        isClosed = true
    }

    func waitUntilIdle() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }
}

/// Every VM ID from its `start` being queued until its destroy is confirmed.
/// Lock-protected: the quit path reads it off the main actor.
public final class LiveIDs: Sendable {
    private let ids = Mutex<Set<String>>([])

    public init() {}

    public var snapshot: Set<String> {
        ids.withLock { $0 }
    }

    func insert(_ id: String) {
        _ = ids.withLock { $0.insert(id) }
    }

    func remove(_ id: String) {
        _ = ids.withLock { $0.remove(id) }
    }
}
