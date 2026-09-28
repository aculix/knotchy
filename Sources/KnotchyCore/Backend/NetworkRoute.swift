import Foundation

/// Proxy and VPN routes fail closed: the VM's firewall lets nothing else out.
public enum NetworkRoute: Equatable, Sendable {
    case direct
    case proxy(ProxySettings)
    case wireGuard(WireGuardConfig)
    /// Sessions fail to start rather than quietly browsing directly.
    case unusable(reason: String)
}

public struct ProxySettings: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case http
        case socks5
    }

    public var kind: Kind
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(kind: Kind, host: String, port: Int, username: String = "", password: String = "") {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    public func url(address: String) -> String {
        var userinfo = ""
        if !username.isEmpty {
            userinfo = Self.encode(username) + (password.isEmpty ? "" : ":" + Self.encode(password)) + "@"
        }
        return "\(kind.rawValue)://\(userinfo)\(address):\(port)"
    }

    /// Must match the VM firewall's list.
    static let localRanges = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
                              "172.16.0.0/12", "192.168.0.0/16", "198.18.0.0/15"]

    /// A local proxy is refused: pages could reach the Mac and its network through it.
    public static func isLocal(_ address: String, hostNetworks: [String]) -> Bool {
        guard let ip = ipv4Value(address) else { return true }
        return (localRanges + hostNetworks).contains { cidr in
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let network = ipv4Value(String(parts[0])), let bits = Int(parts[1]), (0...32).contains(bits)
            else { return false }
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
            return ip & mask == network & mask
        }
    }

    static func ipv4Value(_ text: String) -> UInt32? {
        guard WireGuardConfig.isIPv4(text) else { return nil }
        return text.split(separator: ".").reduce(UInt32(0)) { $0 << 8 | UInt32($1)! }
    }

    static func encode(_ text: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

/// IPv4 only (the VM has IPv6 off). All traffic uses the tunnel, whatever AllowedIPs says.
public struct WireGuardConfig: Equatable, Sendable {
    public var privateKey: String
    public var addresses: [String]
    /// Empty means 1.1.1.1 through the tunnel.
    public var dns: [String]
    public var mtu: Int?
    public var peerPublicKey: String
    public var presharedKey: String?
    public var endpointHost: String
    public var endpointPort: Int
    public var persistentKeepalive: Int?
    public var name: String?

    public enum ParseError: Error, Equatable, Sendable {
        case missing(String)
        case invalid(String)
        case multiplePeers
    }

    public static func parse(_ text: String) throws(ParseError) -> WireGuardConfig {
        var section = ""
        var interface: [String: String] = [:]
        var peers: [[String: String]] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                section = line.lowercased()
                if section == "[peer]" { peers.append([:]) }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { throw .invalid(line) }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch section {
            case "[interface]":
                interface[key] = interface[key].map { $0 + "," + value } ?? value
            case "[peer]":
                peers[peers.count - 1][key] = value
            default:
                throw .invalid(line)
            }
        }
        guard peers.count <= 1 else { throw .multiplePeers }
        guard let peer = peers.first else { throw .missing("[Peer]") }

        guard let privateKey = interface["privatekey"] else { throw .missing("PrivateKey") }
        guard isKey(privateKey) else { throw .invalid("PrivateKey") }
        guard let publicKey = peer["publickey"] else { throw .missing("PublicKey") }
        guard isKey(publicKey) else { throw .invalid("PublicKey") }
        let presharedKey = peer["presharedkey"]
        if let presharedKey, !isKey(presharedKey) { throw .invalid("PresharedKey") }

        let addresses = list(interface["address"]).compactMap(ipv4CIDR)
        guard !addresses.isEmpty else { throw .missing("an IPv4 Address") }
        let dns = list(interface["dns"]).filter(isIPv4)
        let mtu = try interface["mtu"].map { (text: String) throws(ParseError) -> Int in
            guard let mtu = Int(text), (576...9000).contains(mtu) else { throw .invalid("MTU") }
            return mtu
        }
        let keepalive = try peer["persistentkeepalive"].flatMap { (text: String) throws(ParseError) -> Int? in
            if text.lowercased() == "off" { return nil }
            guard let seconds = Int(text), (0...65535).contains(seconds) else { throw .invalid("PersistentKeepalive") }
            return seconds == 0 ? nil : seconds
        }

        guard let endpoint = peer["endpoint"] else { throw .missing("Endpoint") }
        guard !endpoint.hasPrefix("["), let colon = endpoint.lastIndex(of: ":"),
              let port = Int(endpoint[endpoint.index(after: colon)...]), (1...65535).contains(port)
        else { throw .invalid("Endpoint (an IPv4 address or host name, and a port)") }
        let host = String(endpoint[..<colon])
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
            throw .invalid("Endpoint")
        }

        return WireGuardConfig(privateKey: privateKey, addresses: addresses, dns: dns, mtu: mtu,
                               peerPublicKey: publicKey, presharedKey: presharedKey,
                               endpointHost: host, endpointPort: port, persistentKeepalive: keepalive)
    }

    public func setconf(endpointAddress address: String) -> String {
        var lines = ["[Interface]", "PrivateKey = \(privateKey)", "", "[Peer]", "PublicKey = \(peerPublicKey)"]
        if let presharedKey { lines.append("PresharedKey = \(presharedKey)") }
        lines.append("Endpoint = \(address):\(endpointPort)")
        lines.append("AllowedIPs = 0.0.0.0/0")
        lines.append("PersistentKeepalive = \(persistentKeepalive ?? 25)")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Validation

    /// Curve25519: 32 bytes in base64.
    static func isKey(_ text: String) -> Bool {
        text.count == 44 && Data(base64Encoded: text)?.count == 32
    }

    static func list(_ text: String?) -> [String] {
        (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber)
                && Int(part).map { $0 <= 255 } == true
        }
    }

    static func ipv4CIDR(_ text: String) -> String? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, isIPv4(String(parts[0])) else { return nil }
        guard parts.count == 2 else { return text + "/32" }
        guard let prefix = Int(parts[1]), (0...32).contains(prefix), parts[1].allSatisfy(\.isNumber) else { return nil }
        return text
    }
}

