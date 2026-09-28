import Foundation
import Virtualization

/// Knotchy is built for Apple silicon only; macOS itself refuses to open it on an Intel Mac.
public enum Unsupported: Equatable, Sendable {
    case noVirtualization
}

public struct HostFacts: Equatable, Sendable {
    public var unsupported: Unsupported?
    public var osVersion: String
    public var bytesFree: Int64?

    public init(unsupported: Unsupported?, osVersion: String, bytesFree: Int64?) {
        self.unsupported = unsupported
        self.osVersion = osVersion
        self.bytesFree = bytesFree
    }
}

public protocol HostChecking: Sendable {
    func facts() async -> HostFacts
}

public struct SystemHost: HostChecking {
    public init() {}

    /// Synchronous, so the app can decide on minimal mode before it registers anything.
    @MainActor
    public static func unsupported() -> Unsupported? {
        VZVirtualMachine.isSupported ? nil : .noVirtualization
    }

    public func facts() async -> HostFacts {
        let unsupported = await Self.unsupported()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var os = "macOS \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { os += ".\(version.patchVersion)" }
        // The runtime keeps its data under the home folder.
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return HostFacts(unsupported: unsupported, osVersion: os, bytesFree: values?.volumeAvailableCapacityForImportantUsage)
    }
}
