import KnotchyCore
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, network, vm

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .network: "Network"
        case .vm: "VM"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .network: "network"
        case .vm: "shippingbox"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var section: SettingsTab? = .general
}

@MainActor
final class SettingsWindowController {
    static let size = CGSize(width: 700, height: 470)

    private let app: AppDelegate
    private let navigation = SettingsNavigation()
    private(set) var window: NSWindow?

    init(app: AppDelegate) {
        self.app = app
    }

    func show(_ section: SettingsTab? = nil) {
        if let section { navigation.section = section }
        let window = self.window ?? makeWindow()
        self.window = window
        // An accessory app's windows open behind the frontmost app unless it activates first.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsView(app: app, settings: app.settings, navigation: navigation))
        host.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "Knotchy Settings"
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.size)
        window.center()
        window.setFrameAutosaveName("KnotchySettings")
        return window
    }
}

struct SettingsView: View {
    let app: AppDelegate
    @Bindable var settings: AppSettings
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $navigation.section) { section in
                Label(section.title, systemImage: section.symbol)
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch navigation.section ?? .general {
                case .general: GeneralSettings(settings: settings)
                case .network: NetworkSettings(settings: settings)
                case .vm: VMSettings(controller: app.controller, status: app.vmStatus)
                }
            }
            .navigationTitle((navigation.section ?? .general).title)
        }
        .frame(width: SettingsWindowController.size.width, height: SettingsWindowController.size.height)
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    @State private var opensAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Destroy folded pages", selection: $settings.autoDestroyMinutes) {
                    ForEach(AppSettings.autoDestroyChoices, id: \.self) { minutes in
                        Text(minutes == 1 ? "After 1 minute" : "After \(minutes) minutes").tag(minutes)
                    }
                }
                Picker("Open pages in", selection: $settings.opensLarge) {
                    Text("Small panel").tag(false)
                    Text("Large panel").tag(true)
                }
            } footer: {
                Text("A page folded into the notch keeps running until it's destroyed.")
            }

            Section {
                Toggle("Open copied link with \(GlobalHotKey.openCopiedLinkLabel)", isOn: $settings.copiedLinkShortcut)
            } footer: {
                Text("Copy a link anywhere (in Chrome: right-click › Copy Link Address), then press \(GlobalHotKey.openCopiedLinkLabel).")
            }

            Section {
                Toggle("Open Knotchy at login", isOn: Binding {
                    opensAtLogin
                } set: { enabled in
                    loginError = LoginItem.set(enabled)
                    opensAtLogin = LoginItem.isEnabled
                })
            } footer: {
                if let loginError { Text(loginError).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onAppear { opensAtLogin = LoginItem.isEnabled }
    }
}

// Every mode's form stays laid out, inactive ones hidden, so switching crossfades instead of resizing the window.
private struct NetworkSettings: View {
    @Bindable var settings: AppSettings
    @State private var importing = false
    @State private var importMessage: String?

    var body: some View {
        ZStack(alignment: .top) {
            ForEach([AppSettings.NetworkMode.direct, .proxy, .vpn], id: \.self) { mode in
                let active = settings.networkMode == mode
                NetworkForm(settings: settings, mode: mode, importMessage: importMessage, importing: $importing)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .animation(active ? .easeOut(duration: 0.2).delay(0.05) : .easeOut(duration: 0.1), value: active)
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "conf") ?? .data, .zip],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { importMessage = await settings.importWireGuard(from: urls) }
            }
        }
    }
}

private struct NetworkForm: View {
    @Bindable var settings: AppSettings
    let mode: AppSettings.NetworkMode
    let importMessage: String?
    @Binding var importing: Bool

