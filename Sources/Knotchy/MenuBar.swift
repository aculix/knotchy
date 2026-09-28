import AppKit
import KnotchyCore
import Observation
import SwiftUI

struct KnotchyMenu: View {
    let app: AppDelegate
    @Bindable var settings: AppSettings

    private var controller: SessionController { app.controller }

    var body: some View {
        if app.vmStatus.needsSetup {
            Button("Set Up Knotchy…") { app.setupWindow.show() }
            Divider()
        }

        if let session = SessionSummary(controller.state, url: controller.pageURL ?? controller.openedURL,
                                        setupFolded: controller.setupFolded) {
            Section(session.title) {
                if session.canShow {
                    Button("Show Panel") { controller.showPanel() }
                }
                if session.canDestroy {
                    Button("Destroy VM") { controller.destroy() }
                }
            }
            Divider()
        }

        Button("Open Copied Link") { app.services.openCopiedLink() }
            .keyboardShortcut("l", modifiers: [.control, .option, .command])

        Divider()

        Picker("Auto-Destroy Folded Pages", selection: $settings.autoDestroyMinutes) {
            ForEach(AppSettings.autoDestroyChoices, id: \.self) { minutes in
                Text(minutes == 1 ? "After 1 Minute" : "After \(minutes) Minutes").tag(minutes)
            }
        }
        Picker("Open Pages In", selection: $settings.opensLarge) {
            Text("Small Panel").tag(false)
            Text("Large Panel").tag(true)
        }
        Menu("Connection") {
            Picker("Connection", selection: connection) {
                Text("Direct").tag(Connection.direct)
                if !settings.proxyHost.isEmpty {
                    Text("Proxy (\(settings.proxyHost):\(String(settings.proxyPort)))").tag(Connection.proxy)
                }
                if !settings.wireGuardNames.isEmpty {
                    Section("WireGuard VPN") {
                        ForEach(settings.wireGuardNames, id: \.self) { Text($0).tag(Connection.vpn($0)) }
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Network Settings…") { showSettings(.network) }
        }

        Divider()

        Button {
            controller.rebuildImage()
        } label: {
            Text("Rebuild VM")
            Text(app.vmStatus.summary)
        }
        .disabled(isSettingUp || app.vmStatus.image == .noContainerTool || app.vmStatus.needsSetup)

        Divider()

        if !app.vmStatus.needsSetup {
            Button("Set Up Knotchy…") { app.setupWindow.show() }
        }
        Button("Settings…") { showSettings(nil) }
            .keyboardShortcut(",")
        Button("Quit Knotchy") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private enum Connection: Hashable {
        case direct, proxy, vpn(String)
    }

    private var connection: Binding<Connection> {
        Binding {
            switch settings.networkMode {
            case .direct: .direct
            case .proxy: .proxy
            case .vpn: .vpn(settings.wireGuardServer)
            }
        } set: { choice in
            switch choice {
            case .direct:
                settings.networkMode = .direct
            case .proxy:
                settings.networkMode = .proxy
            case .vpn(let server):
                settings.wireGuardServer = server
                settings.networkMode = .vpn
            }
        }
    }

    private var isSettingUp: Bool {
        if case .settingUp = controller.state { true } else { false }
    }

    private func showSettings(_ section: SettingsTab?) {
        app.settingsWindow.show(section)
    }
}

@MainActor
@Observable
final class VMStatus {
    private(set) var image: ContainerCLIBackend.ImageStatus?
    private(set) var runtime: RuntimeStatus?
    @ObservationIgnored private let backend: ContainerCLIBackend
    @ObservationIgnored private let controller: SessionController

    init(backend: ContainerCLIBackend, controller: SessionController) {
        self.backend = backend
        self.controller = controller
        watchSetup()
    }

    var needsSetup: Bool {
        switch runtime {
        case .missing?, .outdated?: true
        default: false
        }
    }

    var runtimeSummary: String {
        switch runtime {
        case nil: "Checking…"
        case .missing: "Not installed"
        case .outdated(let version): "Apple container \(version) (too old)"
        case .current(let version?): "Apple container \(version)"
        case .current(nil): "Apple container (version unknown)"
        }
    }

    func refresh() {
        Task {
            let runtime = await backend.runtimeStatus()
            if runtime != self.runtime { self.runtime = runtime }
            let status = await backend.imageStatus()
            if status != image { image = status }
        }
    }

    var summary: String {
        if needsSetup { return "Setup isn't finished" }
        return switch image {
        case nil: "Checking…"
        case .noContainerTool: "Setup isn't finished"
        case .missing: "Not built yet"
        case .built(nil): "Built"
        case .built(let date?): "Built " + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        }
    }

    private func watchSetup() {
        let wasSettingUp: Bool
        if case .settingUp = controller.state { wasSettingUp = true } else { wasSettingUp = false }
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if wasSettingUp { self.refresh() }
                self.watchSetup()
            }
        }
    }
}

struct SessionSummary {
    var title: String
    var canShow: Bool
    var canDestroy: Bool

    init?(_ state: SessionState, url: URL?, setupFolded: Bool) {
        let host = url?.host().map { " — \($0)" } ?? ""
        switch state {
        case .starting(_, let folded):
            (title, canShow, canDestroy) = ("Opening\(host)", folded, true)
        case .live(let mode):
            (title, canShow, canDestroy) = ("Open\(host)", mode == .collapsed, true)
        case .settingUp(let issue):
            (title, canShow, canDestroy) = (Self.setupTitle(issue), setupFolded, false)
        case .destroying:
            (title, canShow, canDestroy) = ("Destroying the VM…", false, false)
        default:
            return nil
        }
    }

    static func setupTitle(_ issue: SetupIssue) -> String {
        switch issue {
        case .cliMissing: "Installing the container runtime…"
        case .cliOutdated: "Updating the container runtime…"
        case .serviceStopped, .kernelMissing: "Starting the container runtime…"
        default: "Building the VM…"
        }
    }
}
