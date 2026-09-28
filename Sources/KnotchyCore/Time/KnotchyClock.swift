/// `ContinuousClock` keeps counting while the Mac sleeps, so an expired idle countdown fires on wake.
public protocol KnotchyClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

public struct SystemClock: KnotchyClock {
    public init() {}

    public var now: ContinuousClock.Instant { .now }

    public func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await Task.sleep(until: deadline, clock: .continuous)
    }
}
