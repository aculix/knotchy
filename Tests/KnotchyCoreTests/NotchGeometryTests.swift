import CoreGraphics
import Testing
@testable import KnotchyCore

struct NotchGeometryTests {
    private let macBookPro = ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 870),
        safeAreaTop: 32,
        auxLeft: CGRect(x: 0, y: 950, width: 662, height: 32),
        auxRight: CGRect(x: 850, y: 950, width: 662, height: 32),
        menuBarThickness: 24
    )

    private let external = ScreenInfo(
        frame: CGRect(x: 1512, y: -200, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: -200, width: 1920, height: 1055),
        safeAreaTop: 0, auxLeft: .zero, auxRight: .zero, menuBarThickness: 24
    )

    @Test func peekUnderAPhysicalNotch() {
        let layout = NotchGeometry.layout(for: macBookPro, mode: .peek)
        #expect(layout.notch == CGRect(x: 662, y: 950, width: 188, height: 32))
        #expect(layout.pill == CGRect(x: 590, y: 950, width: 332, height: 32))
        #expect(layout.panel == CGRect(x: 430, y: 510, width: 652, height: 472))
        #expect(layout.toolbar == CGRect(x: 436, y: 916, width: 640, height: 34))
        #expect(layout.content == CGRect(x: 436, y: 516, width: 640, height: 400))
        #expect(layout.contentScale == 0.625)
    }

    @Test func expandedUnderAPhysicalNotch() {
        let layout = NotchGeometry.layout(for: macBookPro, mode: .expanded)
        #expect(layout.panel == CGRect(x: 238, y: 270, width: 1036, height: 712))
        #expect(layout.content == CGRect(x: 244, y: 276, width: 1024, height: 640))
        #expect(layout.contentScale == 1)
    }

    @Test func theNotchHeightIsTheSafeArea() {
        var screen = macBookPro
        screen.safeAreaTop = 37
        screen.auxLeft = CGRect(x: 0, y: 945, width: 662, height: 37)
        screen.auxRight = CGRect(x: 850, y: 945, width: 662, height: 37)
        let layout = NotchGeometry.layout(for: screen, mode: .peek)
        #expect(layout.notch == CGRect(x: 662, y: 945, width: 188, height: 37))
        #expect(layout.panel.height == CGFloat(37 + 34 + 400 + 6))
    }

    @Test func aNotchNeedsASafeAreaAndBothMenuBarAreas() {
        let virtualNotch = CGRect(x: 656, y: 950, width: 200, height: 32)
        var noRightArea = macBookPro
        noRightArea.auxRight = .zero
        #expect(!noRightArea.hasNotch)
        #expect(NotchGeometry.layout(for: noRightArea, mode: .peek).notch == virtualNotch)

        var noSafeArea = macBookPro
        noSafeArea.safeAreaTop = 0
        #expect(!noSafeArea.hasNotch)
        #expect(NotchGeometry.layout(for: noSafeArea, mode: .peek).notch == virtualNotch)
    }

    @Test func asymmetricEarsAndNotchWidthClamping() {
        var screen = macBookPro
        screen.auxLeft = CGRect(x: 0, y: 950, width: 600, height: 32)
        screen.auxRight = CGRect(x: 850, y: 950, width: 662, height: 32)
        #expect(NotchGeometry.layout(for: screen, mode: .peek).notch == CGRect(x: 600, y: 950, width: 250, height: 32))

        screen.auxLeft = CGRect(x: 0, y: 950, width: 500, height: 32)
        screen.auxRight = CGRect(x: 1000, y: 950, width: 512, height: 32)
        #expect(NotchGeometry.layout(for: screen, mode: .peek).notch.width == 300)

        screen.auxLeft = CGRect(x: 0, y: 950, width: 700, height: 32)
        screen.auxRight = CGRect(x: 760, y: 950, width: 752, height: 32)
        #expect(NotchGeometry.layout(for: screen, mode: .peek).notch == CGRect(x: 670, y: 950, width: 120, height: 32))
    }

    @Test func virtualNotchOnAScreenWithoutOne() {
        let layout = NotchGeometry.layout(for: external, mode: .peek)
        #expect(layout.notch == CGRect(x: 2372, y: 855, width: 200, height: 25))
        #expect(layout.panel == CGRect(x: 2146, y: 415, width: 652, height: 465))
        #expect(layout.content == CGRect(x: 2152, y: 421, width: 640, height: 400))
    }

    @Test func aScreenLeftOfTheMainOne() {
        var screen = external
        screen.frame.origin = CGPoint(x: -1920, y: 0)
        screen.visibleFrame.origin = CGPoint(x: -1920, y: 0)
        let layout = NotchGeometry.layout(for: screen, mode: .peek)
        #expect(layout.notch == CGRect(x: -1060, y: 1055, width: 200, height: 25))
        #expect(layout.panel == CGRect(x: -1286, y: 615, width: 652, height: 465))
    }

    @Test func autoHiddenMenuBarKeepsAVisibleNotch() {
        var screen = external
        screen.visibleFrame = screen.frame
        screen.menuBarThickness = 0
        #expect(NotchGeometry.layout(for: screen, mode: .peek).notch.height == 24)

        screen.menuBarThickness = 30
        #expect(NotchGeometry.layout(for: screen, mode: .peek).notch.height == 30)
    }

    @Test func expandedScalesDownOnAShortScreenKeeping16by10() {
        let short = ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            visibleFrame: CGRect(x: 0, y: 60, width: 1280, height: 636),
            safeAreaTop: 0, auxLeft: .zero, auxRight: .zero, menuBarThickness: 24
        )
        let layout = NotchGeometry.layout(for: short, mode: .expanded)
        // Usable height: 720 - 60 (Dock) - 24 (notch) - 34 - 6 - 8 = 588, rounded down to 585.
        #expect(layout.content.size == CGSize(width: 936, height: 585))
        #expect(layout.content.width / layout.content.height == 1.6)
        #expect(layout.panel.minY >= short.visibleFrame.minY)
        #expect(layout.contentScale == CGFloat(936) / 1024)
        #expect(NotchGeometry.layout(for: short, mode: .peek).content.size == CGSize(width: 640, height: 400))
    }

    @Test func expandedScalesDownOnANarrowScreen() {
        let portrait = ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 900, height: 1600),
            visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 1575),
            safeAreaTop: 0, auxLeft: .zero, auxRight: .zero, menuBarThickness: 25
        )
        let layout = NotchGeometry.layout(for: portrait, mode: .expanded)
        // Usable width: 900 - 16 - 12 = 872, which is exactly 16:10 at 545 high.
        #expect(layout.panel == CGRect(x: 8, y: 990, width: 884, height: 610))
        #expect(layout.content == CGRect(x: 14, y: 996, width: 872, height: 545))
    }

    @Test func aVirtualNotchIsOnWholePoints() {
        var odd = external
        odd.frame.size.width = 1365
        odd.visibleFrame.size.width = 1365
        let layout = NotchGeometry.layout(for: odd, mode: .peek)
        #expect(layout.notch.minX == layout.notch.minX.rounded())
        #expect(layout.panel.minX == layout.panel.minX.rounded())
    }

    @Test func mapsSurfacePointsToRenderPixels() {
        let render = PixelSize(width: 1024, height: 640)
        let peek = CGSize(width: 640, height: 400)
        func point(_ p: CGPoint, _ surface: CGSize) -> [UInt16]? {
            NotchGeometry.videoPoint(p, surfaceSize: surface, renderSize: render).map { [$0.x, $0.y] }
        }
        #expect(point(CGPoint(x: 320, y: 200), peek) == [512, 320])
        #expect(point(.zero, peek) == [0, 0])
        #expect(point(CGPoint(x: 0.5, y: 0.5), peek) == [0, 0])
        #expect(point(CGPoint(x: 640, y: 400), peek) == [1023, 639])
        #expect(point(CGPoint(x: -5, y: 900), peek) == [0, 639])
        // Letterboxing: a wider surface gets 30 pt bars at the sides, a taller one 50 pt above and below.
        #expect(point(CGPoint(x: 30, y: 0), CGSize(width: 700, height: 400)) == [0, 0])
        #expect(point(CGPoint(x: 0, y: 450), CGSize(width: 640, height: 500)) == [0, 639])
        #expect(point(CGPoint(x: 0, y: 50), CGSize(width: 640, height: 500)) == [0, 0])
    }

    @Test func nothingToMapOntoGivesNoPoint() {
        let render = PixelSize(width: 1024, height: 640)
        let peek = CGSize(width: 640, height: 400)
        #expect(NotchGeometry.videoPoint(.zero, surfaceSize: .zero, renderSize: render) == nil)
        #expect(NotchGeometry.videoPoint(CGPoint(x: CGFloat.nan, y: 5), surfaceSize: peek, renderSize: render) == nil)
        #expect(NotchGeometry.videoPoint(.zero, surfaceSize: CGSize(width: CGFloat.infinity, height: CGFloat.infinity), renderSize: render) == nil)
        #expect(NotchGeometry.videoPoint(.zero, surfaceSize: CGSize(width: CGFloat.leastNonzeroMagnitude, height: 1), renderSize: render) == nil)
        #expect(NotchGeometry.videoPoint(.zero, surfaceSize: peek, renderSize: PixelSize(width: 70_000, height: 640)) == nil)
        #expect(NotchGeometry.videoPoint(.zero, surfaceSize: peek, renderSize: PixelSize(width: 0, height: 640)) == nil)
    }
}
