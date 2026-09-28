import Foundation

/// Apple's container runtime: the release Knotchy installs, and how an installed one is judged.
public enum ContainerRuntime {
    public struct Release: Equatable, Sendable {
        public let version: String
        public let url: URL
        public let sha256: String
        public let size: Int64

        public init(version: String, url: URL, sha256: String, size: Int64) {
            self.version = version
            self.url = url
            self.sha256 = sha256
            self.size = size
        }
    }

    /// The only package Knotchy ever installs. Bump it only after testing a new release.
    public static let pinned = Release(
        version: "1.4.1",
        url: URL(string: "https://github.com/apple/container/releases/download/1.4.1/container-1.4.1-installer-signed.pkg")!,
        sha256: "c0d2716afefbb194c93fae662e9cae7cc186bcbcf746816608ec673dd648a6a4",
        size: 117_773_865)
    public static let minimumVersion = "1.4.0"

    public static func version(in output: String) -> String? {
        output.firstMatch(of: #/container CLI version (\d+(?:\.\d+)+)/#).map { String($0.1) }
    }

    /// Output Knotchy can't read counts as current, so a new format can never cause a downgrade.
    public static func status(versionOutput: String?) -> RuntimeStatus {
        guard let versionOutput else { return .missing }
        guard let found = version(in: versionOutput) else { return .current(nil) }
        return isOlder(found, than: minimumVersion) ? .outdated(found) : .current(found)
    }

    public static func isOlder(_ version: String, than other: String) -> Bool {
        let lhs = version.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}

public enum RuntimeStatus: Equatable, Sendable {
    case missing
    case outdated(String)
    /// nil: installed, but its version couldn't be read.
    case current(String?)
}