extension NetworkRoute {
    public var label: String? {
        switch self {
        case .direct, .unusable: nil
        case .proxy(let proxy): proxy.kind == .socks5 ? "SOCKS5 proxy" : "HTTP proxy"
        case .wireGuard(let config): config.name ?? "VPN"
        }
    }
}

extension WireGuardConfig.ParseError {
    /// Finishes "The WireGuard config …".
    public var message: String {
        switch self {
        case .missing(let what): "has no \(what)"
        case .invalid(let what): "has an invalid \(what)"
        case .multiplePeers: "has more than one peer; Knotchy needs one server per config"
        }
    }
}

public struct RouteLaunch: Equatable, Sendable {
    /// Always includes KNOTCHY_ROUTE, so a VM missing its proxy or VPN settings stops.
    public var environment: [String]
    /// Never passed with `-e`: `container` saves the environment to disk and shows it in `inspect`.
    public var secrets: [String]
}

extension NetworkRoute {
    public func launch(resolve: (String) throws -> String, hostNetworks: [String] = [],
                       allowLocalProxy: Bool = false) throws -> RouteLaunch {
        switch self {
        case .direct:
            return RouteLaunch(environment: ["KNOTCHY_ROUTE=direct"], secrets: [])
        case .unusable(let reason):
            throw VMBackendError.failed(reason)
        case .proxy(let proxy):
            let address = try resolve(proxy.host)
            if !allowLocalProxy, ProxySettings.isLocal(address, hostNetworks: hostNetworks) {
                let which = proxy.host == address ? address : "\(proxy.host) is \(address)"
                throw VMBackendError.failed(
                    "Knotchy won't use a proxy on this Mac or your local network (\(which)): pages could reach your network through it.")
            }
            return RouteLaunch(environment: ["KNOTCHY_ROUTE=proxy", "KNOTCHY_PROXY_ADDR=\(address):\(proxy.port)"],
                               secrets: ["KNOTCHY_PROXY_URL=\(proxy.url(address: address))"])
        case .wireGuard(let config):
            let address = try resolve(config.endpointHost)
            return RouteLaunch(
                environment: [
                    "KNOTCHY_ROUTE=wireguard",
                    "KNOTCHY_WG_ENDPOINT=\(address):\(config.endpointPort)",
                    "KNOTCHY_WG_ADDRESS=\(config.addresses.joined(separator: " "))",
                    "KNOTCHY_WG_DNS=\(config.dns.joined(separator: " "))",
                    "KNOTCHY_WG_MTU=\(config.mtu ?? 1420)",
                ],
                secrets: ["KNOTCHY_WG_SETCONF=\(Data(config.setconf(endpointAddress: address).utf8).base64EncodedString())"]
            )
        }
    }
}
