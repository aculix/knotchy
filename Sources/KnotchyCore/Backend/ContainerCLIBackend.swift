import Foundation
import Synchronization

public final class ContainerCLIBackend: VMBackend {
    public static let image = "local/knotchy-vm:latest"
    /// The image a rebuild replaces, named so it can be deleted afterwards.
    static let previousImage = "local/knotchy-vm:previous"
    public static let staleAfterDays = 14

    private let cli: CLIRunner
    private let vmSources: URL?
    private let runDirectory: URL
    private let startsInFlight = Mutex(0)
    private let route = Mutex(NetworkRoute.direct)
    private let startedRoute = Mutex(NetworkRoute.direct)

    public var lastStartedRoute: NetworkRoute { startedRoute.withLock { $0 } }

    public func setNetworkRoute(_ newRoute: NetworkRoute) {
        route.withLock { $0 = newRoute }
    }

    /// Test-only (knotchyctl --allow-local-proxy); the app never sets it.
    private let localProxyAllowed = Mutex(false)

    public func allowLocalProxy() {
        localProxyAllowed.withLock { $0 = true }
    }

    public init(vmSources: URL?, cli: CLIRunner = CLIRunner()) {
        self.vmSources = vmSources
        self.cli = cli
        runDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("knotchy", isDirectory: true)
    }

    // MARK: Preflight

    public func preflight() async -> PreflightResult {
        guard cli.executable != nil else { return .issue(.cliMissing) }
        if case .outdated(let found) = await runtimeStatus() { return .issue(.cliOutdated(found: found)) }
        guard let status = try? await cli.run(["system", "status"], timeout: 15), status.status == 0,
              field("status", in: status.text) == "running"
        else { return .issue(.serviceStopped) }
        let appRoot = field("paths.appRoot", in: status.text)
            ?? NSHomeDirectory() + "/Library/Application Support/com.apple.container/"
        let kernel = URL(fileURLWithPath: appRoot).appendingPathComponent("kernels/default.kernel-arm64")
        guard FileManager.default.fileExists(atPath: kernel.path) else { return .issue(.kernelMissing) }

        guard let inspect = try? await cli.run(["image", "inspect", Self.image], timeout: 15), inspect.status == 0
        else { return .issue(.imageMissing) }
        let labels = Self.labels(in: inspect.text)
        let found = labels["aculix.knotchy.protocol"].flatMap(Int.init) ?? 0
        guard found == WireProtocol.version else {
            return .issue(.imageOutdated(found: found, need: WireProtocol.version))
        }
        prepareRunDirectory()
        return .ready(appRoot: appRoot, staleImage: Self.staleness(built: labels["aculix.knotchy.built"]))
    }

