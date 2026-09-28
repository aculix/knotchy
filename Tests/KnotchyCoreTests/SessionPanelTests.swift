import Foundation
import Testing
@testable import KnotchyCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionPanelTests {
    @Test func aFreshPanelStaysOpenUntilEnteredOrFor30s() async {
        let h = Harness()
        await h.goLive()
        h.advance(by: .milliseconds(29_999))
        #expect(h.state == .live(.peek))
        h.advance(by: .milliseconds(1))
        #expect(h.state == .live(.collapsed))
    }

    @Test func theFirstClickOutsideFoldsAnUnengagedPanel() async {
        let h = Harness()
        await h.goLive()
        h.controller.clickedOutside()
        #expect(h.state == .live(.collapsed))
    }

    @Test func anEnteredPeekFolds400msAfterThePointerLeaves() async {
        let h = Harness()
        await h.goLive()
        h.controller.pointerEntered()
        h.advance(by: .seconds(60))
        #expect(h.state == .live(.peek))   // Entered: the 30 s fold no longer applies.

        h.controller.pointerExited()
        h.advance(by: .milliseconds(399))
        #expect(h.state == .live(.peek))
        h.advance(by: .milliseconds(1))
        #expect(h.state == .live(.collapsed))
    }

    @Test func comingBackWithinTheGraceKeepsItOpen() async {
        let h = Harness()
        await h.goLive()
        h.controller.pointerEntered()
        h.controller.pointerExited()
        h.advance(by: .milliseconds(200))
        h.controller.pointerEntered()
        h.advance(by: .seconds(1))
        #expect(h.state == .live(.peek))
    }

    @Test func afterAClickInsideOnlyAClickOutsideFolds() async {
        let h = Harness()
        await h.goLive()
        h.controller.pointerEntered()
        h.controller.panelClicked()
        h.controller.pointerExited()
        h.advance(by: .seconds(60))
        #expect(h.state == .live(.peek))
        h.controller.clickedOutside()
        #expect(h.state == .live(.collapsed))
    }

    @Test func expandedFoldsOnlyOnAClickOutside() async {
        let h = Harness()
        await h.goLive()
        h.controller.pointerEntered()
        h.controller.expand()
        #expect(h.state == .live(.expanded))
        h.controller.pointerExited()
        h.advance(by: .seconds(60))
        #expect(h.state == .live(.expanded))

        h.controller.shrink()
        #expect(h.state == .live(.peek))
        h.controller.pointerEntered()
        h.controller.pointerExited()
        h.advance(by: .seconds(1))
        #expect(h.state == .live(.peek))   // Still key after Expanded: pointer-away doesn't fold.

        h.controller.expand()
        h.controller.clickedOutside()
        #expect(h.state == .live(.collapsed))
    }

    @Test func expandAndShrinkOnlyApplyToTheirModes() async {
        let h = Harness()
        h.controller.expand()
        #expect(h.state == .idle)
        await h.goLive()
        h.controller.shrink()
        #expect(h.state == .live(.peek))
        h.controller.clickedOutside()
        h.controller.expand()
        #expect(h.state == .live(.collapsed))
    }

    @Test func hoveringThePillReopensPeek() async {
        let h = Harness()
        await h.goLive()
        h.controller.clickedOutside()
        h.controller.pointerEntered()
        #expect(h.state == .live(.peek))
        h.controller.pointerExited()
        h.advance(by: .milliseconds(400))
        #expect(h.state == .live(.collapsed))
    }

    @Test func theIdleCountdownRunsOnlyWhileCollapsedAndResetsOnReopen() async {
        let h = Harness()
        await h.goLive()
        #expect(h.controller.countdown == nil)
        h.controller.clickedOutside()
        #expect(h.controller.countdown == .seconds(300))

        h.advance(by: .seconds(240))
        #expect(h.controller.countdown == .seconds(60))
        h.controller.pointerEntered()
        #expect(h.controller.countdown == nil)
        h.advance(by: .seconds(120))
        #expect(h.state == .live(.peek))

        h.controller.clickedOutside()
        #expect(h.controller.countdown == .seconds(300))
        h.advance(by: .seconds(300) - .milliseconds(1))
        #expect(h.state == .live(.collapsed))
        h.advance(by: .milliseconds(1))
        #expect(h.state == .destroying)
        await waitUntil("destroyed") { h.state == .destroyed }
    }

    @Test func decodingPausesWhileCollapsed() async {
        let h = Harness()
        let stream = await h.goLive()
        h.controller.clickedOutside()
        #expect(stream.decodeChanges == [false])
        h.controller.pointerEntered()
        #expect(stream.decodeChanges == [false, true])
    }

    @Test func foldingWhileStartingShowsThePillAndStaysFoldedWhenReady() async {
        let h = Harness()
        h.connector.hold()
        h.controller.open(Harness.url)
        h.controller.clickedOutside()
        #expect(h.state == .starting(.booting, folded: true))

        await waitUntil("connecting") { h.state == .starting(.connecting, folded: true) }
        h.connector.release()
        await waitUntil("loading") { h.state == .starting(.loading, folded: true) }

        let stream = h.connector.connections[0]
        stream.emit(.contentReady)
        await waitUntil("collapsed") { h.state == .live(.collapsed) }
        #expect(h.controller.countdown == .seconds(300))
        #expect(stream.decodeChanges == [false])
    }

    @Test func hoveringTheStartingPillUnfoldsIt() async {
        let h = Harness()
        h.backend.hold(.start)
        h.controller.open(Harness.url)
        h.controller.clickedOutside()
        h.controller.pointerEntered()
        #expect(h.state == .starting(.booting, folded: false))
        h.controller.pointerExited()
        h.advance(by: .milliseconds(400))
        #expect(h.state == .starting(.booting, folded: true))
        h.backend.release(.start)
    }

    @Test func aGraceFoldStartedWhileStartingCarriesIntoPeek() async {
        let h = Harness()
        let stream = await h.openAndConnect()
        h.controller.pointerEntered()
        h.controller.pointerExited()
        h.advance(by: .milliseconds(200))
        stream.emit(.contentReady)
        await waitUntil("live") { h.state == .live(.peek) }
        h.advance(by: .milliseconds(200))
        #expect(h.state == .live(.collapsed))
    }

    @Test func retryKeepsThePanelEnteredWhenThePointerIsOnIt() async {
        let h = Harness()
        h.backend.failStarts(with: VMBackendError.failed("boom"))
        h.controller.open(Harness.url)
        await waitUntil("failed") { h.state == .failed(.start("boom")) }
        h.backend.failStarts(with: nil)
        h.controller.pointerEntered()
        h.controller.retry()
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
        h.connector.connections[0].emit(.contentReady)
        await waitUntil("live") { h.state == .live(.peek) }

        h.advance(by: .seconds(30))
        #expect(h.state == .live(.peek))
        h.controller.pointerExited()
        h.advance(by: .milliseconds(400))
        #expect(h.state == .live(.collapsed))
    }

    @Test func pointerInputDoesNothingWithoutAnOpenPanel() async {
        let h = Harness()
        h.controller.clickedOutside()
        h.controller.pointerEntered()
        h.controller.pointerExited()
        h.controller.panelClicked()
        #expect(h.state == .idle)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionProgressTests {
    @Test func showsTheLatestProgressWhileStarting() async {
        let h = Harness()
        let stream = await h.openAndConnect()
        stream.emit(.progress(10))
        await waitUntil("10 %") { h.controller.progress == 10 }
        stream.emit(.progress(60))
        await waitUntil("60 %") { h.controller.progress == 60 }
        h.advance(by: .seconds(10))
        #expect(h.controller.progress == 60)   // No hiding before content is ready.
    }

    @Test func hidesAtProgress100() async {
        let h = Harness()
        let stream = await h.openAndConnect()
        stream.emit(.progress(30))
        await waitUntil("30 %") { h.controller.progress == 30 }
        stream.emit(.progress(100))
        await waitUntil("hidden") { h.controller.progress == nil }
    }

    @Test func onceReadyItHides2sAfterTheLastProgress() async {
        let h = Harness()
        let stream = await h.openAndConnect()
        stream.emit(.progress(30))
        stream.emit(.contentReady)
        await waitUntil("live") { h.state == .live(.peek) }
        #expect(h.controller.progress == 30)
        h.advance(by: .milliseconds(1999))
        #expect(h.controller.progress == 30)
        h.advance(by: .milliseconds(1))
        #expect(h.controller.progress == nil)
    }

    @Test func aLoadThatNeverReports100StillHidesWhenReady() async {
        let h = Harness()
        let stream = await h.openAndConnect()
        stream.emit(.progress(30))
        await waitUntil("30 %") { h.controller.progress == 30 }
        h.advance(by: .seconds(5))
        stream.emit(.contentReady)
        await waitUntil("live") { h.state == .live(.peek) }
        #expect(h.controller.progress == nil)
    }

    @Test func endingASessionHidesTheBar() async {
        let h = Harness()
        let stream = await h.openAndConnect()
        stream.emit(.progress(40))
        await waitUntil("40 %") { h.controller.progress == 40 }
        stream.emit(.ended(.closed))
        await waitUntil("failed") { h.state == .failed(.start("The VM closed the connection.")) }
        #expect(h.controller.progress == nil)
    }

    @Test func progressAfterReadyShowsAgainThenHides() async {
        let h = Harness()
        let stream = await h.goLive()
        stream.emit(.progress(20))
        await waitUntil("20 %") { h.controller.progress == 20 }
        h.advance(by: .seconds(2))
        #expect(h.controller.progress == nil)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionToolbarTests {
    @Test func navigateSendsTheURLAndUpdatesTheAddress() async throws {
        let h = Harness()
        let stream = await h.goLive()
        let url = try #require(URL(string: "https://example.net/page"))
        h.controller.navigate(url)
        #expect(stream.sent == [.navigate("https://example.net/page")])
        #expect(h.controller.openedURL == url)
    }

    @Test func backForwardAndReloadRunScripts() async {
        let h = Harness()
        let stream = await h.goLive()
        h.controller.goBack()
        h.controller.goForward()
        h.controller.reload()
        #expect(stream.sent == [.script("history.back()"), .script("history.forward()"), .script("location.reload()")])
    }

    @Test func toolbarActionsNeedALiveSession() async {
        let h = Harness()
        let stream = await h.openAndConnect()
        h.controller.reload()
        h.controller.navigate(Harness.otherURL)
        #expect(stream.sent.isEmpty)
        #expect(h.controller.openedURL == Harness.url)
    }

    @Test func aNonWebLinkShowsANoticeFor2s() async throws {
        let h = Harness()
        h.controller.open(try #require(URL(string: "ftp://files.example.com")))
        #expect(h.controller.notice == .noWebLink)
        #expect(h.state == .idle)
        h.advance(by: .milliseconds(1999))
        #expect(h.controller.notice == .noWebLink)
        h.advance(by: .milliseconds(1))
        #expect(h.controller.notice == nil)
    }

    @Test func navigateRejectsNonWebLinks() async throws {
        let h = Harness()
        let stream = await h.goLive()
        h.controller.navigate(try #require(URL(string: "file:///etc/passwd")))
        #expect(stream.sent.isEmpty)
        #expect(h.controller.notice == .noWebLink)
        #expect(h.controller.openedURL == Harness.url)
    }

    @Test func textWithoutALinkShowsANotice() {
        let h = Harness()
        h.controller.open(text: "call me maybe")
        #expect(h.controller.notice == .noWebLink)
        #expect(h.state == .idle)
    }

    @Test func textWithALinkOpensIt() {
        let h = Harness()
        h.controller.open(text: "Your parcel: https://example.com/ (tracking)")
        #expect(h.state == .starting(.booting, folded: false))
        #expect(h.controller.openedURL == Harness.url)
    }
}
