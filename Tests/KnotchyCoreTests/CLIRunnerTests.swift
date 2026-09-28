import Foundation
import Testing
@testable import KnotchyCore

struct CLIRunnerTests {
    @Test func findsARuntimeInstalledAfterLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("container")
        let runner = CLIRunner(searchPaths: [tool.path])
        #expect(runner.executable == nil)

        try "#!/bin/sh\necho container CLI version 1.4.1\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        #expect(runner.executable == tool.path)
        #expect(try runner.runBlocking(["--version"], timeout: 5).text.contains("1.4.1"))
    }
}
