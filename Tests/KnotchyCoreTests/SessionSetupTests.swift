import Foundation
import Testing
@testable import KnotchyCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionSetupTests {
    @Test func aPreflightIssueNeedsSetupWithoutStartingAVM() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.imageMissing))
        h.controller.open(Harness.url)
        await waitUntil("setup required") { h.state == .setupRequired(.imageMissing, error: nil) }
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight])
        #expect(h.controller.liveIDs.snapshot.isEmpty)
    }

    @Test func theSetupActionShowsItsOutputThenTheLinkOpens() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.imageMissing))
        h.backend.scriptFix(output: ["Step 1/9", "Step 9/9"])
        h.backend.hold(.fix)
        h.controller.open(Harness.url)
        await waitUntil("setup required") { h.state == .setupRequired(.imageMissing, error: nil) }

        h.controller.performSetupAction()
        #expect(h.state == .settingUp(.imageMissing))
        await waitUntil("the output shows") { h.controller.setupLog == "Step 9/9" }

        h.backend.release(.fix)
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
        #expect(h.controller.openedURL == Harness.url)
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight, .fix(.imageMissing), .preflight, .start("knotchy-00000002")])
    }

    @Test func aSetupActionFoldsAwayAndItsLinkStartsFolded() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.imageMissing))
        h.backend.hold(.fix)
        h.controller.open(Harness.url)
        await waitUntil("setup required") { h.state == .setupRequired(.imageMissing, error: nil) }
        h.controller.clickedOutside()
        #expect(!h.controller.setupFolded)   // Only a running action folds.

        h.controller.performSetupAction()
        h.controller.clickedOutside()
        #expect(h.controller.setupFolded)
        h.controller.pointerEntered()
        #expect(!h.controller.setupFolded)
        h.controller.foldSetup()
        #expect(h.controller.setupFolded)

        h.backend.release(.fix)
        await waitUntil("loading, folded") { h.state == .starting(.loading, folded: true) }
        #expect(!h.controller.setupFolded)
    }

    @Test func aFoldedSetupOpenedByHoveringFoldsWhenThePointerLeaves() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.imageMissing))
        h.backend.hold(.fix)
        h.controller.open(Harness.url)
        await waitUntil("setup required") { h.state == .setupRequired(.imageMissing, error: nil) }
        h.controller.performSetupAction()
        h.controller.foldSetup()

        h.controller.pointerEntered()
        #expect(!h.controller.setupFolded)
        h.controller.pointerExited()
        h.advance(by: SessionController.foldGrace)
        #expect(h.controller.setupFolded)

        h.controller.showPanel()
        h.controller.pointerEntered()
        h.controller.pointerExited()
        h.advance(by: SessionController.foldGrace)
        #expect(!h.controller.setupFolded)
    }

    @Test func aFailedSetupShowsTheErrorOnTheCard() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.imageMissing))
        h.backend.scriptFix(output: [], error: VMBackendError.failed("container build failed"))
        h.controller.open(Harness.url)
        await waitUntil("setup required") { h.state == .setupRequired(.imageMissing, error: nil) }
        h.controller.performSetupAction()
        await waitUntil("the error shows") {
            h.state == .setupRequired(.imageMissing, error: "container build failed")
        }
    }

    @Test func aSecondIssueAfterSetupShowsItsOwnCard() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.imageMissing), .issue(.imageOutdated(found: 2, need: 3)))
        h.controller.open(Harness.url)
        await waitUntil("setup required") { h.state == .setupRequired(.imageMissing, error: nil) }
        h.controller.performSetupAction()
        await waitUntil("the next issue") { h.state == .setupRequired(.imageOutdated(found: 2, need: 3), error: nil) }
    }

    @Test func aMissingOrOldRuntimeOpensSetup() async {
        for issue in [SetupIssue.cliMissing, .cliOutdated(found: "1.3.0")] {
            let h = Harness()
            h.backend.queuePreflight(.issue(issue))
            h.controller.open(Harness.url)
            await waitUntil("setup required") { h.state == .setupRequired(issue, error: nil) }
            h.controller.performSetupAction()
            #expect(h.recorder.setupRequests == 1)
            #expect(h.state == .setupRequired(issue, error: nil))
            await h.controller.waitForBackendIdle()
            #expect(!h.backend.calls.contains(.fix(issue)))
        }
    }

    @Test func lowDiskNeedsSetupAndHasNoAction() async {
        let h = Harness()
        h.disk.available = 1_000_000_000
        h.controller.open(Harness.url)
        await waitUntil("setup required") { h.state == .setupRequired(.lowDisk(bytesFree: 1_000_000_000), error: nil) }
        h.controller.performSetupAction()
        #expect(h.state == .setupRequired(.lowDisk(bytesFree: 1_000_000_000), error: nil))
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight])
    }

    @Test func dismissDropsThePendingLink() async {
        // Only visible when setup runs again afterwards: here, a requested rebuild.
        let h = Harness()
        h.backend.queuePreflight(.ready(appRoot: "/fake/appRoot", staleImage: StaleImage(builtDaysAgo: 20)),
                                 .issue(.imageMissing))
        await h.goLive()
        h.controller.requestImageUpdate()
        h.controller.open(Harness.otherURL)
        await waitUntil("setup required") { h.state == .setupRequired(.imageMissing, error: nil) }

        h.controller.dismiss()
        #expect(h.state == .settingUp(.imageStale(builtDaysAgo: 20)))
        await waitUntil("idle after the rebuild") { h.state == .idle }
        #expect(!h.backend.calls.contains(.start("knotchy-00000003")))
    }

    @Test func aNewLinkDuringAnAutomaticStartOpensAfterIt() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.serviceStopped))
        h.backend.hold(.fix)
        h.controller.open(Harness.url)
        await waitUntil("starting the service") { h.backend.parkedCount(.fix) == 1 }
        #expect(h.state == .settingUp(.serviceStopped))
        #expect(!h.controller.setupFolded)
        h.controller.open(Harness.otherURL)
        #expect(h.state == .settingUp(.serviceStopped))
        h.backend.release(.fix)
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
        #expect(h.controller.openedURL == Harness.otherURL)
    }

    @Test func aStaleImageWarnsButNeverBlocks() async {
        let h = Harness()
        h.backend.queuePreflight(.ready(appRoot: "/fake/appRoot", staleImage: StaleImage(builtDaysAgo: 20)))
        await h.goLive()
        #expect(h.controller.staleImage == StaleImage(builtDaysAgo: 20))
    }

    @Test func updateNowRebuildsOnceTheSessionEnds() async {
        let h = Harness()
        h.backend.queuePreflight(.ready(appRoot: "/fake/appRoot", staleImage: StaleImage(builtDaysAgo: 20)))
        await h.goLive()
        h.controller.requestImageUpdate()
        #expect(h.controller.staleImage == nil)

        h.controller.destroy()
        await waitUntil("destroyed") { h.state == .destroyed }
        h.advance(by: .milliseconds(1500))
        #expect(h.state == .settingUp(.imageStale(builtDaysAgo: 20)))
        await waitUntil("idle after the rebuild") { h.state == .idle }
        #expect(h.backend.calls.suffix(2) == [.fix(.imageStale(builtDaysAgo: 20)), .preflight])
    }

    @Test func aRebuildThatEndsInAnotherIssueShowsItsCard() async {
        let h = Harness()
        h.backend.queuePreflight(.ready(appRoot: "/fake/appRoot", staleImage: StaleImage(builtDaysAgo: 20)),
                                 .issue(.serviceStopped))
        await h.goLive()
        h.controller.requestImageUpdate()
        h.controller.destroy()
        await waitUntil("destroyed") { h.state == .destroyed }
        h.advance(by: .milliseconds(1500))
        await waitUntil("the next issue") { h.state == .setupRequired(.serviceStopped, error: nil) }
    }

    @Test func aFailedRebuildStillOpensAPendingLink() async {
        let h = Harness()
        h.backend.queuePreflight(.ready(appRoot: "/fake/appRoot", staleImage: StaleImage(builtDaysAgo: 20)))
        h.backend.scriptFix(output: [], error: VMBackendError.failed("container build failed"))
        h.backend.hold(.fix)
        await h.goLive()
        h.controller.requestImageUpdate()
        h.controller.destroy()
        await waitUntil("destroyed") { h.state == .destroyed }
        h.advance(by: .milliseconds(1500))
        await waitUntil("rebuilding") { h.backend.parkedCount(.fix) == 1 }

        h.controller.open(Harness.otherURL)
        #expect(h.state == .settingUp(.imageStale(builtDaysAgo: 20)))
        h.backend.release(.fix)
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
        #expect(h.controller.openedURL == Harness.otherURL)
    }

    @Test func aLinkOpenedAfterARebuildStartsUnengaged() async {
        // The pointer was on the panel before it hid; nothing says it is there now.
        let h = Harness()
        h.backend.queuePreflight(.ready(appRoot: "/fake/appRoot", staleImage: StaleImage(builtDaysAgo: 20)))
        h.backend.hold(.fix)
        await h.goLive()
        h.controller.pointerEntered()
        h.controller.requestImageUpdate()
        h.controller.destroy()
        await waitUntil("destroyed") { h.state == .destroyed }
        h.advance(by: .milliseconds(1500))
        await waitUntil("rebuilding") { h.backend.parkedCount(.fix) == 1 }
        h.controller.open(Harness.otherURL)
        h.backend.release(.fix)

        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
        h.connector.connections.last!.emit(.contentReady)
        await waitUntil("live") { h.state == .live(.peek) }
        h.advance(by: .seconds(30))
        #expect(h.state == .live(.collapsed))
    }

    @Test func aFreshImageBuildSatisfiesARequestedRebuild() async {
        let h = Harness()
        h.backend.queuePreflight(.ready(appRoot: "/fake/appRoot", staleImage: StaleImage(builtDaysAgo: 20)),
                                 .issue(.imageMissing))
        await h.goLive()
        h.controller.requestImageUpdate()
        h.controller.open(Harness.otherURL)
        await waitUntil("setup required") { h.state == .setupRequired(.imageMissing, error: nil) }
        h.controller.performSetupAction()
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }

        h.controller.destroy()
        await waitUntil("destroyed") { h.state == .destroyed }
        h.advance(by: .milliseconds(1500))
        #expect(h.state == .idle)
        await h.controller.waitForBackendIdle()
        #expect(h.backend.calls.filter { if case .fix = $0 { true } else { false } } == [.fix(.imageMissing)])
    }

    @Test func laterHidesTheWarningForThisSession() async {
        let h = Harness()
        h.backend.queuePreflight(.ready(appRoot: "/fake/appRoot", staleImage: StaleImage(builtDaysAgo: nil)))
        await h.goLive()
        h.controller.dismissStaleImageWarning()
        #expect(h.controller.staleImage == nil)

        h.controller.destroy()
        await waitUntil("destroyed") { h.state == .destroyed }
        h.advance(by: .milliseconds(1500))
        #expect(h.state == .idle)
    }

    @Test func aStoppedServiceStartsByItselfAndTheLinkOpens() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.serviceStopped))
        h.controller.open(Harness.url)
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
        #expect(h.backend.calls == [.sweep(keeping: []), .preflight, .fix(.serviceStopped), .preflight,
                                    .start("knotchy-00000002")])
    }

    @Test func aServiceThatWontStayUpShowsItsCardOnce() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.serviceStopped), .issue(.serviceStopped))
        h.controller.open(Harness.url)
        await waitUntil("setup required") {
            h.state == .setupRequired(.serviceStopped, error: SessionController.stillBrokenMessage)
        }
        #expect(h.backend.calls.filter { $0 == .fix(.serviceStopped) }.count == 1)

        h.backend.queuePreflight(.issue(.serviceStopped))
        h.controller.open(Harness.url)   // A new request gets its own automatic start.
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
        #expect(h.backend.calls.filter { $0 == .fix(.serviceStopped) }.count == 2)
    }

    @Test func retryStartsTheServiceAgain() async {
        let h = Harness()
        h.backend.queuePreflight(.issue(.serviceStopped))
        h.backend.failStarts(with: VMBackendError.failed("boot failed"))
        h.controller.open(Harness.url)
        await waitUntil("the start fails") { if case .failed(.start) = h.state { true } else { false } }

        h.backend.failStarts(with: nil)
        h.backend.queuePreflight(.issue(.serviceStopped))
        h.controller.retry()
        await waitUntil("loading") { h.state == .starting(.loading, folded: false) }
        #expect(h.backend.calls.filter { $0 == .fix(.serviceStopped) }.count == 2)
    }
}
