/// When the setup window opens by itself at launch.
public enum SetupLaunchRule {
    public static let completedKey = "setupCompleted"

    public static func shouldOpen(hostSupported: Bool, setupCompleted: Bool, runtime: RuntimeStatus) -> Bool {
        guard hostSupported, setupCompleted else { return true }
        switch runtime {
        case .missing, .outdated: return true
        case .current: return false
        }
    }
}
