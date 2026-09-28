import AppKit
import KnotchyCore
import Observation
import SwiftUI

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum Presentation: Equatable {
    case hidden
    case compact
    case banner
    case panel
}

@MainActor
@Observable
final class NotchChrome {
    static let earWidth: CGFloat = 64
    static let bannerWidth: CGFloat = 320
    static let bannerRowHeight: CGFloat = 34

    var presentation: Presentation = .hidden
    /// Lags `presentation` while retracting so the content shrinks into the notch with the shape.
    var content: Presentation = .hidden
    var reveal: CGFloat = 0
    var state: SessionState = .idle
    var notice: Notice?
    var notchSize = CGSize(width: 200, height: 32)
    var hasNotch = true
    var panelSize = CGSize(width: 652, height: 472)
    var panelOffsetX: CGFloat = 0
    var routeLabel: String?

    var bodySize: CGSize { Self.bodySize(presentation, notch: notchSize, panel: panelSize, hasNotch: hasNotch) }
    var topRadius: CGFloat { Self.topRadius(presentation) }
    var bottomRadius: CGFloat { Self.bottomRadius(presentation) }
    var offsetX: CGFloat { presentation == .panel ? panelOffsetX : 0 }

    static func bodySize(_ presentation: Presentation, notch: CGSize, panel: CGSize, hasNotch: Bool) -> CGSize {
        switch presentation {
        case .hidden: CGSize(width: notch.width, height: hasNotch ? notch.height : 0)
        case .compact: CGSize(width: notch.width + 2 * earWidth, height: notch.height)
        case .banner: CGSize(width: max(notch.width + 2 * earWidth, bannerWidth), height: notch.height + bannerRowHeight)
        case .panel: panel
        }
    }

    static func topRadius(_ presentation: Presentation) -> CGFloat {
        switch presentation {
        case .hidden: 0
        case .compact: 6
        case .banner: 8
        case .panel: 10
        }
    }

    static func bottomRadius(_ presentation: Presentation) -> CGFloat {
        switch presentation {
        case .hidden: 10
        case .compact: 12
        case .banner: 18
        case .panel: 22
        }
    }
}

