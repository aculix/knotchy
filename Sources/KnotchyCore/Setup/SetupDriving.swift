/// What the setup flow needs from the session controller.
@MainActor
public protocol SetupDriving: AnyObject {
    var state: SessionState { get }
    var setupLog: String? { get }
    var setupOutput: [String] { get }
    func runtimeStatus() async -> RuntimeStatus
    func checkSetup() async -> SetupRunOutcome?
    func runSetup(_ issue: SetupIssue, continuing: Bool) async -> SetupRunOutcome?
    func beginRuntimeInstall(replacing found: String?) async -> Result<Void, RuntimeHoldRefusal>
    func finishRuntimeInstall(_ result: RuntimeInstallResult) async -> SetupRunOutcome
    func waitWhileSettingUp() async
}

extension SessionController: SetupDriving {}
