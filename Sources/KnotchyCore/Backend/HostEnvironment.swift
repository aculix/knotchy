import Darwin
import Foundation

public enum HostNetworks {
    /// Blocked in the VM on top of the private ranges, for LANs and VPNs on public addresses.
    public static func current() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var networks = Set<String>()
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, let mask = interface.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let prefix = bits.nonzeroBitCount
            guard prefix >= 8 else { continue }   // Never let a bogus /0 block the whole internet.
            let network = ip & bits
            networks.insert("\(network >> 24).\((network >> 16) & 0xFF).\((network >> 8) & 0xFF).\(network & 0xFF)/\(prefix)")
        }
        return networks.sorted()
    }
}

public struct SystemDiskSpace: DiskSpaceChecking {
    public init() {}

    @concurrent
    public func bytesFree(atPath path: String) async -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
