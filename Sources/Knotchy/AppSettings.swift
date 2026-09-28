import AppKit
import Carbon.HIToolbox
import KnotchyCore
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppSettings {
    static let autoDestroyChoices = [1, 2, 5, 10, 15, 30]

    private let defaults = UserDefaults.standard
    @ObservationIgnored var onChange: () -> Void = {}

    var autoDestroyMinutes: Int {
        didSet { save(autoDestroyMinutes, "autoDestroyMinutes") }
    }

    var opensLarge: Bool {
        didSet { save(opensLarge, "opensLarge") }
    }

    var copiedLinkShortcut: Bool {
        didSet { save(copiedLinkShortcut, "copiedLinkShortcut") }
    }

    // MARK: Network

    enum NetworkMode: String, CaseIterable {
        case direct, proxy, vpn
    }

    var networkMode: NetworkMode {
        didSet { save(networkMode.rawValue, "networkMode") }
    }

    var proxyKind: ProxySettings.Kind {
        didSet { save(proxyKind.rawValue, "proxyKind") }
    }

    var proxyHost: String {
        didSet { save(proxyHost, "proxyHost") }
    }

    var proxyPort: Int {
        didSet { save(proxyPort, "proxyPort") }
    }

    var proxyUsername: String {
        didSet { save(proxyUsername, "proxyUsername") }
    }

    // Debounced: after an app update, every keychain write can raise a keychain prompt.
    var proxyPassword: String {
        didSet {
            passwordSave?.cancel()
            let password = proxyPassword
            passwordSave = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                Keychain.write(password, for: "proxy-password")
                self.defaults.set(!password.isEmpty, forKey: "proxyHasPassword")
            }
            onChange()
        }
    }
    @ObservationIgnored private var passwordSave: Task<Void, Never>?

    // In the keychain, not UserDefaults: WireGuard configs hold private keys.
    private(set) var wireGuardConfigs: [String: String] {
        didSet {
            let json = (try? JSONEncoder().encode(wireGuardConfigs)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Keychain.write(wireGuardConfigs.isEmpty ? "" : json, for: "wireguard-configs")
            onChange()
        }
    }

    var wireGuardServer: String {
        didSet { save(wireGuardServer, "wireGuardServer") }
    }

    var selectedWireGuard: WireGuardConfig? {
        wireGuardConfigs[wireGuardServer].flatMap { try? WireGuardConfig.parse($0) }
    }

    var wireGuardNames: [String] {
        wireGuardConfigs.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // An unusable proxy or VPN must fail the start, never fall back to a direct connection.
    var route: NetworkRoute {
        switch networkMode {
        case .direct:
            return .direct
        case .proxy:
            let host = proxyHost.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, (1...65535).contains(proxyPort) else {
                return .unusable(reason: "The proxy isn't set up. Add its server and port in Settings → Network, or switch to Direct.")
            }
            return .proxy(ProxySettings(kind: proxyKind, host: host, port: proxyPort,
                                        username: proxyUsername, password: proxyPassword))
        case .vpn:
            guard let text = wireGuardConfigs[wireGuardServer] else {
                return .unusable(reason: "No VPN server is chosen. Import a WireGuard config in Settings → Network, or switch to Direct.")
            }
            do {
                var config = try WireGuardConfig.parse(text)
                config.name = wireGuardServer
                return .wireGuard(config)
            } catch {
                return .unusable(reason: "The WireGuard config “\(wireGuardServer)” \(error.message).")
            }
        }
    }

    /// A hint for Settings only; sessions enforce `ProxySettings.isLocal` on the resolved address.
    var proxyIsLocal: Bool {
        let host = proxyHost.trimmingCharacters(in: .whitespaces).lowercased()
        if host == "localhost" || [".local", ".lan", ".home", ".internal"].contains(where: host.hasSuffix) { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        let (a, b) = (octets[0], octets[1])
        return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
    }

    func importWireGuard(from urls: [URL]) async -> String? {
        var found: [(String, String)] = []
        var problems: [String] = []
        for url in urls {
            let files: [(String, String)]
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if url.pathExtension.lowercased() == "zip" {
                files = await Task.detached { Self.confFiles(inZip: url) }.value
                if files.isEmpty { problems.append("\(url.lastPathComponent) has no .conf files") }
            } else if size <= 64 * 1024, let text = try? String(contentsOf: url, encoding: .utf8) {
                files = [(url.deletingPathExtension().lastPathComponent, text)]
            } else {
                problems.append("couldn't read \(url.lastPathComponent)")
                continue
            }
            for (name, text) in files {
                do {
                    _ = try WireGuardConfig.parse(text)
                    found.append((name, text))
                } catch {
                    problems.append("“\(name)” \(error.message)")
                }
            }
        }
        guard !found.isEmpty else { return problems.first.map { "Nothing imported: \($0)." } ?? "Nothing imported." }
        var configs = wireGuardConfigs
        for (name, text) in found { configs[name] = text }
        wireGuardConfigs = configs
        wireGuardServer = found.map(\.0).sorted { $0.localizedStandardCompare($1) == .orderedAscending }[0]
        networkMode = .vpn
        return problems.isEmpty ? nil : "Imported \(found.count); skipped: \(problems.joined(separator: "; "))."
    }

    func removeWireGuardConfigs() {
        wireGuardConfigs = [:]
        wireGuardServer = ""
    }

    private nonisolated static func confFiles(inZip url: URL) -> [(String, String)] {
        // Output past `limit` fails the read, so a zip bomb can't exhaust memory.
        func unzip(_ arguments: [String], limit: Int) -> Data? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let pid = process.processIdentifier
            let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
            defer { watchdog.cancel() }
            var data = Data()
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 16 * 1024), !chunk.isEmpty {
                data.append(chunk)
                if data.count > limit {
                    process.terminate()
                    process.waitUntilExit()
                    return nil
                }
            }
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }
        guard let listing = unzip(["-Z1", url.path], limit: 1024 * 1024).flatMap({ String(data: $0, encoding: .utf8) })
        else { return [] }
        let entries = listing.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.lowercased().hasSuffix(".conf") && !$0.hasPrefix("__MACOSX") }
            .prefix(500)
        return entries.compactMap { entry in
            guard let data = unzip(["-p", url.path, entry], limit: 64 * 1024),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return (URL(fileURLWithPath: entry).deletingPathExtension().lastPathComponent, text)
        }
    }

    init() {
        defaults.register(defaults: ["autoDestroyMinutes": 5, "opensLarge": false, "copiedLinkShortcut": true,
                                     "networkMode": "direct", "proxyKind": "http", "proxyPort": 8080])
        autoDestroyMinutes = defaults.integer(forKey: "autoDestroyMinutes")
        opensLarge = defaults.bool(forKey: "opensLarge")
        copiedLinkShortcut = defaults.bool(forKey: "copiedLinkShortcut")
        networkMode = NetworkMode(rawValue: defaults.string(forKey: "networkMode") ?? "") ?? .direct
        proxyKind = ProxySettings.Kind(rawValue: defaults.string(forKey: "proxyKind") ?? "") ?? .http
        proxyHost = defaults.string(forKey: "proxyHost") ?? ""
        proxyPort = defaults.integer(forKey: "proxyPort")
        let username = defaults.string(forKey: "proxyUsername") ?? ""
        let server = defaults.string(forKey: "wireGuardServer") ?? ""
        proxyUsername = username
        wireGuardServer = server
        // Skip the keychain (and its possible prompt) unless a secret was saved.
        proxyPassword = defaults.bool(forKey: "proxyHasPassword") || !username.isEmpty
            ? Keychain.read("proxy-password") ?? "" : ""
        wireGuardConfigs = server.isEmpty ? [:] :
            (Keychain.read("wireguard-configs")?.data(using: .utf8))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange()
    }

    func apply(to controller: SessionController) {
        controller.idleDestroyDelay = .seconds(autoDestroyMinutes * 60)
        controller.opensExpanded = opensLarge
    }
}

@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// Carbon, because its hot keys need no Accessibility permission.
@MainActor
final class GlobalHotKey {
    static let openCopiedLinkLabel = "⌃⌥⌘L"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    static func openCopiedLink(_ action: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey | cmdKey), action: action)
    }

    private init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4B4E_4F54), id: 1)
        // Exclusive, so a shortcut another app owns fails instead of silently sharing.
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(),
                                  OptionBits(kEventHotKeyExclusive), &hotKey) == noErr else {
            RemoveEventHandler(handler)
            handler = nil   // deinit also runs after a failed init; don't remove it twice.
            return nil
        }
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
