import AppKit
import KnotchyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let backend: ContainerCLIBackend
    let controller: SessionController
    let services: ServicesProvider
    let settings = AppSettings()
    let vmStatus: VMStatus
    let unsupported: Unsupported?
    let setupFlow: SetupFlow
    var isSupportedMac: Bool { unsupported == nil }
    private(set) lazy var setupWindow = SetupWindowController(
        unsupported.map(SetupWindowController.Content.unsupported) ?? .setup(setupFlow))
    private(set) lazy var settingsWindow = SettingsWindowController(app: self)
    private var notch: NotchWindowController?
    private var copiedLinkHotKey: GlobalHotKey?
    private var wantsCopiedLinkHotKey = false
    private var signalSources: [DispatchSourceSignal] = []
    private var quitting = false

    override init() {
        unsupported = Self.detectUnsupported()
        let vmSources = Bundle.main.resourceURL?.appendingPathComponent("vm")
        let hasSources = vmSources.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Containerfile").path) } ?? false
        backend = ContainerCLIBackend(vmSources: hasSources ? vmSources : nil)
        controller = SessionController(
            backend: backend,
            connector: StreamClient(renderSize: SessionController.renderSize),
            diskSpace: SystemDiskSpace(),
            hostNetworks: { HostNetworks.current() },
            requestQuit: { NSApp.terminate(nil) }
        )
        services = ServicesProvider(controller: controller)
        vmStatus = VMStatus(backend: backend, controller: controller)
        setupFlow = SetupFlow(host: SystemHost(), installer: SystemRuntimeInstaller(), driver: controller)
        super.init()
        controller.quitsWhenIdle = false
        controller.showSetup = { [weak self] in self?.setupWindow.show() }
        if isSupportedMac {
            settings.onChange = { [weak self] in self?.applySettings() }
            applySettings()
        } else {
            services.redirect = { [weak self] in self?.setupWindow.show() }
        }
    }

    private static func detectUnsupported() -> Unsupported? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["KNOTCHY_PRETEND"] == "no-virtualization" { return .noVirtualization }
        #endif
        return SystemHost.unsupported()
    }

    private func applySettings() {
        settings.apply(to: controller)
        backend.setNetworkRoute(settings.route)
        guard settings.copiedLinkShortcut != wantsCopiedLinkHotKey else { return }
        wantsCopiedLinkHotKey = settings.copiedLinkShortcut
        if wantsCopiedLinkHotKey {
            copiedLinkHotKey = GlobalHotKey.openCopiedLink { [services] in services.openCopiedLink() }
            if copiedLinkHotKey == nil { ServicesLog.write("\(GlobalHotKey.openCopiedLinkLabel) is taken by another app") }
        } else {
            copiedLinkHotKey = nil
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Registered before launch finishes, so a Services request that launched the app isn't lost.
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let directory = DebugTour.argument(after: "--setup-snapshot") {
            Task {
                await DebugTour.snapshotSetup(app: self, to: URL(fileURLWithPath: directory))
                NSApp.terminate(nil)
            }
            return
        }
        #endif
        guard isSupportedMac else { return setupWindow.show() }
        notch = NotchWindowController(controller: controller, routeLabel: { [backend] in backend.lastStartedRoute.label })
        vmStatus.refresh()

        // Route Ctrl-C, kill and logout through applicationShouldTerminate so the VMs get destroyed.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        #if DEBUG
        let all = CommandLine.arguments
        if let index = all.firstIndex(of: "--tour"), index + 2 < all.count, let url = URL(string: all[index + 2]),
           let notch {
            let directory = URL(fileURLWithPath: all[index + 1])
            Task { await DebugTour.run(controller: controller, snapshot: { notch.snapshot(to: directory, name: $0) }, url: url) }
            return
        }
        if all.contains("--settings-timing") {
            Task {
                await DebugTour.timeNetworkSwitching(app: self)
                NSApp.terminate(nil)
            }
            return
        }
        if let index = all.firstIndex(of: "--settings-snapshot"), index + 1 < all.count {
            let directory = URL(fileURLWithPath: all[index + 1])
            Task {
                await DebugTour.snapshotSettings(app: self, to: directory)
                NSApp.terminate(nil)
            }
            return
        }
        if let index = all.firstIndex(of: "--tour-timing"), index + 1 < all.count, let url = URL(string: all[index + 1]) {
            Task { await DebugTour.run(controller: controller, snapshot: nil, url: url) }
            return
        }
        #endif

        Task { await openSetupIfNeeded() }
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let first = arguments.first { controller.open(text: first) }
    }

    private func openSetupIfNeeded() async {
        let runtime = await backend.runtimeStatus()
        let completed = UserDefaults.standard.bool(forKey: SetupLaunchRule.completedKey)
        if SetupLaunchRule.shouldOpen(hostSupported: true, setupCompleted: completed, runtime: runtime) {
            setupWindow.show()
        }
    }

    // From the browser extensions: Chrome's Services menu never sees a link's address.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard isSupportedMac else { return setupWindow.show() }
        for url in urls where url.scheme == "knotchy" && url.host() == "open" {
            let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value
            ServicesLog.write("knotchy:// request, link \(link == nil ? "missing" : "present")")
            if let link, let target = URL(string: link) {
                controller.open(target)
            } else {
                controller.open(text: "")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        quitting = true
        setupFlow.cancel()
        if setupFlow.isDownloading { SystemRuntimeInstaller.removeLeftovers() }
        // Not Now mid-build closes the window before the build ends.
        if setupFlow.allRequiredDone { UserDefaults.standard.set(true, forKey: SetupLaunchRule.completedKey) }
        // Synchronous on purpose: terminate: often runs inside a non-reentrant main-queue block; awaiting here deadlocked.
        notch?.hide()
        CATransaction.flush()
        CLIRunner.stopBuilds()
        controller.closeBackendChain()
        let ids = Array(controller.liveIDs.snapshot)
        if !ids.isEmpty { backend.destroyBlocking(ids: ids, deadline: .seconds(20)) }
        return .terminateNow
    }
}

@MainActor
final class ServicesProvider: NSObject {
    private let controller: SessionController
    /// In minimal mode, requests only bring the explanation window forward, so the calling app gets a normal reply.
    var redirect: (@MainActor () -> Void)?

    init(controller: SessionController) {
        self.controller = controller
    }

    @objc func openLink(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(from: pasteboard, service: "Open in Knotchy")
    }

    @objc func openCopiedLink(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(from: .general, service: "Open Copied Link in Knotchy")
    }

    func openCopiedLink() {
        open(from: .general, service: "Shortcut")
    }

    private func open(from pasteboard: NSPasteboard, service: String) {
        if let redirect { return redirect() }
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let url: URL?
        let source: String
        if let found = urls.first(where: { LinkIntake.validate($0) != nil }) {
            (url, source) = (found, "url")
        } else if let html = pasteboard.string(forType: .html), let found = LinkIntake.extractURL(fromHTML: html) {
            // A selected hyperlink's text rarely holds the address; its HTML does.
            (url, source) = (found, "html")
        } else if let found = Self.firstLink(inRTF: pasteboard.data(forType: .rtf)) {
            (url, source) = (found, "rtf")
        } else if let text = pasteboard.string(forType: .string), let found = LinkIntake.extractURL(from: text) {
            (url, source) = (found, "text")
        } else {
            (url, source) = (nil, "none")
        }
        ServicesLog.write("\(service): types \(types), link from \(source)")
        if let url {
            controller.open(url)
        } else {
            controller.open(text: "")
        }
    }

    private static func firstLink(inRTF data: Data?) -> URL? {
        guard let data, let text = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
        var found: URL?
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            if let url, let valid = LinkIntake.validate(url) {
                found = valid
                stop.pointee = true
            }
        }
        return found
    }
}

// Pasteboard types and sources only; never log the links themselves.
enum ServicesLog {
    static func write(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Knotchy.log")
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }
}
