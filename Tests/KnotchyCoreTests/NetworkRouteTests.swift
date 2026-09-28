import Foundation
import Testing
@testable import KnotchyCore

@Suite struct NetworkRouteTests {
    static let key = Data(repeating: 7, count: 32).base64EncodedString()
    static let otherKey = Data(repeating: 9, count: 32).base64EncodedString()

    static let mullvadStyle = """
    [Interface]
    # Device: Quick Fox
    PrivateKey = \(key)
    Address = 10.64.12.34/32,fc00:bbbb:bbbb:bb01::1:c21/128
    DNS = 10.64.0.1

    [Peer]
    PublicKey = \(otherKey)
    AllowedIPs = 0.0.0.0/0,::0/0
    Endpoint = se-got-wg-001.relays.mullvad.net:51820
    """

    @Test func parsesAProviderConfig() throws {
        let config = try WireGuardConfig.parse(Self.mullvadStyle)
        #expect(config.privateKey == Self.key)
        #expect(config.addresses == ["10.64.12.34/32"])
        #expect(config.dns == ["10.64.0.1"])
        #expect(config.peerPublicKey == Self.otherKey)
        #expect(config.endpointHost == "se-got-wg-001.relays.mullvad.net")
        #expect(config.endpointPort == 51820)
        #expect(config.mtu == nil)
        #expect(config.persistentKeepalive == nil)
    }

    @Test func keysAreCaseInsensitiveAndRepeatsJoin() throws {
        let text = """
        [interface]
        privatekey=\(Self.key)
        Address = 10.2.0.2
        Address = 10.2.0.3/32
        DNS = 10.2.0.1, 1.1.1.1, example.search.domain
        MTU = 1380
        [PEER]
        publickey = \(Self.otherKey)
        PresharedKey = \(Self.key)
        endpoint = 203.0.113.9:443
        PersistentKeepalive = 15
        """
        let config = try WireGuardConfig.parse(text)
        #expect(config.addresses == ["10.2.0.2/32", "10.2.0.3/32"])
        #expect(config.dns == ["10.2.0.1", "1.1.1.1"])
        #expect(config.mtu == 1380)
        #expect(config.presharedKey == Self.key)
        #expect(config.persistentKeepalive == 15)
    }

    @Test func rejectsWhatTheVMCannotUse() {
        func parse(_ text: String) -> WireGuardConfig.ParseError? {
            do { _ = try WireGuardConfig.parse(text); return nil } catch { return error }
        }
        let peer = "[Peer]\nPublicKey = \(Self.otherKey)\nEndpoint = 1.2.3.4:51820\n"
        #expect(parse("[Interface]\nAddress = 10.0.0.2/32\n" + peer) == .missing("PrivateKey"))
        #expect(parse("[Interface]\nPrivateKey = nope\nAddress = 10.0.0.2/32\n" + peer) == .invalid("PrivateKey"))
        #expect(parse("[Interface]\nPrivateKey = \(Self.key)\nAddress = fd00::2/128\n" + peer) == .missing("an IPv4 Address"))
        #expect(parse("[Interface]\nPrivateKey = \(Self.key)\nAddress = 10.0.0.2/32\n") == .missing("[Peer]"))
        #expect(parse("[Interface]\nPrivateKey = \(Self.key)\nAddress = 10.0.0.2/32\n" + peer + peer) == .multiplePeers)
        let v6Endpoint = "[Peer]\nPublicKey = \(Self.otherKey)\nEndpoint = [2001:db8::1]:51820\n"
        #expect(parse("[Interface]\nPrivateKey = \(Self.key)\nAddress = 10.0.0.2/32\n" + v6Endpoint) != nil)
        let shellEndpoint = "[Peer]\nPublicKey = \(Self.otherKey)\nEndpoint = $(reboot):51820\n"
        #expect(parse("[Interface]\nPrivateKey = \(Self.key)\nAddress = 10.0.0.2/32\n" + shellEndpoint) == .invalid("Endpoint"))
        #expect(parse("[Interface]\nPrivateKey = \(Self.key)\nAddress = 10.0.0.2/32\nPostUp = rm -rf /\n" + peer) == nil)
    }

