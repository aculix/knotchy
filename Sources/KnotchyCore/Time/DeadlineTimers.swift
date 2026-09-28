/// Tests call `fireDue()` after advancing a `TestClock`; firing is idempotent for a given `now`.
@MainActor
final class DeadlineTimers<Key: Hashable & Sendable> {
    var onFire: @MainActor (Key) -> Void = { _ in }

    private struct Entry {
        var deadline: ContinuousClock.Instant
        var order: Int
    }

    private let clock: any KnotchyClock
    private var entries: [Key: Entry] = [:]
    private var nextOrder = 0
    private var driver: Task<Void, Never>?

    init(clock: any KnotchyClock) {
        self.clock = clock
    }

    isolated deinit {
        driver?.cancel()
    }

    func set(_ key: Key, after duration: Duration) {
        set(key, at: clock.now + duration)
    }

    func set(_ key: Key, at deadline: ContinuousClock.Instant) {
        nextOrder += 1
        entries[key] = Entry(deadline: deadline, order: nextOrder)
        reschedule()
    }

    func cancel(_ key: Key) {
        guard entries.removeValue(forKey: key) != nil else { return }
        reschedule()
    }

    func deadline(of key: Key) -> ContinuousClock.Instant? {
        entries[key]?.deadline
    }

    /// Keys `onFire` re-arms at or before `now` fire in this same pass; doing that every time loops forever.
    func fireDue() {
        let now = clock.now
        while let (key, _) = entries
            .filter({ $0.value.deadline <= now })
            .min(by: { ($0.value.deadline, $0.value.order) < ($1.value.deadline, $1.value.order) }) {
            entries[key] = nil
            onFire(key)
        }
        reschedule()
    }

    private func reschedule() {
        driver?.cancel()
        guard let next = entries.values.map(\.deadline).min() else {
            driver = nil
            return
        }
        driver = Task { [weak self, clock] in
            do { try await clock.sleep(until: next) } catch { return }
            guard !Task.isCancelled else { return }   // Replaced while waking up.
            self?.fireDue()
        }
    }
}
