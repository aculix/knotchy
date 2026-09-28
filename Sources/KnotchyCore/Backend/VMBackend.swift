import Foundation

/// The controller serializes all calls except `destroyBlocking`, which the quit path may make
/// from any thread while an async call is still running.
public protocol VMBackend: Sendable {
    func preflight() async -> PreflightResult
    /// Must register as in flight before its first suspension so `destroyBlocking` waits for it.
    func start(id: String, url: URL, renderSize: PixelSize, blockCIDRs: [String]) async throws -> VMSession
    /// Returns only once the VM is confirmed gone; otherwise throws `.destroyStuck`.
    func destroy(id: String) async throws
    func forceDestroy(id: String) async throws
    func sweepOrphans(keeping: Set<String>) async
    func fix(_ issue: SetupIssue, output: @escaping @Sendable (String) -> Void) async throws
    /// Not serialized by the controller: `container --version` doesn't use the service.
    func runtimeStatus() async -> RuntimeStatus
    func stopService() async throws
    /// Blocking. Waits for in-flight starts first so a VM created at the last moment is destroyed too.
    func destroyBlocking(ids: [String], deadline: Duration)
}

public struct VMSession: Equatable, Sendable {
    public let id: String
    public let socketPath: String

    public init(id: String, socketPath: String) {
        self.id = id
        self.socketPath = socketPath
    }
}

public enum SetupIssue: Equatable, Sendable {
    case cliMissing
    case cliOutdated(found: String)
    case serviceStopped
    case kernelMissing
    case imageMissing
    case imageOutdated(found: Int, need: Int)
    case imageStale(builtDaysAgo: Int?)
    case lowDisk(bytesFree: Int64)
}

public enum PreflightResult: Equatable, Sendable {
    case ready(appRoot: String, staleImage: StaleImage?)
    /// Never `.imageStale` (that rides on `.ready`) or `.lowDisk` (the controller checks disk).
    case issue(SetupIssue)
}

public struct StaleImage: Equatable, Sendable {
    public var builtDaysAgo: Int?

    public init(builtDaysAgo: Int?) {
        self.builtDaysAgo = builtDaysAgo
    }
}

public enum VMBackendError: Error, Equatable, Sendable {
    case destroyStuck(id: String)
    /// The message is shown to the user.
    case failed(String)
}

public protocol DiskSpaceChecking: Sendable {
    /// Async: the query can block for tens of milliseconds and stall the panel's opening animation.
    func bytesFree(atPath path: String) async -> Int64?
}
