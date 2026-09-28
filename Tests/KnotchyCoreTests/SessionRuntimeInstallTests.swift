import Foundation
import Testing
@testable import KnotchyCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionRuntimeInstallTests {
    @Test func aFreshInstallHoldsLinksThenStartsTheServiceAndBuilds() async {
        let h = Harness()
        let hold = await h.controller.beginRuntimeInstall(replacing: nil)
        #expect((try? hold.get()) != nil)
        #expect(h.state == .settingUp(.cliMissing))
        #expect(h.controller.setupFolded)
        h.controller.open(Harness.url)
        #expect(h.state == .settingUp(.cliMissing))
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls == [.sweep(keeping: [])])   // The link waits: no preflight, no start.

        h.backend.queuePreflight(.issue(.imageMissing))
        #expect(await h.controller.finishRuntimeInstall(.installed) == .ready)
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
        #expect(Array(h.backend.calls.prefix(5))
                == [.sweep(keeping: []), .fix(.serviceStopped), .preflight, .fix(.imageMissing), .preflight])
    }

    @Test func anUpdateStopsTheServiceFirst() async {
        let h = Harness()
        let hold = await h.controller.beginRuntimeInstall(replacing: "1.3.0")
        #expect((try? hold.get()) != nil)
        #expect(h.state == .settingUp(.cliOutdated(found: "1.3.0")))
        #expect(h.backend.calls == [.sweep(keeping: []), .stopService])
    }

    @Test func aServiceThatWontStopEndsTheHold() async {
        let h = Harness()
        h.backend.failStopService(with: VMBackendError.failed("still running"))
        guard case .failure(let refusal) = await h.controller.beginRuntimeInstall(replacing: "1.3.0") else {
            Issue.record("The hold should have been refused")
            return
        }
        #expect(refusal == .stopFailed("still running"))
        #expect(h.state == .idle)
    }

    @Test func theHoldWaitsForTheBrowserToClose() async {
        let h = Harness()
        await h.goLive()
        guard case .failure(let refusal) = await h.controller.beginRuntimeInstall(replacing: "1.3.0") else {
            Issue.record("The hold should have been refused")
            return
        }
        #expect(refusal == .sessionOpen)
        #expect(h.state == .live(.peek))
        #expect(!h.backend.calls.contains(.stopService))
    }

    @Test func theHoldIsAcceptedAfterAFailedStart() async {
        let h = Harness()
        h.backend.failStarts(with: VMBackendError.failed("boot failed"))
        h.controller.open(Harness.url)
        await waitUntil("the start fails") { if case .failed(.start) = h.state { true } else { false } }
        let hold = await h.controller.beginRuntimeInstall(replacing: nil)
        #expect((try? hold.get()) != nil)
        #expect(h.state == .settingUp(.cliMissing))
    }

    @Test func aCancelledInstallGoesBackToIdle() async {
        let h = Harness()
        _ = await h.controller.beginRuntimeInstall(replacing: nil)
        #expect(await h.controller.finishRuntimeInstall(.cancelled) == .needs(.cliMissing))
        #expect(h.state == .idle)
    }

    @Test func aFailedInstallShowsItsCardToAWaitingLink() async {
        let h = Harness()
        _ = await h.controller.beginRuntimeInstall(replacing: nil)
        h.controller.open(Harness.url)
        #expect(await h.controller.finishRuntimeInstall(.failed("Couldn't install the runtime."))
                == .failed(.cliMissing, "Couldn't install the runtime."))
        #expect(h.state == .setupRequired(.cliMissing, error: "Couldn't install the runtime."))
    }
}
