import Foundation
import Testing
@testable import KnotchyCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionNewLinkTests {
    private let first = "knotchy-00000001"
    private let second = "knotchy-00000002"

    @Test func fromLiveTheOldVMIsDestroyedAndTheNewOneStartsAtOnce() async {
        let h = Harness()
        let old = await h.goLive()
        h.controller.open(Harness.otherURL)
        #expect(h.state == .starting(.booting, folded: false))
        #expect(h.controller.openedURL == Harness.otherURL)
        #expect(old.isClosed)
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight, .start(first), .destroy(first), .preflight, .start(second)])
    }

    @Test func aStartThatHasNotBegunNeverRuns() async {
        let h = Harness()
        h.controller.open(Harness.url)
        h.controller.open(Harness.otherURL)
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight, .start(second)])
        #expect(h.controller.liveIDs.snapshot == [second])
    }

    @Test func aSupersededStartIsDestroyedRightAfterItReturns() async {
        let h = Harness()
        h.backend.hold(.start)
        h.controller.open(Harness.url)
        await waitUntil("start runs") { h.backend.parkedCount(.start) == 1 }
        h.controller.open(Harness.otherURL)
        #expect(h.controller.liveIDs.snapshot == [first, second])

        h.backend.release(.start)
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight, .start(first), .destroy(first), .preflight, .start(second)])
        await waitUntil("the new session connects") { h.connector.socketPaths == ["/fake/\(second).sock"] }
        #expect(h.controller.liveIDs.snapshot == [second])
    }

    @Test func aConnectThatReturnsAfterANewLinkIsClosed() async {
        let h = Harness()
        h.connector.hold()
        h.controller.open(Harness.url)
        await waitUntil("connect runs") { h.connector.parkedCount == 1 }
        h.backend.hold(.start)
        h.controller.open(Harness.otherURL)
        await waitUntil("the new start runs") { h.backend.parkedCount(.start) == 1 }

        h.connector.release()
        await waitUntil("the late stream is closed") { h.connector.connections.first?.isClosed == true }
        #expect(h.state == .starting(.booting, folded: false))
        #expect(h.controller.connection == nil)

        h.backend.release(.start)
        await waitUntil("the new session connects") { h.state == .starting(.loading, folded: false) }
        #expect((h.controller.connection as? FakeStreamConnection)?.socketPath == "/fake/\(second).sock")
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight, .start(first), .destroy(first), .preflight, .start(second)])
    }

    @Test func aSupersededStartThatFailsLeavesTheNewSessionAlone() async {
        let h = Harness()
        h.backend.hold(.start)
        h.backend.hold(.destroy)
        h.controller.open(Harness.url)
        await waitUntil("start runs") { h.backend.parkedCount(.start) == 1 }
        h.controller.open(Harness.otherURL)
        h.backend.failStarts(with: VMBackendError.failed("boom"))
        h.backend.release(.start)
        await waitUntil("the old VM's destroy runs") { h.backend.parkedCount(.destroy) == 1 }
        #expect(h.state == .starting(.booting, folded: false))   // Not the old start's error card.
        h.backend.failStarts(with: nil)
        h.backend.release(.destroy)
        await waitUntil("the new session connects") { h.state == .starting(.loading, folded: false) }
    }

    @Test func anOldSessionsStuckDestroyDoesNotDriveTheCurrentPill() async {
        let h = Harness()
        await h.goLive()
        h.backend.hold(.destroy)
        h.backend.failDestroys(with: VMBackendError.destroyStuck(id: first))
        h.controller.destroy()
        await waitUntil("destroy runs") { h.backend.parkedCount(.destroy) == 1 }
        h.controller.open(Harness.otherURL)
        h.controller.destroy()   // The new session never started a VM, so this one succeeds.
        h.backend.release(.destroy)
        await h.controller.waitForBackendIdle()
        #expect(h.state == .destroyed)
    }

    @Test func liveIDsCoverASupersededSessionUntilItsDestroyIsConfirmed() async {
        let h = Harness()
        await h.goLive()
        h.backend.hold(.destroy)
        h.controller.open(Harness.otherURL)
        await waitUntil("destroy runs") { h.backend.parkedCount(.destroy) == 1 }
        #expect(h.controller.liveIDs.snapshot == [first, second])
        h.backend.release(.destroy)
        await h.controller.waitForBackendIdle()
        #expect(h.controller.liveIDs.snapshot == [second])
    }

    @Test func fromDestroyingTheNewSessionStartsAfterTheDestroy() async {
        let h = Harness()
        await h.goLive()
        h.backend.hold(.destroy)
        h.controller.destroy()
        await waitUntil("destroy runs") { h.backend.parkedCount(.destroy) == 1 }
        h.controller.open(Harness.otherURL)
        #expect(h.state == .starting(.booting, folded: false))

        h.backend.release(.destroy)
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls.suffix(3) == [.destroy(first), .preflight, .start(second)])
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
    }

    @Test func fromTheCollapsedPillTheNewLinkOpensThePanel() async {
        let h = Harness()
        await h.goLive()
        h.controller.clickedOutside()
        h.controller.open(Harness.otherURL)
        #expect(h.state == .starting(.booting, folded: false))
        #expect(h.controller.countdown == nil)
    }

    @Test func fromDestroyedTheCheckmarkIsCutShort() async {
        let h = Harness()
        await h.goLive()
        h.controller.destroy()
        await waitUntil("destroyed") { h.state == .destroyed }
        h.controller.open(Harness.otherURL)
        #expect(h.state == .starting(.booting, folded: false))
        h.advance(by: .seconds(2))
        #expect(h.state != .idle)
    }

    @Test func fromSessionEndedThePillIsCutShort() async {
        let h = Harness()
        let stream = await h.goLive()
        stream.emit(.ended(.closed))
        await waitUntil("ended") { h.state == .failed(.ended(.closed)) }
        h.controller.open(Harness.otherURL)
        #expect(h.state == .starting(.booting, folded: false))
        h.advance(by: .seconds(3))
        #expect(h.state != .idle)
    }

    @Test func fromTheErrorCardTheNewLinkStarts() async {
        let h = Harness()
        h.backend.failStarts(with: VMBackendError.failed("boom"))
        h.controller.open(Harness.url)
        await waitUntil("failed") { h.state == .failed(.start("boom")) }
        h.backend.failStarts(with: nil)
        h.controller.open(Harness.otherURL)
        #expect(h.state == .starting(.booting, folded: false))
        await waitUntil("the new start runs") { h.backend.calls.contains(.start(second)) }
    }

    @Test func fromAStuckDestroyTheStuckVMStaysOnPendingCleanup() async {
        let h = Harness()
        await h.goLive()
        h.backend.failDestroys(with: VMBackendError.destroyStuck(id: first))
        h.backend.failForceDestroys(with: VMBackendError.destroyStuck(id: first))
        h.controller.destroy()
        await waitUntil("stuck") { h.state == .failed(.destroyStuck) }
        h.controller.open(Harness.otherURL)
        #expect(h.state == .starting(.booting, folded: false))
        await h.controller.waitForBackendIdle()
        #expect(h.controller.liveIDs.snapshot == [first, second])
    }

    @Test func fromSetupRequiredPreflightRunsAgain() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.imageMissing))
        h.controller.open(Harness.url)
        await waitUntil("setup required") { h.state == .setupRequired(.imageMissing, error: nil) }
        h.controller.open(Harness.otherURL)
        #expect(h.state == .starting(.booting, folded: false))
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight, .preflight, .start(second)])
    }

    @Test func backendCallsNeverOverlap() async {
        let h = Harness()
        h.backend.hold(.start)
        h.controller.open(Harness.url)
        await waitUntil("start runs") { h.backend.parkedCount(.start) == 1 }
        h.controller.open(Harness.otherURL)
        h.controller.open(Harness.url)
        h.controller.destroy()
        h.controller.open(Harness.otherURL)
        h.backend.release(.start)
        await h.controller.waitForBackendIdle()
        #expect(h.backend.maxConcurrentCalls == 1)
        #expect(h.controller.liveIDs.snapshot == ["knotchy-00000004"])
    }
}
