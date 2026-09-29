import Foundation
import Testing
@testable import KnotchyCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionSetupRunTests {
    @Test func aWindowRunFixesEachIssueInTurnAndEndsIdle() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.imageMissing))
        #expect(await h.controller.runSetup(.serviceStopped, continuing: true) == .ready)
        #expect(h.state == .idle)
        #expect(h.backend.calls == [.sweep(keeping: []), .fix(.serviceStopped), .preflight, .fix(.imageMissing), .preflight])
    }

    @Test func aWindowRunFetchesTheKernelBetweenTheServiceAndTheBuild() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.kernelMissing), .issue(.imageMissing))
        #expect(await h.controller.runSetup(.serviceStopped, continuing: true) == .ready)
        #expect(h.backend.calls == [.sweep(keeping: []), .fix(.serviceStopped), .preflight, .fix(.kernelMissing), .preflight,
                                    .fix(.imageMissing), .preflight])
    }

    @Test func aKernelThatStaysMissingIsReportedOnce() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.kernelMissing))
        #expect(await h.controller.runSetup(.kernelMissing, continuing: true)
                == .failed(.kernelMissing, SessionController.stillBrokenMessage))
        #expect(h.backend.calls.filter { $0 == .fix(.kernelMissing) }.count == 1)
    }

    @Test func aWindowRunStartsFolded() async {
        let h = Harness()
        h.backend.hold(.fix)
        let run = Task { await h.controller.runSetup(.imageMissing, continuing: false) }
        await waitUntil("building") { h.backend.parkedCount(.fix) == 1 }
        #expect(h.state == .settingUp(.imageMissing))
        #expect(h.controller.setupFolded)
        h.backend.release(.fix)
        #expect(await run.value == .ready)
    }

    @Test func aWindowRunNeverFixesTheSameIssueTwice() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.serviceStopped))
        #expect(await h.controller.runSetup(.serviceStopped, continuing: true)
                == .failed(.serviceStopped, SessionController.stillBrokenMessage))
        #expect(h.state == .idle)
        #expect(h.backend.calls.filter { $0 == .fix(.serviceStopped) }.count == 1)
    }

    @Test func anotherImageIssueAfterABuildIsTheSameFix() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.imageOutdated(found: 2, need: 3)))
        #expect(await h.controller.runSetup(.imageMissing, continuing: true)
                == .failed(.imageOutdated(found: 2, need: 3), SessionController.stillBrokenMessage))
        #expect(h.backend.calls.filter { if case .fix = $0 { true } else { false } }.count == 1)
    }

    @Test func aFailedWindowRunLeavesNoCardWithoutALink() async {
        let h = Harness()
        h.backend.scriptFix(output: [], error: VMBackendError.failed("container build failed"))
        #expect(await h.controller.runSetup(.imageMissing, continuing: true) == .failed(.imageMissing, "container build failed"))
        #expect(h.state == .idle)
    }

    @Test func aLinkDuringAWindowRunWaitsForTheWholeChain() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.imageMissing))
        h.backend.hold(.fix)
        let run = Task { await h.controller.runSetup(.serviceStopped, continuing: true) }
        await waitUntil("starting the service") { h.backend.parkedCount(.fix) == 1 }
        h.controller.open(Harness.url)
        #expect(h.state == .settingUp(.serviceStopped))
        #expect(!h.controller.setupFolded)   // A waiting link shows its card.
        h.backend.release(.fix)
        #expect(await run.value == .ready)
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
        #expect(Array(h.backend.calls.prefix(5))
                == [.sweep(keeping: []), .fix(.serviceStopped), .preflight, .fix(.imageMissing), .preflight])
    }

    @Test func aBusyControllerRefusesTheWindow() async {
        let h = Harness()
        await h.goLive()
        #expect(await h.controller.runSetup(.imageMissing, continuing: true) == nil)
        #expect(await h.controller.checkSetup() == nil)
    }

    @Test func checkingStartsAStoppedServiceButNeverBuilds() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.serviceStopped), .issue(.imageMissing))
        #expect(await h.controller.checkSetup() == .needs(.imageMissing))
        #expect(h.state == .idle)
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight, .fix(.serviceStopped), .preflight])
    }

    @Test func checkingNeverDownloadsTheKernel() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.serviceStopped), .issue(.kernelMissing))
        #expect(await h.controller.checkSetup() == .needs(.kernelMissing))
        #expect(h.state == .idle)
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight, .fix(.serviceStopped), .preflight])
    }

    @Test func setupErrorsReadAsSentences() {
        let timedOut = SessionController.message(for: CLIRunner.Failure.timedOut(["system", "start"]))
        #expect(timedOut == "The container runtime stopped responding. Try again.")
        #expect(SessionController.message(for: CLIRunner.Failure.notInstalled) == "Apple's container runtime isn't installed.")
        #expect(SessionController.message(for: CLIRunner.Failure.launchFailed("denied"))
                == "Couldn't run the container runtime: denied")
    }

    @Test func checkingOpensALinkACardWasHolding() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.imageMissing))
        h.controller.open(Harness.url)
        await waitUntil("setup required") { h.state == .setupRequired(.imageMissing, error: nil) }
        #expect(await h.controller.checkSetup() == .ready)
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
        #expect(h.controller.openedURL == Harness.url)
    }

    @Test func checkingAReadyMacFixesNothing() async {
        let h = Harness()
        #expect(await h.controller.checkSetup() == .ready)
        #expect(!h.backend.calls.contains { if case .fix = $0 { true } else { false } })
    }

    @Test func setupOutputKeepsTheLast200Lines() async {
        let h = Harness()
        h.backend.scriptFix(output: (1...250).map { "line \($0)" })
        _ = await h.controller.runSetup(.imageMissing, continuing: false)
        #expect(h.controller.setupOutput.count == 200)
        #expect(h.controller.setupOutput.first == "line 51")
        #expect(h.controller.setupOutput.last == "line 250")
    }

    @Test func waitingForSetupReturnsOnlyWhenItEnds() async {
        let h = Harness()
        h.backend.hold(.fix)
        let run = Task { await h.controller.runSetup(.imageMissing, continuing: false) }
        await waitUntil("building") { h.backend.parkedCount(.fix) == 1 }
        let waiter = Task {
            await h.controller.waitWhileSettingUp()
            return h.state
        }
        await Task.yield()
        h.backend.release(.fix)
        #expect(await waiter.value == .idle)
        _ = await run.value
    }
}