/// Tracks the shape, not the window, which is larger while the shape animates.
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var trackingRect: CGRect = .zero {
        didSet { if trackingRect != oldValue { updateTrackingAreas() } }
    }
    /// Remove only this one; NSHostingView's own areas drive SwiftUI hover effects.
    private var shapeArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let shapeArea { removeTrackingArea(shapeArea) }
        shapeArea = nil
        guard !trackingRect.isEmpty else { return }
        let area = NSTrackingArea(rect: trackingRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        shapeArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === shapeArea { onEnter() } else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === shapeArea { onExit() } else { super.mouseExited(with: event) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchWindowController {
    private static let shadowPadding: CGFloat = 36

    private let controller: SessionController
    private let chrome = NotchChrome()
    private let panel = NotchPanel()
    private let host: TrackingHostingView<NotchRootView>
    private var screen: NSScreen?
    private var anchor = CGPoint.zero
    private var clickMonitor: Any?
    private var lastState: SessionState = .idle
    /// A finished animation only tidies up if no newer one has started.
    private var generation = 0
    private var trackingExtent: Extent?
    private let currentRouteLabel: () -> String?
    private var sessionRouteLabel: String?

    init(controller: SessionController, routeLabel: @escaping () -> String? = { nil }) {
        self.controller = controller
        currentRouteLabel = routeLabel
        host = TrackingHostingView(rootView: NotchRootView(controller: controller, chrome: chrome))
        host.sizingOptions = []
        host.onEnter = { [weak self] in self?.pointerEntered() }
        host.onExit = { [weak self] in self?.pointerExited() }
        panel.contentView = host
        // Global mouse monitors need no Accessibility permission.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            MainActor.assumeIsolated { controller.clickedOutside() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screen = nil
                self.panel.orderOut(nil)
                self.update()
            }
        }
        observe()
        update()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// So crossing the notch on the way to the menu bar doesn't open the folded pill.
    private static let hoverIntent: Duration = .milliseconds(150)
    private var pendingEnter: Task<Void, Never>?

    private func pointerEntered() {
        pendingEnter?.cancel()
        guard chrome.presentation == .compact else {
            controller.pointerEntered()
            return
        }
        pendingEnter = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverIntent)
            guard !Task.isCancelled else { return }
            self?.controller.pointerEntered()
        }
    }

    private func pointerExited() {
        pendingEnter?.cancel()
        pendingEnter = nil
        controller.pointerExited()
    }

    /// A key non-activating panel keeps the keyboard until it leaves the screen; `resignKey()` only notifies.
    private func relinquishKey() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func observe() {
        withObservationTracking {
            _ = controller.state
            _ = controller.notice
            _ = controller.setupFolded
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    static func presentation(for state: SessionState, notice: Notice?, setupFolded: Bool) -> Presentation {
        switch state {
        case .settingUp where setupFolded:
            .compact
        case .idle:
            notice == nil ? .hidden : .banner
        case .starting(_, folded: true), .live(.collapsed):
            .compact
        case .destroying, .destroyed, .failed(.ended), .failed(.destroyStuck):
            .banner
        case .starting(_, folded: false), .live(.peek), .live(.expanded), .failed(.start), .setupRequired, .settingUp:
            .panel
        }
    }

    private func update() {
        let state = controller.state
        let notice = controller.notice
        defer { lastState = state }
        let target = Self.presentation(for: state, notice: notice, setupFolded: controller.setupFolded)
        guard target != .hidden else {
            retract()
            return
        }

        if screen == nil || (state == .starting(.booting, folded: false) && lastState != state) {
            let next = Self.screenUnderPointer()
            if next != screen { panel.orderOut(nil) }
            screen = next
        }
        guard let screen else { return }
        // The route is chosen as the VM boots, so read it once connecting.
        if case .starting(.booting, _) = state, lastState != state { sessionRouteLabel = nil }
        if case .starting(.connecting, _) = state, lastState != state { sessionRouteLabel = currentRouteLabel() }
        let routeLabel = sessionRouteLabel
        let info = ScreenInfo(screen)
        let large: Bool
        switch state {
        case .live(.expanded): large = true
        case .starting(_, folded: false): large = controller.opensExpanded
        default: large = false
        }
        let layout = NotchGeometry.layout(for: info, mode: large ? .expanded : .peek)
        let notchSize = layout.notch.size
        let panelSize = layout.panel.size
        let panelOffsetX = layout.panel.midX - layout.notch.midX
        anchor = CGPoint(x: layout.notch.midX, y: info.frame.maxY)

        generation += 1
        let current = generation
        let apply = { [chrome] in
            chrome.presentation = target
            chrome.content = target
            chrome.reveal = 1
            chrome.state = state
            chrome.notice = notice
            chrome.notchSize = notchSize
            chrome.panelSize = panelSize
            chrome.panelOffsetX = panelOffsetX
            chrome.hasNotch = info.hasNotch
            chrome.routeLabel = routeLabel
        }
        let targetExtent = Self.extent(target, notch: notchSize, panel: panelSize, offset: panelOffsetX, hasNotch: info.hasNotch)
        setTracking(targetExtent)

        if !panel.isVisible {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                apply()
                chrome.presentation = .hidden
                chrome.reveal = 0
            }
            let hiddenExtent = Self.extent(.hidden, notch: notchSize, panel: panelSize, offset: 0, hasNotch: info.hasNotch)
            fitWindow(hiddenExtent, targetExtent)
            panel.orderFrontRegardless()
            // Draw while invisible and start ~2 frames later, or the first draw (fonts, symbols) stalls the animation.
            withTransaction(transaction) { host.layoutSubtreeIfNeeded() }
            panel.displayIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(35)) { [weak self] in
                guard let self, self.generation == current else { return }
                self.animate(from: .hidden, to: target, apply: apply, generation: current, extent: targetExtent)
            }
        } else {
            let from = chrome.presentation
            let currentExtent = Self.extent(from, notch: chrome.notchSize, panel: chrome.panelSize,
                                            offset: chrome.offsetX, hasNotch: chrome.hasNotch)
            fitWindow(currentExtent, targetExtent)
            animate(from: from, to: target, apply: apply, generation: current, extent: targetExtent)
        }

        // Only a click into the page (VideoView) makes the panel key; opening never does.
        if target != .panel { relinquishKey() }
    }

    private func animate(from: Presentation, to target: Presentation, apply: @escaping () -> Void,
                         generation current: Int, extent: Extent) {
        withAnimation(Self.animation(from: from, to: target), completionCriteria: .removed) {
            apply()
        } completion: { [weak self] in
            guard let self, self.generation == current else { return }
            self.fitWindow(extent)
        }
    }

    private func retract() {
        guard panel.isVisible else {
            screen = nil
            return
        }
        generation += 1
        let current = generation
        setTracking(nil)
        relinquishKey()
        withAnimation(Motion.hide, completionCriteria: .removed) {
            chrome.presentation = .hidden
            chrome.reveal = 0
        } completion: { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
            self.screen = nil
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { self.chrome.content = .hidden }
        }
    }

    private static func animation(from: Presentation, to target: Presentation) -> Animation {
        switch (from, target) {
        case (.panel, .panel): Motion.resize
        case (_, .panel): Motion.open
        case (.panel, _): Motion.fold
        default: Motion.small
        }
    }

    // MARK: - Geometry

    struct Extent {
        /// Reach on the wider side of the notch's centre line.
        var halfWidth: CGFloat
        var height: CGFloat
        var offset: CGFloat = 0
        var width: CGFloat = 0
    }

    static func extent(_ presentation: Presentation, notch: CGSize, panel: CGSize, offset: CGFloat, hasNotch: Bool) -> Extent {
        let body = NotchChrome.bodySize(presentation, notch: notch, panel: panel, hasNotch: hasNotch)
        let width = body.width + 2 * NotchChrome.topRadius(presentation)
        let shift = presentation == .panel ? offset : 0
        return Extent(halfWidth: width / 2 + abs(shift), height: body.height, offset: shift, width: width)
    }

    private func fitWindow(_ extents: Extent...) {
        let half = (extents.map(\.halfWidth).max() ?? 0) + Self.shadowPadding
        let height = (extents.map(\.height).max() ?? 0) + Self.shadowPadding
        let frame = CGRect(x: (anchor.x - half).rounded(), y: anchor.y - height.rounded(.up),
                           width: (2 * half).rounded(.up), height: height.rounded(.up))
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            // Lay out outside any animation, or the shape animates across from the old window position.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { host.layoutSubtreeIfNeeded() }
        }
        refreshTracking()
    }

    private func setTracking(_ extent: Extent?) {
        trackingExtent = extent
        refreshTracking()
    }

    private func refreshTracking() {
        guard let extent = trackingExtent else {
            host.trackingRect = .zero
            return
        }
        let bounds = host.bounds
        let y = host.isFlipped ? bounds.minY : bounds.maxY - extent.height
        host.trackingRect = CGRect(x: bounds.midX + extent.offset - extent.width / 2, y: y,
                                   width: extent.width, height: extent.height)
    }

    #if DEBUG
    func snapshot(to directory: URL, name: String) {
        guard panel.isVisible else {
            FileHandle.standardError.write(Data("snapshot \(name): window hidden\n".utf8))
            return
        }
        DebugSnapshot.write(host, to: directory.appendingPathComponent("\(name).png"))
    }
    #endif

    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }
}

extension ScreenInfo {
    /// The only code that reads `NSScreen`.
    @MainActor
    init(_ screen: NSScreen) {
        func global(_ rect: CGRect?) -> CGRect {
            guard let rect, !rect.isEmpty else { return .zero }
            // The auxiliary areas are documented in screen coordinates; make them global.
            return screen.frame.contains(rect.origin) ? rect : rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        }
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame,
                  safeAreaTop: screen.safeAreaInsets.top,
                  auxLeft: global(screen.auxiliaryTopLeftArea), auxRight: global(screen.auxiliaryTopRightArea),
                  menuBarThickness: NSStatusBar.system.thickness)
    }
}
