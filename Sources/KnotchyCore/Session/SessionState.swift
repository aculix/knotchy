public enum SessionState: Equatable, Sendable {
    case idle
    case starting(StartStep, folded: Bool)
    case live(LiveMode)
    case destroying
    case destroyed
    case failed(SessionFailure)
    case setupRequired(SetupIssue, error: String?)
    case settingUp(SetupIssue)
}

public enum StartStep: Sendable {
    case booting
    /// Waiting for HELLO.
    case connecting
    /// Waiting for `ContentReadiness`.
    case loading
}

public enum LiveMode: Sendable {
    case peek
    case expanded
    case collapsed
}

public enum SessionFailure: Equatable, Sendable {
    case start(String)
    case ended(EndReason)
    /// The VM stays on the pending-cleanup list.
    case destroyStuck
}

/// A transient pill, shown whatever the state.
public enum Notice: Equatable, Sendable {
    case noWebLink
}
