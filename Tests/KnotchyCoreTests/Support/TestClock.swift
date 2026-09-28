import Synchronization
@testable import KnotchyCore

final class TestClock: KnotchyClock {
    private struct Sleeper {
        let id: Int
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: ContinuousClock.Instant
        var nextID = 0
        var sleepers: [Sleeper] = []
    }

    private let state: Mutex<State>

    init(now: ContinuousClock.Instant = .now) {
        state = Mutex(State(now: now))
    }

    var now: ContinuousClock.Instant {
        state.withLock { $0.now }
    }

    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { s in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= s.now { return .success(()) }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper = state.withLock { s -> Sleeper? in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// The woken tasks run concurrently, in no particular order.
    func advance(by duration: Duration) {
        let due = state.withLock { s -> [Sleeper] in
            s.now += duration
            let now = s.now
            let due = s.sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
