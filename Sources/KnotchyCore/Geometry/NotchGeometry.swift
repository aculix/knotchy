import CoreGraphics

/// Rects are in global screen coordinates (AppKit's: origin bottom left, y up).
public struct ScreenInfo: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var safeAreaTop: CGFloat
    public var auxLeft: CGRect
    public var auxRight: CGRect
    public var menuBarThickness: CGFloat

    public init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
                auxLeft: CGRect, auxRight: CGRect, menuBarThickness: CGFloat) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxLeft = auxLeft
        self.auxRight = auxRight
        self.menuBarThickness = menuBarThickness
    }

    public var hasNotch: Bool {
        safeAreaTop > 0 && !auxLeft.isEmpty && !auxRight.isEmpty
    }
}

public enum PanelMode: Sendable {
    case peek
    case expanded
}

/// Global screen coordinates, y up; convert them for SwiftUI views and tracking areas.
public struct PanelLayout: Equatable, Sendable {
    public var notch: CGRect
    public var pill: CGRect
    /// Full size for its mode so the shape never clips; a Peek↔Expanded animation needs the larger.
    public var panel: CGRect
    public var toolbar: CGRect
    public var content: CGRect
    public var contentScale: CGFloat
}

public enum NotchGeometry {
    public static let toolbarHeight: CGFloat = 34
    public static let margin: CGFloat = 6
    public static let peekContent = CGSize(width: 640, height: 400)
    public static let expandedContent = CGSize(width: 1024, height: 640)
    public static let renderWidth: CGFloat = 1024
    public static let virtualNotchWidth: CGFloat = 200
    public static let minimumNotchHeight: CGFloat = 24
    public static let notchWidthRange: ClosedRange<CGFloat> = 120...300
    public static let pillEarWidth: CGFloat = 72
    public static let screenInset: CGFloat = 8
    public static let minimumContentHeight: CGFloat = 50

    public static func layout(for screen: ScreenInfo, mode: PanelMode) -> PanelLayout {
        let notch = notchRect(for: screen)
        let height = notch.height

        let base = mode == .peek ? peekContent : expandedContent
        // Ignores a side Dock: the panel may cover its top.
        let maxWidth = screen.frame.width - 2 * screenInset - 2 * margin
        let maxHeight = (screen.frame.maxY - screen.visibleFrame.minY) - height - toolbarHeight - margin - screenInset
        // Keep exactly 16:10 in whole points: the height is a multiple of 5, the width 8/5 of it.
        let fittingHeight = min(base.height, maxHeight, maxWidth * 5 / 8)
        let contentHeight = max(minimumContentHeight, (fittingHeight / 5).rounded(.down) * 5)
        let contentWidth = contentHeight * 8 / 5

        let panelWidth = contentWidth + 2 * margin
        let panelHeight = height + toolbarHeight + contentHeight + margin
        let centeredX = (notch.midX - panelWidth / 2).rounded()
        let panelX = min(max(centeredX, screen.frame.minX), screen.frame.maxX - panelWidth)
        let panel = CGRect(x: panelX, y: screen.frame.maxY - panelHeight, width: panelWidth, height: panelHeight)

        return PanelLayout(
            notch: notch,
            pill: notch.insetBy(dx: -pillEarWidth, dy: 0),
            panel: panel,
            toolbar: CGRect(x: panel.minX + margin, y: panel.maxY - height - toolbarHeight,
                            width: contentWidth, height: toolbarHeight),
            content: CGRect(x: panel.minX + margin, y: panel.minY + margin,
                            width: contentWidth, height: contentHeight),
            contentScale: contentWidth / renderWidth
        )
    }

    /// `point` is in a flipped view. Nil on degenerate input: drop the event rather than click at (0, 0).
    public static func videoPoint(_ point: CGPoint, surfaceSize: CGSize, renderSize: PixelSize) -> (x: UInt16, y: UInt16)? {
        let pixels = 1...65536
        guard point.x.isFinite, point.y.isFinite, surfaceSize.width.isFinite, surfaceSize.height.isFinite,
              surfaceSize.width > 0, surfaceSize.height > 0,
              pixels.contains(renderSize.width), pixels.contains(renderSize.height)
        else { return nil }
        let video = CGSize(width: renderSize.width, height: renderSize.height)
        let scale = min(surfaceSize.width / video.width, surfaceSize.height / video.height)
        guard scale > 0 else { return nil }
        let originX = (surfaceSize.width - video.width * scale) / 2
        let originY = (surfaceSize.height - video.height * scale) / 2
        let x = min(max((point.x - originX) / scale, 0), video.width - 1)
        let y = min(max((point.y - originY) / scale, 0), video.height - 1)
        return (UInt16(x), UInt16(y))
    }

    private static func notchRect(for screen: ScreenInfo) -> CGRect {
        if screen.hasNotch {
            let left = screen.auxLeft.maxX
            let right = screen.auxRight.minX
            let width = min(max(right - left, notchWidthRange.lowerBound), notchWidthRange.upperBound)
            return CGRect(x: (left + right) / 2 - width / 2, y: screen.frame.maxY - screen.safeAreaTop,
                          width: width, height: screen.safeAreaTop)
        }
        // The minimum keeps a virtual notch visible when the menu bar auto-hides.
        let height = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.menuBarThickness, minimumNotchHeight)
        return CGRect(x: (screen.frame.midX - virtualNotchWidth / 2).rounded(), y: screen.frame.maxY - height,
                      width: virtualNotchWidth, height: height)
    }
}
