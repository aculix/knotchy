// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Knotchy",
    platforms: [.macOS(.v26)],
    targets: [
        // Everything that isn't UI: session logic, protocol, geometry, VM backend.
        .target(name: "KnotchyCore"),
        .executableTarget(name: "Knotchy", dependencies: ["KnotchyCore"], exclude: ["Info.plist"]),
        .executableTarget(name: "knotchyctl", dependencies: ["KnotchyCore"]),
        .testTarget(name: "KnotchyCoreTests", dependencies: ["KnotchyCore"]),
    ]
)
