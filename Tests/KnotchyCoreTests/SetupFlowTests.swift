import Foundation
import Testing
@testable import KnotchyCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SetupFlowTests {
    let host = FakeHost()
    let installer = FakeInstaller()
    let driver = FakeSetupDriver()

    func makeFlow() -> SetupFlow {
        SetupFlow(host: host, installer: installer, driver: driver, retryDelay: .zero)
    }

    @Test func aReadyMacShowsEveryRowDone() async {
        let flow = makeFlow()
        await flow.refresh()
        #expect(flow.mac == .done("macOS 27.0 · 212 GB free"))
        #expect(flow.runtime == .done("container 1.4.1 installed"))
        #expect(flow.vm == .done("Ready"))
        #expect(flow.allRequiredDone)
        #expect(!flow.canSetUp)
    }

    @Test func aMissingRuntimeOffersAnInstallWithoutCheckingTheVM() async {
        driver.runtimeStatuses = [.missing]
        let flow = makeFlow()
        await flow.refresh()
        #expect(flow.runtimeAction == .install)
        #expect(flow.runtime == .pending("Apple's container 1.4.1 · 118 MB, then a 700 MB Linux kernel · installs with Apple's Installer"))
        #expect(flow.vm == .pending("About 3 minutes · downloads about 225 MB"))
        #expect(flow.canSetUp)
        #expect(driver.calls == ["runtimeStatus"])
    }

    @Test func anOldRuntimeOffersAnUpdate() async {
        driver.runtimeStatuses = [.outdated("1.3.0")]
        let flow = makeFlow()
        await flow.refresh()
        #expect(flow.runtimeAction == .update)
        #expect(flow.runtime == .pending("container 1.3.0 is too old · updates to 1.4.1 with Apple's Installer"))
    }

    @Test func aMacThatCantRunVirtualMachinesShowsOnlyThat() async {
        host.current.unsupported = .noVirtualization
        let flow = makeFlow()
        await flow.refresh()
        #expect(flow.unsupported == .noVirtualization)
        #expect(driver.calls.isEmpty)
        #expect(!flow.canSetUp)
    }

    @Test func lowDiskBlocksOnlyWhileSomethingNeedsSpace() async {
        host.current.bytesFree = 2_500_000_000
        driver.runtimeStatuses = [.missing]
        let flow = makeFlow()
        await flow.refresh()
        #expect(flow.mac == .failed("Setting up needs about 10 GB free. 2.5 GB is free.", details: []))
        #expect(!flow.canSetUp)

        driver.runtimeStatuses = [.current("1.4.1")]
        await flow.refresh()
        #expect(flow.mac == .done("macOS 27.0 · 2.5 GB free"))
        #expect(flow.allRequiredDone)
    }

    @Test func installingWithInstallerFinishesTheChain() async throws {
        driver.runtimeStatuses = [.missing, .current("1.4.1")]
        installer.session.hasQuit = false
        let flow = makeFlow()
        await flow.setUp()
        #expect(driver.calls == ["runtimeStatus", "begin(nil)", "runtimeStatus", "finish(installed)"])
        #expect(flow.mac == .done("macOS 27.0 · 212 GB free"))
        #expect(flow.runtime == .done("container 1.4.1 installed"))
        #expect(flow.vm == .done("Ready"))
        #expect(flow.allRequiredDone)

        // Installer still reads the package while its summary is open.
        try await Task.sleep(for: .milliseconds(50))
        #expect(installer.calls == ["download", "open"])
        installer.session.hasQuit = true
        await waitUntil("the package is discarded") { installer.calls.contains("discard") }
        #expect(installer.calls == ["download", "open", "discard"])
    }

    @Test func anUpdatePassesTheOldVersionOn() async {
        driver.runtimeStatuses = [.outdated("1.3.0"), .current("1.4.1")]
        let flow = makeFlow()
        await flow.setUp()
        #expect(driver.calls.contains("begin(1.3.0)"))
        #expect(flow.allRequiredDone)
    }

    @Test func aMismatchedDownloadIsNeverInstalled() async {
        driver.runtimeStatuses = [.missing]
        installer.failDownload(with: .mismatch)
        let flow = makeFlow()
        await flow.setUp()
        #expect(flow.runtime == .failed("The download didn't match the expected package, so it wasn't installed.", details: []))
        #expect(installer.calls == ["download"])
        #expect(!driver.calls.contains { $0.hasPrefix("begin") })
    }

    @Test func anOfflineDownloadSaysSo() async {
        driver.runtimeStatuses = [.missing]
        installer.failDownload(with: .failed("The Internet connection appears to be offline."))
        let flow = makeFlow()
        await flow.setUp()
        guard case .failed(let message, _) = flow.runtime else {
            Issue.record("Expected a failure")
            return
        }
        #expect(message == "Couldn't download the runtime. Check your connection and try again.")
    }

    @Test func quittingInstallerWithoutInstallingIsCancelled() async {
        driver.runtimeStatuses = [.missing]
        let flow = makeFlow()
        await flow.setUp()
        #expect(flow.runtime == .pending("Installing was cancelled."))
        #expect(flow.runtimeAction == .install)
        #expect(flow.canSetUp)
        #expect(driver.calls == ["runtimeStatus", "begin(nil)", "runtimeStatus", "runtimeStatus", "finish(cancelled)"])
        await waitUntil("the package is discarded") { installer.calls.contains("discard") }
        #expect(installer.calls == ["download", "open", "discard"])
    }

    @Test func aChangedDownloadIsNotOpened() async {
        driver.runtimeStatuses = [.missing]
        installer.open(with: .changed)
        let flow = makeFlow()
        await flow.setUp()
        #expect(flow.runtime == .failed("The download changed after it was checked, so it wasn't opened.", details: []))
        #expect(installer.calls == ["download", "open"])
        #expect(driver.calls.last?.hasPrefix("finish(failed") == true)
    }

    @Test func installerThatWontOpenSaysSo() async {
        driver.runtimeStatuses = [.missing]
        installer.open(with: .failed("x"))
        let flow = makeFlow()
        await flow.setUp()
        #expect(flow.runtime == .failed("Couldn't open Installer.", details: ["x"]))
        #expect(installer.calls == ["download", "open", "discard"])
        #expect(flow.canSetUp)
        #expect(driver.calls.last?.hasPrefix("finish(failed") == true)
    }

    @Test func anUpdateWaitsForTheBrowserToClose() async {
        driver.runtimeStatuses = [.outdated("1.3.0")]
        driver.holdResult = .failure(.sessionOpen)
        let flow = makeFlow()
        await flow.setUp()
        #expect(flow.runtime == .failed("Close the Knotchy browser first.", details: []))
        #expect(installer.calls == ["download", "discard"])
    }

    @Test func quittingWhileInstallerIsOpenLeavesItToFinish() async {
        driver.runtimeStatuses = [.missing]
        installer.session.hasQuit = false
        let flow = makeFlow()
        flow.start()
        await waitUntil("Installer is open") { flow.runtime == .running("Finish the install in Installer…", fraction: nil) }
        flow.cancel()
        await waitUntil("the flow stops") { !flow.isRunning }
        #expect(!driver.calls.contains { $0.hasPrefix("finish(") })
        #expect(!installer.calls.contains("discard"))
        installer.session.hasQuit = true   // Ends the cleanup task.
    }

    @Test func aClosingBrowserIsWaitedFor() async {
        driver.runtimeStatuses = [.outdated("1.3.0")]
        for state in [SessionState.destroying, .failed(.destroyStuck)] {
            driver.state = state
            let flow = makeFlow()
            await flow.setUp()
            #expect(flow.runtime == .failed("Wait for the Knotchy browser to finish closing, then try again.", details: []))
        }
        #expect(installer.calls.isEmpty)
    }

    @Test func aFailedServiceStartStopsSetUp() async {
        driver.checkResults = [.failed(.serviceStopped, "Couldn't start the service: x")]
        driver.setupOutput = ["x"]
        let flow = makeFlow()
        await flow.setUp()
        #expect(flow.runtime == .failed("Couldn't start the service: x", details: ["x"]))
        #expect(driver.calls.filter { $0 == "checkSetup" }.count == 1)
        #expect(!driver.calls.contains { $0.hasPrefix("runSetup") })
    }

    @Test func aMissingKernelWaitsForSetUp() async {
        driver.checkResults = [.needs(.kernelMissing)]
        let flow = makeFlow()
        await flow.refresh()
        #expect(flow.runtime == .pending("container 1.4.1 installed · still needs its Linux kernel (700 MB)"))
        #expect(flow.vm == .pending("About 3 minutes · downloads about 225 MB"))
        #expect(flow.canSetUp)
        #expect(!driver.calls.contains { $0.hasPrefix("runSetup") })
    }

    @Test func setUpFetchesAMissingKernelThenBuilds() async {
        driver.checkResults = [.needs(.kernelMissing), .needs(.kernelMissing)]
        let flow = makeFlow()
        await flow.setUp()
        #expect(driver.calls.contains("runSetup(kernelMissing, continuing: true)"))
        #expect(flow.runtime == .done("container 1.4.1 installed"))
        #expect(flow.vm == .done("Ready"))
    }

    @Test func aFailedKernelDownloadShowsInTheRuntimeRow() async {
        driver.checkResults = [.needs(.kernelMissing), .needs(.kernelMissing)]
        driver.runResults = [.failed(.kernelMissing, "Couldn't download the Linux kernel. Check your connection and try again.")]
        driver.setupOutput = ["Downloading the Linux kernel… 212 of 697 MB"]
        let flow = makeFlow()
        await flow.setUp()
        #expect(flow.runtime == .failed("Couldn't download the Linux kernel. Check your connection and try again.",
                                        details: ["Downloading the Linux kernel… 212 of 697 MB"]))
        #expect(flow.vm == .pending("About 3 minutes · downloads about 225 MB"))
    }

    @Test func aBuildFailureShowsItsOutput() async {
        driver.checkResults = [.needs(.imageMissing), .needs(.imageMissing)]
        driver.runResults = [.failed(.imageMissing, "The image build failed: out of space")]
        driver.setupOutput = ["Step 7/9", "error: out of space"]
        let flow = makeFlow()
        await flow.setUp()
        #expect(flow.vm == .failed("The image build failed: out of space", details: ["Step 7/9", "error: out of space"]))
        #expect(driver.calls.contains("runSetup(imageMissing, continuing: true)"))
    }

    @Test func aSetupTheNotchStartedIsFollowed() async {
        driver.state = .settingUp(.imageMissing)
        driver.checkResults = [nil, nil, .ready]
        let flow = makeFlow()
        await flow.setUp()
        #expect(driver.calls.contains("wait"))
        #expect(flow.vm == .done("Ready"))
    }

    @Test func theRowsShowTheControllersProgress() {
        let flow = makeFlow()
        driver.state = .settingUp(.imageMissing)
        driver.setupLog = "Step 3/9"
        #expect(flow.vm == .running("Step 3/9", fraction: nil))
        driver.state = .settingUp(.serviceStopped)
        driver.setupLog = nil
        #expect(flow.runtime == .running("Starting the runtime…", fraction: nil))
        driver.state = .settingUp(.kernelMissing)
        #expect(flow.runtime == .running("Downloading the Linux kernel…", fraction: nil))
        driver.setupLog = "Downloading the Linux kernel… 212 of 697 MB"
        #expect(flow.runtime == .running("Downloading the Linux kernel… 212 of 697 MB", fraction: nil))
    }

    @Test func anOpenBrowserCountsAsAReadyVM() async {
        driver.state = .live(.peek)
        driver.checkResults = [nil]
        let flow = makeFlow()
        await flow.refresh()
        #expect(flow.vm == .done("Ready"))
        #expect(flow.allRequiredDone)
    }

    @Test func anOpenBrowserIsReportedBeforeDownloadingAnUpdate() async {
        driver.state = .live(.peek)
        driver.runtimeStatuses = [.outdated("1.3.0")]
        let flow = makeFlow()
        await flow.setUp()
        #expect(flow.runtime == .failed("Close the Knotchy browser first.", details: []))
        #expect(installer.calls.isEmpty)
    }

    @Test func downloadProgressReadsInMegabytes() {
        #expect(SetupFlow.downloadText(58_886_932, of: ContainerRuntime.pinned.size) == "Downloading… 59 of 118 MB")
    }
}
