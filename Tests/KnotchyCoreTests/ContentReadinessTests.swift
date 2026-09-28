import Testing
@testable import KnotchyCore

struct ContentReadinessTests {
    private let t0 = ContinuousClock.now

    @Test func ignoresBootstrapFramesAndProgress() {
        // A bootstrap 100 after NAVIGATED never gets here: the agent's progress gate drops it.
        var r = ContentReadiness()
        r.hello(at: t0)
        r.frame(isUniform: false)
        r.progress(100)
        #expect(!r.isReady)
    }

    @Test func readyOnTheFirstNonUniformFrameAfterNavigated() {
        var r = ContentReadiness()
        r.hello(at: t0)
        r.navigated(at: t0)
        r.frame(isUniform: true)
        #expect(!r.isReady)
        r.frame(isUniform: false)
        #expect(r.isReady)
    }

    @Test func readyOnProgress100AfterNavigated() {
        var r = ContentReadiness()
        r.hello(at: t0)
        r.navigated(at: t0)
        r.progress(40)
        #expect(!r.isReady)
        r.progress(100)
        #expect(r.isReady)
    }

    @Test func readyFifteenSecondsAfterNavigated() {
        var r = ContentReadiness()
        r.hello(at: t0)
        r.navigated(at: t0 + .seconds(1))
        #expect(r.nextDeadline == t0 + .seconds(16))
        r.tick(now: t0 + .seconds(16) - .milliseconds(1))
        #expect(!r.isReady)
        r.tick(now: t0 + .seconds(16))
        #expect(r.isReady)
        #expect(r.nextDeadline == nil)
    }

    @Test func readyTwentyFiveSecondsAfterHelloIfNavigatedNeverComes() {
        var r = ContentReadiness()
        #expect(r.nextDeadline == nil)
        r.hello(at: t0)
        #expect(r.nextDeadline == t0 + .seconds(25))
        r.tick(now: t0 + .seconds(24))
        #expect(!r.isReady)
        r.tick(now: t0 + .seconds(25))
        #expect(r.isReady)
    }

    @Test func theHelloBackstopStillAppliesAfterALateNavigated() {
        var r = ContentReadiness()
        r.hello(at: t0)
        r.navigated(at: t0 + .seconds(20))
        #expect(r.nextDeadline == t0 + .seconds(25))
        r.tick(now: t0 + .seconds(25))
        #expect(r.isReady)
    }

    @Test func aLateViewerIsCaughtUpByTheReplay() {
        var loaded = ContentReadiness()
        loaded.hello(at: t0)
        loaded.navigated(at: t0)
        loaded.progress(100)
        #expect(loaded.isReady)

        var loading = ContentReadiness()
        loading.hello(at: t0)
        loading.navigated(at: t0)
        loading.progress(40)
        #expect(!loading.isReady)
        loading.frame(isUniform: false)
        #expect(loading.isReady)
    }

    @Test func keepsTheFirstHelloAndNavigated() {
        // A repeated message can't push the timeouts back.
        var r = ContentReadiness()
        r.hello(at: t0)
        r.hello(at: t0 + .seconds(10))
        #expect(r.nextDeadline == t0 + .seconds(25))
        r.navigated(at: t0 + .seconds(5))
        r.navigated(at: t0 + .seconds(9))
        #expect(r.nextDeadline == t0 + .seconds(20))
    }

    @Test func staysReadyOnceReady() {
        var r = ContentReadiness()
        r.hello(at: t0)
        r.navigated(at: t0)
        r.frame(isUniform: false)
        r.frame(isUniform: true)
        r.progress(10)
        #expect(r.isReady)
    }
}

struct FrameSamplerTests {
    private func frame(width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        for y in 0..<height {
            for x in 0..<width * 4 { bytes[y * bytesPerRow + x] = 0xFF }
        }
        return bytes
    }

    /// Bytes that differ almost everywhere, so an out-of-bounds read can't look uniform by chance.
    private func ramp(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 1) }
    }

    @Test func aFlatFrameIsUniform() {
        let bytes = frame(width: 96, height: 60, bytesPerRow: 96 * 4 + 16)
        #expect(bytes.withUnsafeBytes { FrameSampler.isUniform($0, width: 96, height: 60, bytesPerRow: 96 * 4 + 16) })
    }

    @Test func aSampledPixelThatDiffersMakesItContent() {
        var bytes = frame(width: 96, height: 60, bytesPerRow: 96 * 4)
        // Grid point (gx 24, gy 24) samples pixel (48, 30).
        bytes[30 * 96 * 4 + 48 * 4] = 0
        #expect(!bytes.withUnsafeBytes { FrameSampler.isUniform($0, width: 96, height: 60, bytesPerRow: 96 * 4) })
    }

    @Test func aTightBufferIsSampledAndOneByteShortIsRejected() {
        let (width, height, bytesPerRow) = (8, 8, 40)
        let bytes = ramp((height - 1) * bytesPerRow + width * 4)
        #expect(!bytes.withUnsafeBytes { FrameSampler.isUniform($0, width: width, height: height, bytesPerRow: bytesPerRow) })
        #expect(Array(bytes.dropLast()).withUnsafeBytes {
            FrameSampler.isUniform($0, width: width, height: height, bytesPerRow: bytesPerRow)
        })
    }

    @Test(arguments: [
        (8, 8, -32), (8, 8, 31), (8, 0, 32), (0, 8, 32), (8, -1, 32),
        (Int.max / 2, 8, Int.max), (8, Int.max / 2, 32), (8, 8, Int.max), (1 << 16, 1, 1 << 18),
    ])
    func malformedGeometryCountsAsUniform(_ geometry: (width: Int, height: Int, bytesPerRow: Int)) {
        #expect(ramp(4096).withUnsafeBytes {
            FrameSampler.isUniform($0, width: geometry.width, height: geometry.height, bytesPerRow: geometry.bytesPerRow)
        })
    }
}
