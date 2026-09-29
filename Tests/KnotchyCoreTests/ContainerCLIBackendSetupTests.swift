import Foundation
import Synchronization
import Testing
@testable import KnotchyCore

/// Runs `fix` against a fake `container` that logs its arguments.
struct ContainerCLIBackendSetupTests {
    private struct FakeCLI {
        let directory: URL
        let runner: CLIRunner
        var log: [String] {
            let text = (try? String(contentsOf: directory.appendingPathComponent("log"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }
    }

    /// `properties` is what `system property list --format json` prints.
    private func fakeCLI(properties: String = "{}") throws -> FakeCLI {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try properties.write(to: directory.appendingPathComponent("properties.json"), atomically: true, encoding: .utf8)
        let tool = directory.appendingPathComponent("container")
        let script = """
            #!/bin/sh
            echo "$*" >> '\(directory.path)/log'
            # A test makes a command fail by creating fail-<first word> or fail-<first>-<second>.
            if [ -f '\(directory.path)/fail-'"$1" ] || [ -f '\(directory.path)/fail-'"$1-$2" ]; then exit 1; fi
            if [ "$1 $2 $3" = "system property list" ]; then cat '\(directory.path)/properties.json'; exit 0; fi
            if [ "$1 $2" = "builder status" ]; then cat '\(directory.path)/builder.json' 2>/dev/null; exit 0; fi
            # The archive must still be there when it's installed.
            if [ "$1 $2 $3 $4" = "system kernel set --tar" ]; then [ -f "$5" ] || exit 3; fi
            exit 0

            """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return FakeCLI(directory: directory, runner: CLIRunner(searchPaths: [tool.path]))
    }

    private func fail(_ command: String, in cli: FakeCLI) throws {
        try Data().write(to: cli.directory.appendingPathComponent("fail-\(command)"))
    }

    /// What `builder status --format json` prints; without it the state can't be read.
    private func builder(_ json: String, in cli: FakeCLI) throws {
        try json.write(to: cli.directory.appendingPathComponent("builder.json"), atomically: true, encoding: .utf8)
    }

    private func build(with cli: FakeCLI) async throws {
        try await ContainerCLIBackend(vmSources: cli.directory, cli: cli.runner).fix(.imageMissing) { _ in }
    }

    private func kernelProperties(url: URL) -> String {
        #"{"kernel":{"binaryPath":"opt/kata/vmlinux","digest":"sha256:abc123","url":"\#(url.absoluteString)"}}"#
    }

    @Test func startingTheServiceLeavesTheKernelToItsOwnStep() async throws {
        let cli = try fakeCLI()
        defer { try? FileManager.default.removeItem(at: cli.directory) }
        try await ContainerCLIBackend(vmSources: nil, cli: cli.runner).fix(.serviceStopped) { _ in }
        #expect(cli.log == ["system start --disable-kernel-install"])
    }

    @Test func theKernelIsDownloadedWithProgressThenInstalledFromTheFile() async throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("kata-\(UUID().uuidString).tar.zst")
        try Data(count: 3_000_000).write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        let cli = try fakeCLI(properties: kernelProperties(url: archive))
        defer { try? FileManager.default.removeItem(at: cli.directory) }
        let lines = LineLog()

        try await ContainerCLIBackend(vmSources: nil, cli: cli.runner).fix(.kernelMissing) { lines.append($0) }

        #expect(cli.log.count == 2)
        #expect(cli.log.first == "system property list --format json")
        let install = try #require(cli.log.last?.split(separator: " ").map(String.init))
        #expect(Array(install.prefix(4)) == ["system", "kernel", "set", "--tar"])
        #expect(Array(install.dropFirst(5)) == ["--binary", "opt/kata/vmlinux", "--digest", "sha256:abc123", "--force"])
        // The download is deleted once the runtime has its copy.
        let downloaded = URL(fileURLWithPath: install[4])
        #expect(downloaded.deletingLastPathComponent().lastPathComponent.hasPrefix("knotchy-kernel-"))
        #expect(!FileManager.default.fileExists(atPath: downloaded.deletingLastPathComponent().path))
        #expect(lines.all.contains("Downloading the Linux kernel… 3 of 3 MB"))
        #expect(lines.all.last == "Installing the Linux kernel…")
    }

    @Test func aFailedKernelDownloadInstallsNothing() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).tar.zst")
        let cli = try fakeCLI(properties: kernelProperties(url: missing))
        defer { try? FileManager.default.removeItem(at: cli.directory) }
        await #expect(throws: VMBackendError.failed("Couldn't download the Linux kernel. Check your connection and try again.")) {
            try await ContainerCLIBackend(vmSources: nil, cli: cli.runner).fix(.kernelMissing) { _ in }
        }
        #expect(cli.log == ["system property list --format json"])
    }

    @Test func aRebuildDeletesTheImageItReplaced() async throws {
        let cli = try fakeCLI()
        defer { try? FileManager.default.removeItem(at: cli.directory) }
        try await build(with: cli)
        #expect(cli.log.count == 4)
        #expect(cli.log.first == "builder status --format json")
        #expect(cli.log.dropFirst().first == "image tag local/knotchy-vm:latest local/knotchy-vm:previous")
        #expect(cli.log.dropFirst(2).first?.hasPrefix("build ") == true)
        #expect(cli.log.last == "image delete local/knotchy-vm:previous")
    }

    @Test func aFirstBuildHasNothingToDelete() async throws {
        let cli = try fakeCLI()
        defer { try? FileManager.default.removeItem(at: cli.directory) }
        try fail("image-tag", in: cli)
        try await build(with: cli)
        #expect(!cli.log.contains { $0.hasPrefix("image delete") })
        #expect(cli.log.last?.hasPrefix("build ") == true)
    }

    @Test func aFailedBuildKeepsTheImageButDropsTheExtraNameAndTheBuilder() async throws {
        let cli = try fakeCLI()
        defer { try? FileManager.default.removeItem(at: cli.directory) }
        try builder("[]", in: cli)
        try fail("build", in: cli)
        await #expect(throws: VMBackendError.self) { try await build(with: cli) }
        #expect(Array(cli.log.suffix(2)) == ["image delete local/knotchy-vm:previous", "builder delete --force"])
        #expect(!cli.log.contains { $0.hasPrefix("image delete local/knotchy-vm:latest") })
    }

    @Test func aBuilderTheBuildCreatedIsDeletedAfterwards() async throws {
        let cli = try fakeCLI()
        defer { try? FileManager.default.removeItem(at: cli.directory) }
        try builder("[]", in: cli)
        try await build(with: cli)
        #expect(cli.log.last == "builder delete --force")
    }

    @Test func aStoppedBuilderIsStoppedAgain() async throws {
        let cli = try fakeCLI()
        defer { try? FileManager.default.removeItem(at: cli.directory) }
        try builder(#"[{"id":"buildkit","status":{"state":"stopped"}}]"#, in: cli)
        try await build(with: cli)
        #expect(cli.log.last == "builder stop")
    }

    @Test func aRunningBuilderIsLeftRunning() async throws {
        let cli = try fakeCLI()
        defer { try? FileManager.default.removeItem(at: cli.directory) }
        try builder(#"[{"id":"buildkit","status":{"state":"running"}}]"#, in: cli)
        try await build(with: cli)
        #expect(cli.log.filter { $0.hasPrefix("builder") } == ["builder status --format json"])
    }

    @Test func aRuntimeThatDoesntNameItsKernelInstallsItsOwnRecommendation() async throws {
        let cli = try fakeCLI(properties: #"{"kernel":{}}"#)
        defer { try? FileManager.default.removeItem(at: cli.directory) }
        try await ContainerCLIBackend(vmSources: nil, cli: cli.runner).fix(.kernelMissing) { _ in }
        #expect(cli.log == ["system property list --format json", "system kernel set --recommended --force"])
    }
}

private final class LineLog: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    func append(_ line: String) { lines.withLock { $0.append(line) } }
}