    var body: some View {
        Form {
            Section {
                Picker("Connection", selection: $settings.networkMode) {
                    Text("Direct").tag(AppSettings.NetworkMode.direct)
                    Text("Proxy").tag(AppSettings.NetworkMode.proxy)
                    Text("WireGuard VPN").tag(AppSettings.NetworkMode.vpn)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text(description)
            }

            details
                .disabled(settings.networkMode != mode)   // No tabbing into a hidden form.
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var description: String {
        switch mode {
        case .direct: "Pages go out through this Mac's internet connection, and can reach nothing else."
        case .proxy: "Pages can only go out through the proxy. If it's down, they don't load."
        case .vpn: "Pages can only go out through the VPN. If it's down, they don't load. The rest of your Mac isn't affected."
        }
    }

    @ViewBuilder private var details: some View {
        switch mode {
        case .direct:
            Section {
                LabeledContent("Internet", value: "This Mac's connection")
                LabeledContent("Blocked", value: "Your Mac, your network, IPv6")
                LabeledContent("DNS", value: "1.1.1.1 (Cloudflare)")
            } header: {
                Text("Direct")
            }
        case .proxy:
            Section {
                Picker("Type", selection: $settings.proxyKind) {
                    Text("HTTP").tag(ProxySettings.Kind.http)
                    Text("SOCKS5").tag(ProxySettings.Kind.socks5)
                }
                TextField("Server", text: $settings.proxyHost, prompt: Text("proxy.example.com"))
                TextField("Port", value: $settings.proxyPort, format: .number.grouping(.never), prompt: Text("8080"))
                TextField("Username", text: $settings.proxyUsername, prompt: Text("Optional"))
                SecureField("Password", text: $settings.proxyPassword, prompt: Text("Optional"))
            } header: {
                Text("Proxy")
            } footer: {
                if settings.proxyIsLocal {
                    Text("Proxies on this Mac or your network aren't allowed: pages could reach your network through them.")
                        .foregroundStyle(.orange)
                } else {
                    Text("The password is kept in your keychain.")
                }
            }
        case .vpn:
            Section {
                if settings.wireGuardNames.isEmpty {
                    LabeledContent("Server", value: "None")
                    LabeledContent("Endpoint", value: "—")
                    LabeledContent("DNS", value: "—")
                    LabeledContent("No configs imported") {
                        Button("Import…") { importing = true }
                    }
                } else {
                    Picker("Server", selection: $settings.wireGuardServer) {
                        ForEach(settings.wireGuardNames, id: \.self) { Text($0).tag($0) }
                    }
                    let config = settings.selectedWireGuard
                    LabeledContent("Endpoint", value: config.map { "\($0.endpointHost):\(String($0.endpointPort))" } ?? "—")
                    LabeledContent("DNS", value: config.map { $0.dns.isEmpty ? "1.1.1.1" : $0.dns.joined(separator: ", ") } ?? "—")
                    LabeledContent(settings.wireGuardNames.count == 1 ? "1 config" : "\(settings.wireGuardNames.count) configs") {
                        HStack {
                            Button("Remove All") { settings.removeWireGuardConfigs() }
                            Button("Import…") { importing = true }
                        }
                    }
                }
            } header: {
                Text("WireGuard")
            } footer: {
                if let importMessage {
                    Text(importMessage).foregroundStyle(.orange).lineLimit(2)
                } else {
                    Text("Import the .conf files, or the .zip, from Mullvad, Proton VPN, IVPN or others.")
                }
            }
        }
    }
}

private struct VMSettings: View {
    let controller: SessionController
    let status: VMStatus

    var body: some View {
        Form {
            Section {
                LabeledContent("Container runtime", value: status.runtimeSummary)
                LabeledContent("VM image", value: status.summary)
                LabeledContent("Rebuild") {
                    Button(status.image == .missing ? "Build Now" : "Rebuild Now") { controller.rebuildImage() }
                        .disabled(isSettingUp || status.image == .noContainerTool)
                }
            } footer: {
                Text("Rebuilding takes about 3 minutes and picks up the latest WebKit security fixes. Progress shows in the notch.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onAppear { status.refresh() }
    }

    private var isSettingUp: Bool {
        if case .settingUp = controller.state { true } else { false }
    }
}
