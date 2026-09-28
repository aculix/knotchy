/// How a setup run started by the setup window ended.
public enum SetupRunOutcome: Equatable, Sendable {
    /// Preflight is ready; a waiting link may have started.
    case ready
    /// Stopped at an issue this kind of run doesn't fix.
    case needs(SetupIssue)
    case failed(SetupIssue, String)
}

public enum RuntimeHoldRefusal: Error, Equatable, Sendable {
    case sessionOpen
    case setupRunning
    case stopFailed(String)
}

public enum RuntimeInstallResult: Equatable, Sendable {
    case installed
    case cancelled
    case failed(String)
}