    @Test func setconfForcesAFullTunnelAndAKeepalive() throws {
        let config = try WireGuardConfig.parse(Self.mullvadStyle)
        let setconf = config.setconf(endpointAddress: "185.213.154.66")
        #expect(setconf == """
        [Interface]
        PrivateKey = \(Self.key)

        [Peer]
        PublicKey = \(Self.otherKey)
        Endpoint = 185.213.154.66:51820
        AllowedIPs = 0.0.0.0/0
        PersistentKeepalive = 25

        """)
    }

    @Test func proxyURLsEncodeCredentialsAndUseTheAddress() {
        let proxy = ProxySettings(kind: .socks5, host: "proxy.example", port: 1080, username: "me@home", password: "p:w/d@!")
        #expect(proxy.url(address: "203.0.113.7") == "socks5://me%40home:p%3Aw%2Fd%40%21@203.0.113.7:1080")
        #expect(ProxySettings(kind: .http, host: "h", port: 8080).url(address: "10.0.0.5") == "http://10.0.0.5:8080")
        #expect(ProxySettings(kind: .http, host: "h", port: 8080, username: "u").url(address: "10.0.0.5") == "http://u@10.0.0.5:8080")
    }

    @Test func launchKeepsSecretsOutOfTheEnvironment() throws {
        var asked: [String] = []
        let resolve = { (host: String) -> String in asked.append(host); return "198.51.100.4" }
        #expect(try NetworkRoute.direct.launch(resolve: resolve) == RouteLaunch(environment: ["KNOTCHY_ROUTE=direct"], secrets: []))

        let proxy = NetworkRoute.proxy(ProxySettings(kind: .http, host: "proxy.corp", port: 3128, username: "u", password: "p"))
        #expect(try proxy.launch(resolve: resolve) == RouteLaunch(
            environment: ["KNOTCHY_ROUTE=proxy", "KNOTCHY_PROXY_ADDR=198.51.100.4:3128"],
            secrets: ["KNOTCHY_PROXY_URL=http://u:p@198.51.100.4:3128"]
        ))

        let wireGuard = try NetworkRoute.wireGuard(WireGuardConfig.parse(Self.mullvadStyle)).launch(resolve: resolve)
        #expect(asked == ["proxy.corp", "se-got-wg-001.relays.mullvad.net"])
        #expect(wireGuard.environment == [
            "KNOTCHY_ROUTE=wireguard", "KNOTCHY_WG_ENDPOINT=198.51.100.4:51820", "KNOTCHY_WG_ADDRESS=10.64.12.34/32",
            "KNOTCHY_WG_DNS=10.64.0.1", "KNOTCHY_WG_MTU=1420",
        ])
        #expect(wireGuard.environment.allSatisfy { !$0.contains(Self.key) })
        #expect(wireGuard.secrets.count == 1 && wireGuard.secrets[0].hasPrefix("KNOTCHY_WG_SETCONF="))
        #expect((wireGuard.environment + wireGuard.secrets).allSatisfy { !$0.contains("\n") })

        #expect(throws: VMBackendError.failed("no")) { try NetworkRoute.unusable(reason: "no").launch(resolve: resolve) }
    }

    @Test func routeLabels() throws {
        #expect(NetworkRoute.direct.label == nil)
        #expect(NetworkRoute.proxy(ProxySettings(kind: .socks5, host: "h", port: 1)).label == "SOCKS5 proxy")
        var config = try WireGuardConfig.parse(Self.mullvadStyle)
        #expect(NetworkRoute.wireGuard(config).label == "VPN")
        config.name = "sg-sin-wg-001"
        #expect(NetworkRoute.wireGuard(config).label == "sg-sin-wg-001")
    }

    @Test func proxiesOnTheMacOrItsNetworkAreRefused() throws {
        for local in ["10.1.2.3", "127.0.0.1", "169.254.169.254", "172.20.0.1", "192.168.64.1", "100.100.1.1", "0.0.0.0"] {
            #expect(ProxySettings.isLocal(local, hostNetworks: []), "\(local)")
        }
        #expect(ProxySettings.isLocal("203.0.113.9", hostNetworks: ["203.0.113.0/24"]))
        #expect(!ProxySettings.isLocal("203.0.113.9", hostNetworks: ["198.51.100.0/24"]))
        #expect(!ProxySettings.isLocal("8.8.8.8", hostNetworks: []))
        #expect(!ProxySettings.isLocal("172.32.0.1", hostNetworks: []))

        let proxy = NetworkRoute.proxy(ProxySettings(kind: .http, host: "proxy.lan", port: 3128))
        #expect(throws: VMBackendError.self) { try proxy.launch(resolve: { _ in "192.168.1.10" }) }
        #expect(try proxy.launch(resolve: { _ in "192.168.1.10" }, allowLocalProxy: true).environment.count == 2)
        // A local WireGuard server is fine: only wireguard-go can reach it.
        let wireGuard = NetworkRoute.wireGuard(try WireGuardConfig.parse(Self.mullvadStyle))
        #expect(try wireGuard.launch(resolve: { _ in "192.168.1.1" }).environment.contains("KNOTCHY_WG_ENDPOINT=192.168.1.1:51820"))
    }
}
