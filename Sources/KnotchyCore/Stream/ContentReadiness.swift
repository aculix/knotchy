/// Decides when Starting ends. Frames and progress before NAVIGATED come from the agent's
/// about:blank bootstrap and never count; `afterHello` is a backstop if NAVIGATED never arrives.
public struct ContentReadiness: Sendable {
    public static let afterNavigated: Duration = .seconds(15)
    public static let afterHello: Duration = .seconds(25)

    public private(set) var isReady = false
    private var helloAt: ContinuousClock.Instant?
    private var navigatedAt: ContinuousClock.Instant?

    public init() {}

    public mutating func hello(at now: ContinuousClock.Instant) {
        if helloAt == nil { helloAt = now }
    }

    public mutating func navigated(at now: ContinuousClock.Instant) {
        if navigatedAt == nil { navigatedAt = now }
    }

    public mutating func frame(isUniform: Bool) {
        if navigatedAt != nil, !isUniform { isReady = true }
    }

    public mutating func progress(_ percent: Int) {
        if navigatedAt != nil, percent >= 100 { isReady = true }
    }

    public mutating func tick(now: ContinuousClock.Instant) {
        if let deadline = nextDeadline, now >= deadline { isReady = true }
    }

    public var nextDeadline: ContinuousClock.Instant? {
        guard !isReady else { return nil }
        return [navigatedAt.map { $0 + Self.afterNavigated }, helloAt.map { $0 + Self.afterHello }]
            .compactMap { $0 }
            .min()
    }
}
