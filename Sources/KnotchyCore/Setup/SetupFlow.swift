import Foundation
import Observation

/// The setup window's rows and the order of its steps. The window binds only to this.
@MainActor
@Observable
public final class SetupFlow {
    public enum Status: Equatable, Sendable {
        case pending(String)
        case running(String, fraction: Double?)
        case done(String)
        case failed(String, details: [String])
    }

    public enum RuntimeAction: Equatable, Sendable {
        case install
        case update
    }

    /// The build peaks at about 9 GB: the builder alone takes 4 GB until it is deleted. About 5 GB stays in use.
    public static let requiredFreeBytes: Int64 = 10_000_000_000
    static let vmDetail = "About 3 minutes · downloads about 225 MB"
    static let kernelDownloading = "Downloading the Linux kernel…"

    public private(set) var mac: Status = .pending("Checking…")
    public private(set) var unsupported: Unsupported?
    public private(set) var runtimeAction: RuntimeAction?
    public private(set) var isRunning = false
    /// Quitting now leaves a partial download behind.
    @ObservationIgnored public private(set) var isDownloading = false
    private var runtimeBase: Status = .pending("")
    private var vmBase: Status = .pending(SetupFlow.vmDetail)

    @ObservationIgnored private let host: any HostChecking
    @ObservationIgnored private let installer: any RuntimeInstalling
    @ObservationIgnored private let driver: any SetupDriving
    @ObservationIgnored private let release: ContainerRuntime.Release
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private var facts: HostFacts?
    @ObservationIgnored private var runtimeStatus: RuntimeStatus?

    public init(host: any HostChecking, installer: any RuntimeInstalling, driver: any SetupDriving,
                release: ContainerRuntime.Release = ContainerRuntime.pinned, retryDelay: Duration = .milliseconds(500)) {
        self.host = host
        self.installer = installer
        self.driver = driver
        self.release = release
        self.retryDelay = retryDelay
        runtimeBase = .pending(Self.installDetail(release))
    }

    // MARK: - Rows

    /// With the controller's live progress on top, so a setup the notch started shows here too.
    public var runtime: Status {
        switch driver.state {
        case .settingUp(.serviceStopped): return .running("Starting the runtime…", fraction: nil)
        case .settingUp(.kernelMissing): return .running(driver.setupLog ?? Self.kernelDownloading, fraction: nil)
        default: return runtimeBase
        }
    }

    public var vm: Status {
        if case .settingUp(let issue) = driver.state, Self.isImageIssue(issue) {
            return .running(driver.setupLog ?? "Starting the build…", fraction: nil)
        }
        return vmBase
    }

    public var allRequiredDone: Bool {
        if case .done = mac, case .done = runtime, case .done = vm { return true }
        return false
    }

    public var canSetUp: Bool {
        guard !isRunning, unsupported == nil, !allRequiredDone else { return false }
        if case .failed = mac { return false }
        return true
    }

    // MARK: - Actions

    @ObservationIgnored private var work: Task<Void, Never>?

    /// For the Set Up and Try Again buttons: runs `setUp()` where quitting can cancel it.
    public func start() {
        guard !isRunning else { return }
        work = Task { await setUp() }
    }

    /// Quitting: stops a download. An open Installer is left to finish.
    public func cancel() {
        work?.cancel()
    }