    /// Resolved on the Mac: a proxy route gives the VM no DNS, and a VPN's DNS needs the tunnel up.
    static func resolveIPv4(_ host: String) throws -> String {
        var address = host
        if !WireGuardConfig.isIPv4(host) {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result, let sockaddr = first.pointee.ai_addr else {
                throw VMBackendError.failed("Couldn't find the server “\(host)”. Check Settings → Network.")
            }
            defer { freeaddrinfo(result) }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &inAddr, &buffer, socklen_t(buffer.count)) != nil else {
                throw VMBackendError.failed("Couldn't find the server “\(host)”.")
            }
            address = String(cString: buffer)
        }
        if address.hasPrefix("127.") || address == "0.0.0.0" {
            throw VMBackendError.failed("The VM can't reach this Mac's localhost (“\(host)”). A proxy on this Mac must listen on the Mac's network address instead.")
        }
        return address
    }

    public func imageStatus() async -> ImageStatus {
        guard cli.executable != nil else { return .noContainerTool }
        guard let inspect = try? await cli.run(["image", "inspect", Self.image], timeout: 15), inspect.status == 0
        else { return .missing }
        let built = Self.labels(in: inspect.text)["aculix.knotchy.built"].flatMap { ISO8601DateFormatter().date(from: $0) }
        return .built(built)
    }

    public enum ImageStatus: Equatable, Sendable {
        case noContainerTool
        case missing
        case built(Date?)
    }

    public func runtimeStatus() async -> RuntimeStatus {
        guard cli.executable != nil else { return .missing }
        let output = try? await cli.run(["--version"], timeout: 10)
        return ContainerRuntime.status(versionOutput: output?.text ?? "")
    }

    public func stopService() async throws {
        let result = try await cli.run(["system", "stop"], timeout: 60)
        guard result.status == 0 else { throw VMBackendError.failed("Couldn't stop the container service: \(result.lastLine)") }
    }

    private func field(_ name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, parts[0] == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func labels(in json: String) -> [String: String] {
        var found: [String: String] = [:]
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                for (key, child) in dict {
                    if key.hasPrefix("aculix.knotchy."), let text = child as? String { found[key] = text }
                    walk(child)
                }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) { walk(object) }
        return found
    }

    static func staleness(built: String?, now: Date = Date()) -> StaleImage? {
        let formatter = ISO8601DateFormatter()
        guard let built, let date = formatter.date(from: built) else { return StaleImage(builtDaysAgo: nil) }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        return days > staleAfterDays ? StaleImage(builtDaysAgo: days) : nil
    }

    private func prepareRunDirectory() {
        let fm = FileManager.default
        let path = runDirectory.path
        var isDirectory: ObjCBool = false
        let attributes = try? fm.attributesOfItem(atPath: path)
        let isSymlink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
        let owner = (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        if isSymlink || !fm.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue
            || owner != getuid() || mode != 0o700 {
            try? fm.removeItem(atPath: path)
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        // Secrets left by a crash; a VM's init deletes its own within a second of booting.
        let stale = Date().addingTimeInterval(-120)
        for name in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where name.hasSuffix(".secrets") || name.hasSuffix(".env") {
            let item = runDirectory.appendingPathComponent(name)
            if let modified = (try? fm.attributesOfItem(atPath: item.path))?[.modificationDate] as? Date, modified < stale {
                try? fm.removeItem(at: item)
            }
        }
    }

    // MARK: Start and destroy

    public func start(id: String, url: URL, renderSize: PixelSize, blockCIDRs: [String]) async throws -> VMSession {
        startsInFlight.withLock { $0 += 1 }
        defer { startsInFlight.withLock { $0 -= 1 } }
        prepareRunDirectory()
        let socket = runDirectory.appendingPathComponent("\(id).sock").path
        unlink(socket)
        let chosenRoute = route.withLock { $0 }
        let launch = try chosenRoute.launch(resolve: Self.resolveIPv4, hostNetworks: blockCIDRs,
                                            allowLocalProxy: localProxyAllowed.withLock { $0 })
        var args = [
            "run", "-d", "--rm", "--name", id,
            "--cpus", "4", "--memory", "2g", "--shm-size", "512m",
            "--dns", "1.1.1.1",
            "--cap-add", "NET_ADMIN",
            // WebKit's bwrap can't mount procfs over a masked /proc, and init writes /proc/sys.
            "--masked-path", "NONE", "--read-only-path", "NONE",
            "--publish-socket", "\(socket):/tmp/knotchy/knotchy.sock",
            "-e", "KNOTCHY_URL=\(url.absoluteString)",
            "-e", "KNOTCHY_SIZE=\(renderSize)",
            "-e", "KNOTCHY_BLOCK_CIDRS=\(blockCIDRs.joined(separator: " "))",
        ]
        for setting in launch.environment { args += ["-e", setting] }
        if !launch.secrets.isEmpty {
            // Init reads, deletes and unmounts this (needs SYS_ADMIN), then drops all capabilities.
            let share = secretsDirectory(id)
            try? FileManager.default.removeItem(at: share)
            guard (try? FileManager.default.createDirectory(at: share, withIntermediateDirectories: false,
                                                             attributes: [.posixPermissions: 0o700])) != nil,
                  FileManager.default.createFile(atPath: share.appendingPathComponent("route").path,
                                                 contents: Data((launch.secrets.joined(separator: "\n") + "\n").utf8),
                                                 attributes: [.posixPermissions: 0o600])
            else {
                try? FileManager.default.removeItem(at: share)
                throw VMBackendError.failed("Couldn't pass the network settings to the VM.")
            }
            args += ["--cap-add", "SYS_ADMIN", "--mount", "type=bind,source=\(share.path),target=/run/knotchy-secrets"]
        }
        args.append(Self.image)
        let output: CLIRunner.Output
        do {
            output = try await cli.run(args, timeout: 60)
        } catch {
            throw VMBackendError.failed("Starting the VM timed out.")
        }
        guard output.status == 0 else {
            cleanUp(id)
            throw VMBackendError.failed("Couldn't start the VM: \(output.lastLine)")
        }
        startedRoute.withLock { $0 = chosenRoute }
        return VMSession(id: id, socketPath: socket)
    }

    public func destroy(id: String) async throws {
        _ = try? await cli.run(["stop", "-t", "2", id], timeout: 10)
        if await waitUntilGone(id, for: 5) { return cleanUp(id) }
        _ = try? await cli.run(["delete", "--force", id], timeout: 10)
        if await waitUntilGone(id, for: 5) { return cleanUp(id) }
        throw VMBackendError.destroyStuck(id: id)
    }

    public func forceDestroy(id: String) async throws {
        _ = try? await cli.run(["delete", "--force", id], timeout: 10)
        if await waitUntilGone(id, for: 5) { return cleanUp(id) }
        throw VMBackendError.destroyStuck(id: id)
    }

    public func sweepOrphans(keeping: Set<String>) async {
        guard let listed = try? await cli.run(["ls", "-a", "-q"], timeout: 10) else { return }
        for id in Self.ids(in: listed.text) where Self.isSessionID(id) && !keeping.contains(id) {
            _ = try? await cli.run(["delete", "--force", id], timeout: 10)
            cleanUp(id)
        }
    }

    static func isSessionID(_ id: String) -> Bool {
        id.count == 16 && id.hasPrefix("knotchy-") && id.dropFirst(8).allSatisfy(\.isHexDigit)
    }

    static func ids(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func isListed(_ id: String) async -> Bool? {
        guard let listed = try? await cli.run(["ls", "-a", "-q"], timeout: 10), listed.status == 0 else { return nil }
        return Self.ids(in: listed.text).contains(id)
    }

    private func waitUntilGone(_ id: String, for seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if await isListed(id) == false { return true }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return false
    }

    private func cleanUp(_ id: String) {
        unlink(runDirectory.appendingPathComponent("\(id).sock").path)
        try? FileManager.default.removeItem(at: secretsDirectory(id))
    }

    private func secretsDirectory(_ id: String) -> URL {
        runDirectory.appendingPathComponent("\(id).secrets", isDirectory: true)
    }

    // MARK: Setup actions

    /// A first start also pulls the runtime's base filesystem, about 70 MB.
    static let serviceTimeout: TimeInterval = 10 * 60
    /// A first build downloads about 470 MB: the builder, the Debian base and its packages.
    static let buildTimeout: TimeInterval = 60 * 60
    static let kernelFolderPrefix = "knotchy-kernel-"

    public func fix(_ issue: SetupIssue, output: @escaping @Sendable (String) -> Void) async throws {
        switch issue {
        case .serviceStopped:
            // The kernel is its own step: `--enable-kernel-install` downloads 700 MB without showing progress.
            let result = try await step(["system", "start", "--disable-kernel-install"], timeout: Self.serviceTimeout,
                                        output: output, named: "Starting the container service")
            guard result.status == 0 else { throw VMBackendError.failed("Couldn't start the service: \(result.lastLine)") }
        case .kernelMissing:
            try await installKernel(output: output)
        case .imageMissing, .imageOutdated, .imageStale:
            try await buildImage(output: output)
        case .cliMissing, .cliOutdated, .lowDisk:
            throw VMBackendError.failed("There's no automatic fix for this.")
        }
    }

    /// Leaves nothing behind but the new image: not the one it replaced, and not a builder it started.
    private func buildImage(output: @escaping @Sendable (String) -> Void) async throws {
        guard let vmSources else { throw VMBackendError.failed("The VM sources are missing from the app.") }
        let now = Date()
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let args = [
            "build", "--cpus", "4", "--memory", "4g", "--dns", "1.1.1.1", "--pull",
            "--build-arg", "APT_REFRESH=\(day.string(from: now))",
            "--build-arg", "BUILD_DATE=\(ISO8601DateFormatter().string(from: now))",
            "-f", vmSources.appendingPathComponent("Containerfile").path,
            "-t", Self.image, vmSources.path,
        ]
        let builderBefore = (try? await cli.run(["builder", "status", "--format", "json"], timeout: 15))
            .flatMap { Self.builderState(in: $0.text) }
        // The runtime keeps a replaced image's files, about 2 GB, until an image is deleted. Deleting the
        // old one by name frees them, along with anything earlier builds left.
        let named = (try? await cli.run(["image", "tag", Self.image, Self.previousImage], timeout: 30))?.status == 0
        let built: Result<CLIRunner.Output, any Error>
        do {
            built = .success(try await step(args, timeout: Self.buildTimeout, output: output, named: "Building the VM image"))
        } catch {
            built = .failure(error)
        }
        // After a failed build the old image keeps its usual name too, so this deletes nothing it needs.
        if named { _ = try? await cli.run(["image", "delete", Self.previousImage], timeout: 5 * 60) }
        // The builder VM keeps about 3 GB of memory and a 4 GB cache. One the user had running stays as it was.
        switch builderBefore {
        case .absent?: _ = try? await cli.run(["builder", "delete", "--force"], timeout: 60)
        case .stopped?: _ = try? await cli.run(["builder", "stop"], timeout: 60)
        case .running?, nil: break
        }
        let result = try built.get()
        guard result.status == 0 else { throw VMBackendError.failed("The image build failed: \(result.lastLine)") }
    }

    enum BuilderState: Equatable {
        case absent
        case stopped
        case running
    }

    /// From `builder status --format json`: `[]` when there's no builder.
    static func builderState(in json: String) -> BuilderState? {
        struct Entry: Decodable {
            struct Status: Decodable {
                let state: String?
            }
            let status: Status?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: Data(json.utf8)) else { return nil }
        guard let first = entries.first else { return .absent }
        return first.status?.state == "running" ? .running : .stopped
    }

    /// A timeout reads as a sentence, not as the command that ran.
    private func step(_ args: [String], timeout: TimeInterval, output: @escaping @Sendable (String) -> Void,
                      named name: String) async throws -> CLIRunner.Output {
        do {
            return try await cli.run(args, timeout: timeout, line: output)
        } catch CLIRunner.Failure.timedOut {
            throw VMBackendError.failed("\(name) took over \(Int(timeout / 60)) minutes, so Knotchy stopped it. Check your connection and try again.")
        }
    }

    public static func removeKernelDownloads() {
        FileDownload.removeFolders(prefix: kernelFolderPrefix)
    }

    /// `kernel set --recommended` prints nothing while it downloads 700 MB, so Knotchy downloads the archive
    /// itself, with progress, and hands it over. The runtime still checks it against the digest it publishes.
    private func installKernel(output: @escaping @Sendable (String) -> Void) async throws {
        let properties = try? await cli.run(["system", "property", "list", "--format", "json"], timeout: 15)
        guard let kernel = properties.flatMap({ Self.recommendedKernel(in: $0.text) }) else {
            let result = try await step(["system", "kernel", "set", "--recommended", "--force"], timeout: 60 * 60,
                                        output: output, named: "Downloading the Linux kernel")
            guard result.status == 0 else { throw VMBackendError.failed("Couldn't install the Linux kernel: \(result.lastLine)") }
            return
        }
        Self.removeKernelDownloads()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(Self.kernelFolderPrefix + UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                         attributes: [.posixPermissions: 0o700])) != nil
        else { throw VMBackendError.failed("Couldn't make a folder for the Linux kernel download.") }
        defer { try? FileManager.default.removeItem(at: folder) }

        let archive = folder.appendingPathComponent(kernel.url.lastPathComponent)
        output("Downloading the Linux kernel…")
        let throttle = ProgressThrottle()
        do {
            try await FileDownload.fetch(kernel.url, to: archive) { written, expected in
                // One line a percent, so the log keeps what came before the download.
                let step = expected.map { Int(written * 100 / max($0, 1)) } ?? Int(written / 10_000_000)
                if throttle.advance(to: step) { output(Self.kernelProgress(written, of: expected)) }
            }
        } catch {
            throw VMBackendError.failed("Couldn't download the Linux kernel. Check your connection and try again.")
        }
        output("Installing the Linux kernel…")
        let result = try await step(["system", "kernel", "set", "--tar", archive.path, "--binary", kernel.binaryPath,
                                     "--digest", kernel.digest, "--force"],
                                    timeout: 10 * 60, output: output, named: "Installing the Linux kernel")
        guard result.status == 0 else { throw VMBackendError.failed("Couldn't install the Linux kernel: \(result.lastLine)") }
    }

    struct RecommendedKernel: Equatable {
        let url: URL
        let binaryPath: String
        let digest: String
    }

    /// From `system property list --format json`; nil when the runtime doesn't say.
    static func recommendedKernel(in json: String) -> RecommendedKernel? {
        struct Properties: Decodable {
            struct Kernel: Decodable {
                let url: String?
                let binaryPath: String?
                let digest: String?
            }
            let kernel: Kernel?
        }
        guard let kernel = (try? JSONDecoder().decode(Properties.self, from: Data(json.utf8)))?.kernel,
              let url = kernel.url.flatMap(URL.init(string:)),
              let binaryPath = kernel.binaryPath, !binaryPath.isEmpty,
              let digest = kernel.digest, digest.hasPrefix("sha256:")
        else { return nil }
        return RecommendedKernel(url: url, binaryPath: binaryPath, digest: digest)
    }

    static func kernelProgress(_ written: Int64, of expected: Int64?) -> String {
        func megabytes(_ bytes: Int64) -> Int { Int((Double(bytes) / 1_000_000).rounded()) }
        guard let expected else { return "Downloading the Linux kernel… \(megabytes(written)) MB" }
        return "Downloading the Linux kernel… \(megabytes(written)) of \(megabytes(expected)) MB"
    }

    // MARK: Quit path

    public func destroyBlocking(ids: [String], deadline: Duration) {
        let end = Date().addingTimeInterval(TimeInterval(deadline.components.seconds))
        // Wait for in-flight starts so a VM created at the last moment is destroyed too.
        while startsInFlight.withLock({ $0 }) > 0, Date() < end { usleep(50_000) }
        for id in ids {
            let left = end.timeIntervalSinceNow
            guard left > 0.5 else { return }
            _ = try? cli.runBlocking(["delete", "--force", id], timeout: min(10, left))
            cleanUp(id)
        }
    }
}

private final class ProgressThrottle: Sendable {
    private let last = Mutex(-1)

    /// True the first time each step is reached.
    func advance(to step: Int) -> Bool {
        last.withLock { last in
            guard step > last else { return false }
            last = step
            return true
        }
    }
}
