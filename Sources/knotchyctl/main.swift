import CoreImage
import Foundation
import ImageIO
import KnotchyCore
import Synchronization
import UniformTypeIdentifiers

// knotchyctl snapshot <url> <out.png> [--after <seconds>] [--click <render x>,<render y>]
//     [--proxy <http|socks5>://[user:pass@]host:port] [--wireguard <file.conf>] [--allow-local-proxy]

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("knotchyctl: \(message)\n".utf8))
    exit(1)
}

func vmSources() -> URL? {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vm")
    return FileManager.default.fileExists(atPath: repo.appendingPathComponent("Containerfile").path) ? repo : nil
}

func writePNG(_ buffer: CVPixelBuffer, to path: String) throws {
    let image = CIImage(cvPixelBuffer: buffer)
    guard let cgImage = CIContext().createCGImage(image, from: image.extent),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

// Thrown rather than fail()ed after the VM starts, so the VM still gets destroyed.
struct SnapshotError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class LatestFrame: Sendable {
    private let frame = Mutex<DecodedFrame?>(nil)
    func set(_ new: DecodedFrame) { frame.withLock { $0 = new } }
    func get() -> DecodedFrame? { frame.withLock { $0 } }
}

func snapshot(url: URL, out: String, after: Double, click: (x: UInt16, y: UInt16)?, route: NetworkRoute) async throws {
    let backend = ContainerCLIBackend(vmSources: vmSources())
    backend.setNetworkRoute(route)
    if arguments.contains("--allow-local-proxy") { backend.allowLocalProxy() }
    // An outdated image would silently ignore the proxy or VPN route.
    guard case .ready = await backend.preflight() else { fail("the VM image isn't ready; build it with scripts/build-vm.sh") }
    let id = "knotchyctl-" + String(format: "%08x", UInt32.random(in: .min ... .max))
    let started = ContinuousClock.now
    let vm = try await backend.start(id: id, url: url, renderSize: SessionController.renderSize,
                                     blockCIDRs: HostNetworks.current())
    do {
        let connection = try await StreamClient(renderSize: SessionController.renderSize).connect(socketPath: vm.socketPath)
        let latest = LatestFrame()
        connection.setFrameHandler { latest.set($0) }
        var ready = false
        for await event in connection.events {
            if event == .contentReady { ready = true; break }
            if case .ended(let reason) = event { throw CocoaError(.featureUnsupported, userInfo: ["reason": "\(reason)"]) }
        }
        guard ready else { throw SnapshotError("the stream ended before content was ready") }
        print("content ready after \(ContinuousClock.now - started)")
        let pages = Task {
            for await event in connection.events {
                if case .pageURL(let page) = event { print("page \(page.absoluteString)") }
            }
        }
        defer { pages.cancel() }
        if let click {
            try await Task.sleep(for: .seconds(1))
            connection.send(.pointerMove(x: click.x, y: click.y, mods: []))
            connection.send(.pointerButton(.left, pressed: true, x: click.x, y: click.y, mods: .leftButton))
            connection.send(.pointerButton(.left, pressed: false, x: click.x, y: click.y, mods: []))
        }
        try await Task.sleep(for: .seconds(after))
        guard let frame = latest.get() else { throw SnapshotError("no frame decoded") }
        try writePNG(frame.pixelBuffer, to: out)
        print("wrote \(out)")
        connection.close()
    } catch {
        try? await backend.destroy(id: id)
        throw error
    }
    try await backend.destroy(id: id)
}

guard arguments.first == "snapshot", arguments.count >= 3, let url = URL(string: arguments[1]) else {
    fail("usage: knotchyctl snapshot <url> <out.png> [--after <seconds>] [--click <x>,<y>] [--proxy <url>] [--wireguard <file>]")
}
var route = NetworkRoute.direct
if let index = arguments.firstIndex(of: "--proxy") {
    guard let proxy = URLComponents(string: arguments[safe: index + 1] ?? ""), let host = proxy.host, let port = proxy.port,
          let kind = ProxySettings.Kind(rawValue: proxy.scheme ?? "")
    else { fail("--proxy needs http://[user:pass@]host:port or socks5://…") }
    route = .proxy(ProxySettings(kind: kind, host: host, port: port,
                                 username: proxy.user ?? "", password: proxy.password ?? ""))
}
if let index = arguments.firstIndex(of: "--wireguard") {
    guard let text = try? String(contentsOfFile: arguments[safe: index + 1] ?? "", encoding: .utf8) else {
        fail("--wireguard needs a readable .conf file")
    }
    do { route = .wireGuard(try WireGuardConfig.parse(text)) } catch { fail("the WireGuard config: \(error)") }
}
let after = arguments.firstIndex(of: "--after").flatMap { Double(arguments[safe: $0 + 1] ?? "") } ?? 3
let click: (x: UInt16, y: UInt16)? = arguments.firstIndex(of: "--click").flatMap { index in
    let parts = (arguments[safe: index + 1] ?? "").split(separator: ",").compactMap { UInt16($0) }
    return parts.count == 2 ? (parts[0], parts[1]) : nil
}
do {
    try await snapshot(url: url, out: arguments[2], after: after, click: click, route: route)
} catch {
    fail("\(error)")
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
