import Foundation
import Testing
@testable import KnotchyCore

@MainActor
final class Recorder {
    var quitRequests = 0
    var setupRequests = 0
}

@MainActor
final class Harness {
    static let url = URL(string: "https://example.com/")!
    static let otherURL = URL(string: "https://example.org/")!

    let backend = FakeVMBackend()
    let connector = FakeStreamConnector()
    let disk = FakeDiskSpace()
    let clock = TestClock()
    let recorder: Recorder
    let controller: SessionController

    init(hostNetworks: [String] = ["192.168.1.0/24"]) {
        let recorder = Recorder()
        self.recorder = recorder
        var sessions = 0
        controller = SessionController(
            backend: backend,
            connector: connector,
            diskSpace: disk,
            clock: clock,
            hostNetworks: { hostNetworks },
            requestQuit: { recorder.quitRequests += 1 },
            makeSessionID: {
                sessions += 1
                return String(format: "knotchy-%08x", sessions)
            }
        )
        controller.showSetup = { recorder.setupRequests += 1 }
    }

    /// Lets go of held calls, so the fakes' 10 s check can't fire later against another test.
    deinit {
        for kind in [FakeVMBackend.Kind.sweep, .preflight, .start, .destroy, .forceDestroy, .fix, .stopService] {
            backend.release(kind)
        }
        connector.release()
        for stream in connector.connections { stream.close() }
    }

    var state: SessionState { controller.state }

    func advance(by duration: Duration) {
        clock.advance(by: duration)
        controller.fireDueTimers()
    }

    @discardableResult
    func openAndConnect(_ url: URL = Harness.url) async -> FakeStreamConnection {
        let before = connector.connections.count
        controller.open(url)
        await waitUntil("the stream connects") {
            self.connector.connections.count > before && self.state == .starting(.loading, folded: false)
        }
        return connector.connections.last!
    }

    func enter(_ mode: LiveMode) {
        switch mode {
        case .peek:
            break
        case .expanded:
            controller.pointerEntered()
            controller.expand()
        case .collapsed:
            controller.clickedOutside()
        }
    }

    @discardableResult
    func goLive(_ url: URL = Harness.url) async -> FakeStreamConnection {
        let stream = await openAndConnect(url)
        stream.emit(.contentReady)
        await waitUntil("the session is live") { self.state == .live(.peek) }
        return stream
    }
}
