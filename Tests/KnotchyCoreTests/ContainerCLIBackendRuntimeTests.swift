import Foundation
import Testing
@testable import KnotchyCore

struct ContainerCLIBackendRuntimeTests {
    /// A fake `container` that answers only `--version`.
    private func fakeCLI(printing line: String) throws -> (CLIRunner, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tool = directory.appendingPathComponent("container")
        let script = "#!/bin/sh\nif [ \"$1\" = --version ]; then echo '\(line)'; exit 0; fi\nexit 1\n"
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (CLIRunner(searchPaths: [tool.path]), directory)
    }

    @Test func anOldRuntimeIsFlaggedBeforeAnythingElse() async throws {
        let (cli, directory) = try fakeCLI(printing: "container CLI version 1.3.0 (build: release)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = ContainerCLIBackend(vmSources: nil, cli: cli)
        #expect(await backend.runtimeStatus() == .outdated("1.3.0"))
        #expect(await backend.preflight() == .issue(.cliOutdated(found: "1.3.0")))
    }

    @Test func aMissingRuntimeIsReported() async {
        let backend = ContainerCLIBackend(vmSources: nil, cli: CLIRunner(searchPaths: ["/nonexistent/container"]))
        #expect(await backend.runtimeStatus() == .missing)
        #expect(await backend.preflight() == .issue(.cliMissing))
    }

    @Test func anOldRuntimeHasNoAutomaticFix() async throws {
        let backend = ContainerCLIBackend(vmSources: nil, cli: CLIRunner(searchPaths: []))
        await #expect(throws: VMBackendError.self) {
            try await backend.fix(.cliOutdated(found: "1.3.0")) { _ in }
        }
    }
}
