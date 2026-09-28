#if DEBUG
import AppKit
import KnotchyCore
import QuartzCore
import SwiftUI

// `Knotchy --tour <dir> <url>` saves PNGs of each state; `--tour-timing <url>` reports dropped frames.
// Checks the UI without screen recording permission; video doesn't appear in the snapshots.
@MainActor
enum DebugTour {
    static func run(controller: SessionController, snapshot: ((String) -> Void)?, url: URL) async {
        let meter = FrameMeter()
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func step(_ name: String, _ times: [Double], _ action: () -> Void) async {
            if snapshot == nil { meter.start() }
            action()
            var elapsed = 0.0
            for time in times {
                await wait(time - elapsed)
                elapsed = time
                snapshot?("\(name)-\(Int(time * 1000))ms")
            }
            if snapshot == nil { print("\(name): \(meter.stop())") }
        }

        await step("01-no-link", [0.08, 0.2, 0.6, 1.0]) { controller.open(text: "no link here") }
        await wait(2.5)
        await step("02-opening", [0.06, 0.12, 0.2, 0.3, 0.45, 0.7, 1.2]) { controller.open(url) }
        for _ in 0..<300 where controller.state != .live(.peek) { await wait(0.1) }
        await wait(1)
        await step("04-expand", [0.08, 0.16, 0.25, 0.4, 1.0]) { controller.expand() }
        await step("05-shrink", [0.08, 0.16, 0.3, 1.0]) { controller.shrink() }
        await step("06-fold", [0.06, 0.12, 0.2, 0.35, 1.0]) { controller.clickedOutside() }
        await wait(0.5)
        await step("07-unfold", [0.06, 0.12, 0.2, 0.35, 1.0]) { controller.pointerEntered() }
        await step("08-destroy", [0.08, 0.2, 0.4, 0.8, 1.6, 2.2, 2.6]) { controller.destroy() }
        await wait(1)
        await step("09-reopen", [0.06, 0.12, 0.2, 0.3, 0.45, 0.7, 1.2]) { controller.open(url) }
        for _ in 0..<300 where controller.state != .live(.peek) { await wait(0.1) }
        await step("10-destroy", [0.3, 2.6]) { controller.destroy() }
        await wait(1)
        NSApp.terminate(nil)
    }

    static func argument(after flag: String) -> String? {
        let all = CommandLine.arguments
        guard let index = all.firstIndex(of: flag), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    /// `Knotchy --setup-snapshot <dir>`; with `KNOTCHY_PRETEND=no-virtualization` it shows minimal mode.
    static func snapshotSetup(app: AppDelegate, to directory: URL) async {
        app.setupWindow.show()
        try? await Task.sleep(for: .seconds(5))
        guard let window = app.setupWindow.window, let view = window.contentView else { return }
        print("setup: window \(window.frame.size)")
        DebugSnapshot.write(view, to: directory.appendingPathComponent("setup.png"))
    }
}

extension DebugTour {
    static func snapshotSettings(app: AppDelegate, to directory: URL) async {
        let settings = app.settings
        let saved = (settings.networkMode, settings.proxyHost)
        let cases: [(String, SettingsTab, AppSettings.NetworkMode)] = [
            ("general", .general, .direct), ("network-direct", .network, .direct),
            ("network-proxy", .network, .proxy), ("network-vpn", .network, .vpn), ("vm", .vm, .direct),
        ]
        for (name, section, mode) in cases {
            settings.networkMode = mode
            if mode == .proxy { settings.proxyHost = "192.168.1.20" }
            app.settingsWindow.show(section)
            try? await Task.sleep(for: .seconds(0.8))
            guard let window = app.settingsWindow.window, let view = window.contentView else { continue }
            print("\(name): window \(window.frame.size)")
            DebugSnapshot.write(view, to: directory.appendingPathComponent("settings-\(name).png"))
        }
        app.settingsWindow.window?.orderOut(nil)
        (settings.networkMode, settings.proxyHost) = saved
    }

    static func timeNetworkSwitching(app: AppDelegate) async {
        let settings = app.settings
        let saved = settings.networkMode
        settings.networkMode = .direct
        app.settingsWindow.show(.general)
        try? await Task.sleep(for: .seconds(1))
        let meter = FrameMeter()
        let steps: [(String, () -> Void)] = [
            ("section network", { app.settingsWindow.show(.network) }),
            ("mode proxy", { settings.networkMode = .proxy }),
            ("mode vpn", { settings.networkMode = .vpn }),
            ("mode direct", { settings.networkMode = .direct }),
            ("section vm", { app.settingsWindow.show(.vm) }),
            ("section general", { app.settingsWindow.show(.general) }),
            ("section network", { app.settingsWindow.show(.network) }),
        ]
        for (name, step) in steps {
            meter.start()
            step()
            try? await Task.sleep(for: .seconds(0.8))
            let size = app.settingsWindow.window?.frame.size ?? .zero
            print("\(name) (window \(Int(size.width))x\(Int(size.height))): \(meter.stop())")
        }
        app.settingsWindow.window?.orderOut(nil)
        settings.networkMode = saved
    }
}

enum DebugSnapshot {
    @MainActor
    static func write(_ view: NSView, to url: URL) {
        guard let layer = view.layer, let window = view.window else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped || !layer.isGeometryFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        (layer.presentation() ?? layer).render(in: context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

// SwiftUI animates on the main thread, so a late display-link callback is a dropped frame.
@MainActor
final class FrameMeter: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var nominal: CFTimeInterval = 1.0 / 60

    func start() {
        stamps = []
        link = (NSScreen.main ?? NSScreen.screens[0]).displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(CACurrentMediaTime())
        nominal = link.targetTimestamp - link.timestamp
    }

    func stop() -> String {
        link?.invalidate()
        link = nil
        let intervals = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        func ms(_ t: CFTimeInterval) -> String { String(format: "%.0f", t * 1000) }
        // "duration@end", both in ms, end measured from the start.
        let late = zip(intervals, stamps.dropFirst()).filter { $0.0 > nominal * 1.5 }
            .map { "\(ms($0.0))@\(ms($0.1 - (stamps.first ?? 0)))" }
        return "\(stamps.count) frames at \(ms(nominal)) ms, worst \(ms(intervals.max() ?? 0)) ms, "
            + "\(late.count) late \(late)"
    }
}
#endif
