import AVFoundation
import AppKit
import CoreMedia
import KnotchyCore
import SwiftUI
import Synchronization

final class LatestFrame: Sendable {
    private let frame = Mutex<DecodedFrame?>(nil)

    func put(_ new: DecodedFrame) -> Bool {
        frame.withLock { slot in
            defer { slot = new }
            return slot == nil
        }
    }

    func take() -> DecodedFrame? {
        frame.withLock { slot in
            defer { slot = nil }
            return slot
        }
    }
}

struct VideoSurface: NSViewRepresentable {
    let controller: SessionController

    func makeNSView(context: Context) -> VideoView {
        let view = VideoView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: VideoView, context: Context) {
        view.attach(controller.connection)
    }
}

final class VideoView: NSView {
    weak var controller: SessionController?
    private var connection: (any StreamConnection)?
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var scrollRemainder = CGPoint.zero
    /// WebKit scrolls about 40 px per wheel tick.
    private let scrollStep: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
        #if DEBUG
        if ProcessInfo.processInfo.environment["KNOTCHY_LOG_LAYOUT"] != nil {
            print(String(format: "%.3f video %.0fx%.0f", CACurrentMediaTime(), bounds.width, bounds.height))
        }
        #endif
    }

    func attach(_ connection: (any StreamConnection)?) {
        guard self.connection !== connection else { return }
        self.connection = connection
        displayLayer.sampleBufferRenderer.flush()
        let slot = LatestFrame()
        connection?.setFrameHandler { [weak self] frame in
            // Keep only the newest frame so a busy main thread drops frames instead of queueing multi-MB buffers.
            guard slot.put(frame) else { return }
            DispatchQueue.main.async {
                guard let frame = slot.take() else { return }
                MainActor.assumeIsolated { self?.show(frame.pixelBuffer) }
            }
        }
    }

    private func show(_ pixelBuffer: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func videoPoint(_ event: NSEvent) -> (x: UInt16, y: UInt16)? {
        NotchGeometry.videoPoint(convert(event.locationInWindow, from: nil), surfaceSize: bounds.size,
                                 renderSize: SessionController.renderSize)
    }

    private func mods(_ event: NSEvent) -> Modifiers {
        var mods: Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods.insert(.shift) }
        // ⌘ maps to Ctrl so ⌘A/C/V/X/Z work like Linux shortcuts in the VM.
        if flags.contains(.control) || flags.contains(.command) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.alt) }
        let buttons = NSEvent.pressedMouseButtons
        if buttons & 1 != 0 { mods.insert(.leftButton) }
        if buttons & 2 != 0 { mods.insert(.rightButton) }
        if buttons & 4 != 0 { mods.insert(.middleButton) }
        return mods
    }

    private func sendMove(_ event: NSEvent) {
        guard let point = videoPoint(event) else { return }
        connection?.send(.pointerMove(x: point.x, y: point.y, mods: mods(event)))
    }

    private func sendButton(_ event: NSEvent, _ button: PointerButton, pressed: Bool) {
        guard let point = videoPoint(event) else { return }
        connection?.send(.pointerButton(button, pressed: pressed, x: point.x, y: point.y, mods: mods(event)))
    }

    override func mouseMoved(with event: NSEvent) { sendMove(event) }
    override func mouseDragged(with event: NSEvent) { sendMove(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMove(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMove(event) }

    override func mouseDown(with event: NSEvent) {
        controller?.panelClicked()
        window?.makeKey()
        window?.makeFirstResponder(self)
        sendButton(event, .left, pressed: true)
    }

    override func mouseUp(with event: NSEvent) { sendButton(event, .left, pressed: false) }
    override func rightMouseDown(with event: NSEvent) { sendButton(event, .right, pressed: true) }
    override func rightMouseUp(with event: NSEvent) { sendButton(event, .right, pressed: false) }
    override func otherMouseDown(with event: NSEvent) { sendButton(event, .middle, pressed: true) }
    override func otherMouseUp(with event: NSEvent) { sendButton(event, .middle, pressed: false) }

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            scrollRemainder.x += dx
            scrollRemainder.y += dy
            dx = (scrollRemainder.x / scrollStep).rounded(.towardZero)
            dy = (scrollRemainder.y / scrollStep).rounded(.towardZero)
            scrollRemainder.x -= dx * scrollStep
            scrollRemainder.y -= dy * scrollStep
        } else {
            dx = dx == 0 ? 0 : (dx > 0 ? max(1, dx.rounded()) : min(-1, dx.rounded()))
            dy = dy == 0 ? 0 : (dy > 0 ? max(1, dy.rounded()) : min(-1, dy.rounded()))
        }
        guard dx != 0 || dy != 0, let point = videoPoint(event) else { return }
        connection?.send(.scroll(ticksX: Int16(clamping: Int(dx)), ticksY: Int16(clamping: Int(dy)), x: point.x, y: point.y))
    }

    // MARK: - Keyboard

    private static let specialKeys: [UInt16: String] = [
        36: "Return", 76: "KP_Enter", 48: "Tab", 51: "BackSpace", 117: "Delete", 53: "Escape",
        49: "space", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
        115: "Home", 119: "End", 116: "Page_Up", 121: "Page_Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private func keyName(_ event: NSEvent) -> String? {
        if let name = Self.specialKeys[event.keyCode] { return name }
        let flags = event.modifierFlags
        let characters = flags.contains(.command) || flags.contains(.control)
            ? event.charactersIgnoringModifiers?.lowercased()
            : event.characters
        guard let scalars = characters?.unicodeScalars, scalars.count == 1, let scalar = scalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        return String(scalar)
    }

    private func sendKey(_ event: NSEvent, pressed: Bool) {
        guard let name = keyName(event) else { return }
        connection?.send(.key(pressed: pressed, mods: mods(event), name: name))
    }

    override func keyDown(with event: NSEvent) { sendKey(event, pressed: true) }
    override func keyUp(with event: NSEvent) { sendKey(event, pressed: false) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command), let controller else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = event.modifierFlags.contains(.shift)
        switch (key, shift) {
        case ("w", false), (".", false): controller.destroy()
        case ("e", true): controller.state == .live(.expanded) ? controller.shrink() : controller.expand()
        case ("[", false): controller.goBack()
        case ("]", false): controller.goForward()
        case ("r", false): controller.reload()
        case ("q", false): NSApp.terminate(nil)
        default:
            sendKey(event, pressed: true)
            sendKey(event, pressed: false)
        }
        return true
    }
}
