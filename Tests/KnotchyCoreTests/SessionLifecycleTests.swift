import Foundation
import Testing
@testable import KnotchyCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionLifecycleTests {
    private let first = "knotchy-00000001"
    private let second = "knotchy-00000002"

    @Test func launchSweepsOrphansFirst() async {
        let h = Harness()
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls == [.sweep(keeping: [])])
        #expect(h.state == .idle)
    }

    @Test func aLinkBootsConnectsAndLoadsThenPeeks() async {
        let h = Harness()
        h.backend.hold(.start)
        h.connector.hold()
        h.controller.open(Harness.url)
        #expect(h.state == .starting(.booting, folded: false))
        #expect(h.controller.openedURL == Harness.url)
        #expect(h.controller.liveIDs.snapshot == [first])

        await waitUntil("start runs") { h.backend.parkedCount(.start) == 1 }
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight, .start(first)])
        #expect(h.backend.startArguments == [.init(id: first, url: Harness.url,
                                                   renderSize: PixelSize(width: 1024, height: 640),
                                                   blockCIDRs: ["192.168.1.0/24"])])

        h.backend.release(.start)
        await waitUntil("connecting") { h.state == .starting(.connecting, folded: false) }
        await waitUntil("connect runs") { h.connector.parkedCount == 1 }
        #expect(h.connector.socketPaths == ["/fake/\(first).sock"])

        h.connector.release()
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
        let stream = h.connector.connections[0]
        #expect(h.controller.connection === stream)

        stream.emit(.hello(version: 1, size: SessionController.renderSize))
        stream.emit(.contentReady)
        await waitUntil("live") { h.state == .live(.peek) }
    }

    @Test func thePageURLFollowsTheVMButNeverReplacesTheOpenedLink() async {
        let h = Harness()
        let stream = await h.goLive()
        #expect(h.controller.pageURL == nil)
        let next = URL(string: "https://example.org/next")!
        stream.emit(.pageURL(next))
        await waitUntil("the page URL shows") { h.controller.pageURL == next }
        #expect(h.controller.openedURL == Harness.url)

        h.controller.open(URL(string: "https://example.net/")!)
        #expect(h.controller.pageURL == nil)
    }

    @Test func destroyIsConfirmedBeforeDestroyedShowsThenGoesIdle() async {
        let h = Harness()
        let stream = await h.goLive()
        h.backend.hold(.destroy)
        h.controller.destroy()
        #expect(h.state == .destroying)
        #expect(stream.isClosed)
        #expect(h.controller.connection == nil)

        await waitUntil("destroy runs") { h.backend.parkedCount(.destroy) == 1 }
        #expect(h.state == .destroying)
        #expect(h.controller.liveIDs.snapshot == [first])

        h.backend.release(.destroy)
        await waitUntil("destroyed") { h.state == .destroyed }
        #expect(h.controller.liveIDs.snapshot.isEmpty)
        h.advance(by: .milliseconds(1499))
        #expect(h.state == .destroyed)
        h.advance(by: .milliseconds(1))
        #expect(h.state == .idle)
        #expect(h.controller.openedURL == nil)
    }

    @Test(arguments: [LiveMode.peek, .expanded, .collapsed])
    func destroyWorksFromEveryLiveMode(_ mode: LiveMode) async {
        let h = Harness()
        await h.goLive()
        h.enter(mode)
        #expect(h.state == .live(mode))
        h.controller.destroy()
        #expect(h.state == .destroying)
        #expect(h.controller.countdown == nil)
        await waitUntil("destroyed") { h.state == .destroyed }
    }

    @Test func destroyDuringPreflightNeverCallsTheBackendsDestroy() async {
        let h = Harness()
        h.backend.hold(.preflight)
        h.controller.open(Harness.url)
        await waitUntil("preflight runs") { h.backend.parkedCount(.preflight) == 1 }
        h.controller.destroy()
        h.backend.release(.preflight)
        await waitUntil("destroyed") { h.state == .destroyed }
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight])
        #expect(h.controller.liveIDs.snapshot.isEmpty)
    }

    @Test func destroyWhileConnectingClosesTheLateStream() async {
        let h = Harness()
        h.connector.hold()
        h.controller.open(Harness.url)
        await waitUntil("connect runs") { h.connector.parkedCount == 1 }
        h.controller.destroy()
        await waitUntil("destroyed") { h.state == .destroyed }
        h.connector.release()
        await waitUntil("the late stream is closed") { h.connector.connections.first?.isClosed == true }
        #expect(h.state == .destroyed)
        #expect(h.controller.connection == nil)
        h.advance(by: .milliseconds(1500))
        #expect(h.state == .idle)
    }

    @Test func aConnectThatFailsAfterDestroyIsIgnored() async {
        let h = Harness()
        h.connector.hold()
        h.connector.failNextConnect(with: .timedOut)
        h.backend.hold(.destroy)
        h.controller.open(Harness.url)
        await waitUntil("connect runs") { h.connector.parkedCount == 1 }
        h.controller.destroy()
        await waitUntil("destroy runs") { h.backend.parkedCount(.destroy) == 1 }
        h.connector.release()
        await h.controller.waitForSessionTasks()
        #expect(h.state == .destroying)   // Not the failed connect's error card.
        h.backend.release(.destroy)
        await waitUntil("destroyed") { h.state == .destroyed }
    }

    @Test func destroyWhileBootingDestroysTheVMOnceStartReturns() async {
        let h = Harness()
        h.backend.hold(.start)
        h.controller.open(Harness.url)
        await waitUntil("start runs") { h.backend.parkedCount(.start) == 1 }
        h.controller.destroy()
        #expect(h.state == .destroying)
        h.backend.release(.start)
        await waitUntil("destroyed") { h.state == .destroyed }
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight, .start(first), .destroy(first)])
        #expect(h.connector.socketPaths.isEmpty)
    }

    @Test func aStuckDestroyShowsTheAmberPillAndCanBeRetried() async {
        let h = Harness()
        await h.goLive()
        h.backend.failDestroys(with: VMBackendError.destroyStuck(id: first))
        h.controller.destroy()
        await waitUntil("stuck") { h.state == .failed(.destroyStuck) }
        #expect(h.controller.liveIDs.snapshot == [first])

        h.backend.failDestroys(with: nil)
        h.controller.retry()
        #expect(h.state == .destroying)
        await waitUntil("destroyed") { h.state == .destroyed }
        #expect(h.backend.calls.filter { $0 == .destroy(first) }.count == 2)
        #expect(h.controller.liveIDs.snapshot.isEmpty)
    }

    @Test func aRetryNeverRetriesItself() async {
        let h = Harness()
        await h.goLive()
        h.backend.failDestroys(with: VMBackendError.destroyStuck(id: first))
        h.controller.destroy()
        await waitUntil("stuck") { h.state == .failed(.destroyStuck) }

        h.controller.retry()   // Fails again: its own job must not also force-destroy the VM.
        await h.controller.waitForBackendIdle()
        #expect(h.state == .failed(.destroyStuck))

        h.backend.failDestroys(with: nil)
        h.controller.retry()
        await waitUntil("destroyed") { h.state == .destroyed }
        await h.controller.waitForBackendIdle()
        #expect(!h.backend.calls.contains(.forceDestroy(first)))
    }

    @Test func theStuckPillGoesIdleAfter30sAndTheVMStaysListed() async {
        let h = Harness()
        await h.goLive()
        h.backend.failDestroys(with: VMBackendError.destroyStuck(id: first))
        h.controller.destroy()
        await waitUntil("stuck") { h.state == .failed(.destroyStuck) }
        h.advance(by: .seconds(29))
        #expect(h.state == .failed(.destroyStuck))
        h.advance(by: .seconds(1))
        #expect(h.state == .idle)
        #expect(h.controller.liveIDs.snapshot == [first])
    }

    @Test func eachLaterJobRetriesAStuckVMOnce() async {
        let h = Harness()
        await h.goLive()
        h.backend.failDestroys(with: VMBackendError.destroyStuck(id: first))
        h.controller.destroy()
        await waitUntil("stuck") { h.state == .failed(.destroyStuck) }
        await h.controller.waitForBackendIdle()
        #expect(!h.backend.calls.contains(.forceDestroy(first)))

        h.backend.failDestroys(with: nil)
        h.backend.failForceDestroys(with: VMBackendError.destroyStuck(id: first))
        await h.goLive(Harness.otherURL)
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls.filter { $0 == .forceDestroy(first) }.count == 1)
        #expect(h.controller.liveIDs.snapshot == [first, second])

        h.backend.failForceDestroys(with: nil)
        h.controller.destroy()   // Destroying `second` is a later job: `first` gets another retry.
        await waitUntil("destroyed") { h.state == .destroyed }
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls.filter { $0 == .forceDestroy(first) }.count == 2)
        #expect(h.controller.liveIDs.snapshot.isEmpty)
    }

    @Test func stuckVMsTakeTurnsForRetries() async {
        let h = Harness()
        h.backend.failDestroys(with: VMBackendError.destroyStuck(id: "any"))
        h.backend.failForceDestroys(with: VMBackendError.destroyStuck(id: "any"))
        await h.goLive()
        h.controller.destroy()
        await waitUntil("the first VM is stuck") { h.state == .failed(.destroyStuck) }
        await h.goLive(Harness.otherURL)
        h.controller.destroy()
        await waitUntil("the second VM is stuck") { h.state == .failed(.destroyStuck) }
        await h.goLive()
        await h.controller.waitForBackendIdle()
        let retries = h.backend.calls.filter { if case .forceDestroy = $0 { true } else { false } }
        #expect(retries == [.forceDestroy(first), .forceDestroy(first), .forceDestroy(second)])
    }

    @Test func aStartFailureShowsTheErrorCardAndQueuesDestroy() async {
        let h = Harness()
        h.backend.failStarts(with: VMBackendError.failed("container run timed out"))
        h.controller.open(Harness.url)
        await waitUntil("failed") { h.state == .failed(.start("container run timed out")) }
        await waitUntil("the VM is destroyed") { h.backend.calls.contains(.destroy(first)) }
        await waitUntil("gone") { h.controller.liveIDs.snapshot.isEmpty }

        h.backend.failStarts(with: nil)
        h.controller.retry()
        #expect(h.state == .starting(.booting, folded: false))
        #expect(h.controller.openedURL == Harness.url)
        await waitUntil("the retry starts") { h.backend.calls.contains(.start(second)) }
    }

    @Test func dismissingTheErrorCardGoesIdle() async {
        let h = Harness()
        h.backend.failStarts(with: VMBackendError.failed("boom"))
        h.controller.open(Harness.url)
        await waitUntil("failed") { h.state == .failed(.start("boom")) }
        h.controller.dismiss()
        #expect(h.state == .idle)
        #expect(h.controller.openedURL == nil)
    }

    @Test func aConnectFailureFailsTheStart() async {
        let h = Harness()
        h.connector.failNextConnect(with: .timedOut)
        h.controller.open(Harness.url)
        await waitUntil("failed") { h.state == .failed(.start("The VM didn't answer in time.")) }
        await waitUntil("the VM is destroyed") { h.backend.calls.contains(.destroy(first)) }
    }

    @Test func aVersionMismatchAsksForARebuildAndDestroysTheVM() async {
        let h = Harness()
        h.connector.failNextConnect(with: .versionMismatch(found: 0, need: 1))
        h.backend.hold(.destroy)
        h.controller.open(Harness.url)
        await waitUntil("setup required") {
            h.state == .setupRequired(.imageOutdated(found: 0, need: 1), error: nil)
        }
        await waitUntil("destroy runs") { h.backend.parkedCount(.destroy) == 1 }
        #expect(h.controller.liveIDs.snapshot == [first])   // Kept until the destroy is confirmed.
        h.backend.release(.destroy)
        await waitUntil("gone") { h.controller.liveIDs.snapshot.isEmpty }
    }

    @Test func theStreamEndingWhileStartingFailsTheStart() async {
        let h = Harness()
        let stream = await h.openAndConnect()
        stream.emit(.ended(.noFirstFrame))
        await waitUntil("failed") { h.state == .failed(.start("The VM didn't send a first frame in time.")) }
        await waitUntil("the VM is destroyed") { h.backend.calls.contains(.destroy(first)) }
    }

    @Test func theStreamEndingWhileLiveShowsSessionEndedFor3s() async {
        let h = Harness()
        let stream = await h.goLive()
        stream.emit(.ended(.closed))
        await waitUntil("ended") { h.state == .failed(.ended(.closed)) }
        await waitUntil("the VM is destroyed") { h.backend.calls.contains(.destroy(first)) }
        h.advance(by: .milliseconds(2999))
        #expect(h.state == .failed(.ended(.closed)))
        h.advance(by: .milliseconds(1))
        #expect(h.state == .idle)
    }

    @Test(arguments: [LiveMode.peek, .expanded, .collapsed])
    func theStreamEndingInEveryLiveModeShowsSessionEnded(_ mode: LiveMode) async {
        let h = Harness()
        let stream = await h.goLive()
        h.enter(mode)
        stream.emit(.ended(.decodeErrors))
        await waitUntil("ended") { h.state == .failed(.ended(.decodeErrors)) }
        #expect(h.controller.countdown == nil)
        #expect(h.controller.connection == nil)
    }

    @Test func aStreamThatFinishesWithoutEndedStillEnds() async {
        let h = Harness()
        let stream = await h.goLive()
        stream.finishEvents()
        await waitUntil("ended") { h.state == .failed(.ended(.closed)) }
        await waitUntil("the VM is destroyed") { h.backend.calls.contains(.destroy(first)) }
    }

    @Test func theAppQuitsItselfAfter60sIdle() {
        let h = Harness()
        h.advance(by: .seconds(59))
        #expect(h.recorder.quitRequests == 0)
        h.advance(by: .seconds(1))
        #expect(h.recorder.quitRequests == 1)
    }

    @Test func theIdleQuitTimerRestartsWheneverIdleStarts() async {
        let h = Harness()
        h.advance(by: .seconds(30))
        await h.goLive()
        h.advance(by: .seconds(60))
        #expect(h.recorder.quitRequests == 0)

        h.controller.destroy()
        await waitUntil("destroyed") { h.state == .destroyed }
        h.advance(by: .milliseconds(1500))
        #expect(h.state == .idle)
        h.advance(by: .seconds(59))
        #expect(h.recorder.quitRequests == 0)
        h.advance(by: .seconds(1))
        #expect(h.recorder.quitRequests == 1)
    }

    @Test func noLinkOpensOnceTheChainIsClosedForQuitting() async {
        let h = Harness()
        h.controller.closeBackendChain()
        h.controller.open(Harness.url)
        #expect(h.state == .idle)
    }

    @Test func theQuitSnapshotIncludesAStartInFlight() async {
        let h = Harness()
        h.backend.hold(.start)
        h.controller.open(Harness.url)
        await waitUntil("start runs") { h.backend.parkedCount(.start) == 1 }
        h.controller.closeBackendChain()
        #expect(h.controller.liveIDs.snapshot == [first])

        // Nothing may destroy the VM behind the quit path's back.
        h.backend.release(.start)
        await h.controller.waitForBackendIdle()
        #expect(!h.backend.calls.contains(.destroy(first)))
        #expect(h.controller.liveIDs.snapshot == [first])
    }
}
