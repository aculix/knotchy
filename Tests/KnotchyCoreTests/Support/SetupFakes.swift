import Foundation
import Synchronization
@testable import KnotchyCore

final class FakeHost: HostChecking {
    private let value = Mutex(HostFacts(unsupported: nil, osVersion: "macOS 27.0", bytesFree: 212_000_000_000))

    var current: HostFacts {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }

    func facts() async -> HostFacts { current }
}

@MainActor
final class FakeInstallerSession: InstallerSession {
    var hasQuit: Bool

    nonisolated init(hasQuit: Bool = true) {
        self.hasQuit = hasQuit
    }
}

final class FakeInstaller: RuntimeInstalling {
    enum Opening: Sendable {
        case opened
        case changed
        case failed(String)
    }

    private struct State {
        var downloadError: DownloadError?
        var opening: Opening = .opened
        var calls: [String] = []
    }

    private let state = Mutex(State())
    /// What `.opened` hands out; it has already quit unless a test says otherwise.
    let session = FakeInstallerSession()

    var calls: [String] { state.withLock { $0.calls } }
    func failDownload(with error: DownloadError) { state.withLock { $0.downloadError = error } }
    func open(with opening: Opening) { state.withLock { $0.opening = opening } }

    func download(_ release: ContainerRuntime.Release,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> DownloadedPackage {
        let error = state.withLock { s -> DownloadError? in
            s.calls.append("download")
            return s.downloadError
        }
        if let error { throw error }
        return DownloadedPackage(directory: URL(fileURLWithPath: "/fake/knotchy-runtime"), name: release.url.lastPathComponent)
    }

    @MainActor
    func openInInstaller(_ package: DownloadedPackage, release: ContainerRuntime.Release) async -> InstallerOpening {
        let opening = state.withLock { s -> Opening in
            s.calls.append("open")
            return s.opening
        }
        switch opening {
        case .opened: return .opened(session)
        case .changed: return .changed
        case .failed(let message): return .failed(message)
        }
    }

    func discard(_ package: DownloadedPackage) {
        state.withLock { $0.calls.append("discard") }
    }
}

@MainActor
final class FakeSetupDriver: SetupDriving {
    var state: SessionState = .idle
    var setupLog: String?
    var setupOutput: [String] = []
    /// Used in order; the last one repeats.
    var runtimeStatuses: [RuntimeStatus] = [.current("1.4.1")]
    /// Used in order; then `.ready`.
    var checkResults: [SetupRunOutcome?] = []
    var runResults: [SetupRunOutcome?] = []
    var holdResult: Result<Void, RuntimeHoldRefusal> = .success(())
    var finishResult: SetupRunOutcome = .ready
    private(set) var calls: [String] = []

    func runtimeStatus() async -> RuntimeStatus {
        calls.append("runtimeStatus")
        return runtimeStatuses.count > 1 ? runtimeStatuses.removeFirst() : runtimeStatuses[0]
    }

    func checkSetup() async -> SetupRunOutcome? {
        calls.append("checkSetup")
        return checkResults.isEmpty ? .ready : checkResults.removeFirst()
    }

    func runSetup(_ issue: SetupIssue, continuing: Bool) async -> SetupRunOutcome? {
        calls.append("runSetup(\(issue), continuing: \(continuing))")
        return runResults.isEmpty ? .ready : runResults.removeFirst()
    }

    func beginRuntimeInstall(replacing found: String?) async -> Result<Void, RuntimeHoldRefusal> {
        calls.append("begin(\(found ?? "nil"))")
        return holdResult
    }

    func finishRuntimeInstall(_ result: RuntimeInstallResult) async -> SetupRunOutcome {
        calls.append("finish(\(result))")
        return finishResult
    }

    func waitWhileSettingUp() async {
        calls.append("wait")
        state = .idle
    }
}