    /// Re-checks everything. Starts a stopped service, as a link would, but never installs or builds.
    public func refresh() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        await inspect()
    }

    /// The Set Up and Try Again buttons: runs whatever is left, in order.
    public func setUp() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        await inspect()
        guard unsupported == nil else { return }
        // The service didn't start: building would only try again.
        if case .failed = runtimeBase { return }
        if case .failed = mac { return }
        if let action = runtimeAction {
            await installRuntime(action)
        } else if case .done = vmBase {
            return
        } else {
            await buildVM()
        }
        updateMac()
    }

    // MARK: - Steps

    private func inspect() async {
        let facts = await host.facts()
        self.facts = facts
        unsupported = facts.unsupported
        guard unsupported == nil else { return }
        let status = await driver.runtimeStatus()
        runtimeStatus = status
        switch status {
        case .missing:
            runtimeAction = .install
            runtimeBase = .pending(Self.installDetail(release))
            vmBase = .pending(Self.vmDetail)
        case .outdated(let found):
            runtimeAction = .update
            runtimeBase = .pending("container \(found) is too old · updates to \(release.version) with Apple's Installer")
            vmBase = .pending(Self.vmDetail)
        case .current(let version):
            runtimeAction = nil
            runtimeBase = .done(Self.installedText(version))
            switch await driver.checkSetup() {
            case .ready?: vmBase = .done("Ready")
            case .needs(let issue)? where Self.isImageIssue(issue): vmBase = .pending(Self.vmDetail)
            case .needs(.kernelMissing)?:
                runtimeBase = .pending(Self.kernelDetail(version))
                vmBase = .pending(Self.vmDetail)
            case .failed(let issue, let message)?: fail(issue, message)
            case nil where Self.isBrowserOpen(driver.state): vmBase = .done("Ready")   // A running VM has an image.
            case .needs?, nil: break   // Busy, or the runtime row's business: the live rows show it.
            }
        }
        updateMac()
    }

    private func installRuntime(_ action: RuntimeAction) async {
        switch driver.state {
        case .starting, .live:
            runtimeBase = .failed("Close the Knotchy browser first.", details: [])
            return
        case .destroying, .failed(.destroyStuck):
            runtimeBase = .failed("Wait for the Knotchy browser to finish closing, then try again.", details: [])
            return
        default:
            break
        }
        runtimeBase = .running(Self.downloadText(0, of: release.size), fraction: 0)
        let package: DownloadedPackage
        do {
            package = try await download()
        } catch DownloadError.mismatch {
            runtimeBase = .failed("The download didn't match the expected package, so it wasn't installed.", details: [])
            return
        } catch {
            runtimeBase = .failed("Couldn't download the runtime. Check your connection and try again.",
                                  details: [String(describing: error)])
            return
        }
        let found: String? = if case .outdated(let version) = runtimeStatus { version } else { nil }
        let hold = await driver.beginRuntimeInstall(replacing: found)
        if case .failure = hold { installer.discard(package) }
        switch hold {
        case .success:
            break
        case .failure(.sessionOpen):
            runtimeBase = .failed("Close the Knotchy browser first.", details: [])
            return
        case .failure(.setupRunning):
            runtimeBase = .failed("Wait for the current setup step to finish, then try again.", details: [])
            return
        case .failure(.stopFailed(let message)):
            runtimeBase = .failed("Couldn't stop the runtime for the update.", details: [message])
            return
        }

        runtimeBase = .running("Opening Installer…", fraction: nil)
        let session: any InstallerSession
        switch await installer.openInInstaller(package, release: release) {
        case .opened(let opened):
            session = opened
        case .changed:
            return await failInstall("The download changed after it was checked, so it wasn't opened.", details: [])
        case .failed(let message):
            installer.discard(package)
            return await failInstall("Couldn't open Installer.", details: [message])
        }

        runtimeBase = .running("Finish the install in Installer…", fraction: nil)
        let status = await waitForInstall(session)
        // Installer reads the package until it quits.
        Task { [installer] in
            while !session.hasQuit { try? await Task.sleep(for: .seconds(2)) }
            installer.discard(package)
        }
        // Quitting: Installer carries on by itself.
        if Task.isCancelled { return }
        guard case .current(let version)? = status else {
            _ = await driver.finishRuntimeInstall(.cancelled)
            runtimeBase = .pending("Installing was cancelled.")
            return
        }
        runtimeStatus = status
        runtimeAction = nil
        runtimeBase = .done(Self.installedText(version))
        apply(await driver.finishRuntimeInstall(.installed))
    }

    /// The current runtime once it appears, or nil when Installer quits without it.
    private func waitForInstall(_ session: any InstallerSession) async -> RuntimeStatus? {
        while !Task.isCancelled {
            let status = await driver.runtimeStatus()
            if case .current = status { return status }
            if session.hasQuit {
                // Installer may have finished between the two checks.
                let last = await driver.runtimeStatus()
                if case .current = last { return last }
                return nil
            }
            try? await Task.sleep(for: retryDelay)
        }
        return nil
    }

    private func download() async throws -> DownloadedPackage {
        isDownloading = true
        defer { isDownloading = false }
        return try await installer.download(release) { [weak self, release] bytes in
            Task { @MainActor in self?.downloaded(bytes, of: release.size) }
        }
    }

    private func failInstall(_ message: String, details: [String]) async {
        _ = await driver.finishRuntimeInstall(.failed(message))
        runtimeBase = .failed(message, details: details)
    }

    private func buildVM() async {
        // A setup the notch started, or a session winding down, gets up to a minute to finish.
        for _ in 0..<120 {
            if Task.isCancelled { return }
            guard let checked = await driver.checkSetup() else {
                if case .settingUp = driver.state {
                    await driver.waitWhileSettingUp()
                } else {
                    try? await Task.sleep(for: retryDelay)
                }
                continue
            }
            switch checked {
            case .needs(let issue) where Self.isImageIssue(issue) || issue == .kernelMissing:
                guard let result = await driver.runSetup(issue, continuing: true) else { continue }
                return apply(result)
            case .needs:
                return await inspect()
            default:
                return apply(checked)
            }
        }
        vmBase = .failed("Close the Knotchy browser first, then try again.", details: [])
    }

    private func apply(_ outcome: SetupRunOutcome) {
        switch outcome {
        case .ready:
            kernelInstalled()
            vmBase = .done("Ready")
        case .needs(let issue):
            if Self.isImageIssue(issue) {
                kernelInstalled()
                vmBase = .pending(Self.vmDetail)
            }
        case .failed(let issue, let message):
            if Self.isImageIssue(issue) { kernelInstalled() }
            fail(issue, message)
        }
    }

    /// The run got past the kernel, so a row still waiting for it is done.
    private func kernelInstalled() {
        guard case .pending = runtimeBase, runtimeAction == nil, case .current(let version)? = runtimeStatus else { return }
        runtimeBase = .done(Self.installedText(version))
    }

    private func fail(_ issue: SetupIssue, _ message: String) {
        if Self.isImageIssue(issue) {
            vmBase = .failed(message, details: driver.setupOutput)
        } else {
            runtimeBase = .failed(message, details: driver.setupOutput)
        }
    }

    private func downloaded(_ bytes: Int64, of total: Int64) {
        // Late callbacks mustn't overwrite what came after the download.
        guard case .running(let text, _) = runtimeBase, text.hasPrefix("Downloading") else { return }
        if bytes >= total {
            runtimeBase = .running("Verifying…", fraction: nil)
        } else {
            runtimeBase = .running(Self.downloadText(bytes, of: total), fraction: Double(bytes) / Double(max(total, 1)))
        }
    }

    private func updateMac() {
        guard let facts else { return }
        let free = facts.bytesFree.map { "\(Self.gigabytes($0)) GB free" }
        if needsSpace, let bytes = facts.bytesFree, bytes < Self.requiredFreeBytes {
            mac = .failed("Setting up needs about 10 GB free. \(Self.gigabytes(bytes)) GB is free.", details: [])
        } else {
            mac = .done([facts.osVersion, free].compactMap { $0 }.joined(separator: " · "))
        }
    }

    /// Only the install and the build use space; starting the service doesn't.
    private var needsSpace: Bool {
        if runtimeAction != nil { return true }
        if case .done = vmBase { return false }
        return true
    }

    // MARK: - Text

    static func installDetail(_ release: ContainerRuntime.Release) -> String {
        "Apple's container \(release.version) · \(megabytes(release.size)) MB, then a 700 MB Linux kernel · installs with Apple's Installer"
    }

    static func installedText(_ version: String?) -> String {
        version.map { "container \($0) installed" } ?? "container installed"
    }

    static func kernelDetail(_ version: String?) -> String {
        "\(installedText(version)) · still needs its Linux kernel (700 MB)"
    }

    static func downloadText(_ bytes: Int64, of total: Int64) -> String {
        "Downloading… \(megabytes(bytes)) of \(megabytes(total)) MB"
    }

    static func megabytes(_ bytes: Int64) -> Int {
        Int((Double(bytes) / 1_000_000).rounded())
    }

    static func gigabytes(_ bytes: Int64) -> String {
        bytes >= 10_000_000_000 ? "\(bytes / 1_000_000_000)" : String(format: "%.1f", Double(bytes) / 1_000_000_000)
    }

    static func isBrowserOpen(_ state: SessionState) -> Bool {
        switch state {
        case .starting, .live: true
        default: false
        }
    }

    static func isImageIssue(_ issue: SetupIssue) -> Bool {
        switch issue {
        case .imageMissing, .imageOutdated, .imageStale: true
        default: false
        }
    }
}
