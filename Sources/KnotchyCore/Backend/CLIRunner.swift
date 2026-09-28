import Foundation
import Synchronization

public struct CLIRunner: Sendable {
    public struct Output: Sendable {
        public var status: Int32
        public var text: String

        public var lastLine: String {
            text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit status \(status)"
        }
    }

    public enum Failure: Error, Equatable {
        case notInstalled
        case timedOut([String])
        case launchFailed(String)
    }

    // Fixed paths: apps launched from the Services menu get a minimal PATH.
    public static let searchPaths = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]
    public let searchPaths: [String]

    public init(searchPaths: [String] = CLIRunner.searchPaths) {
        self.searchPaths = searchPaths
    }

    /// Looked up on every call, so a runtime installed while the app runs is found.
    public var executable: String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func run(_ args: [String], timeout: TimeInterval,
                    line: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.runBlocking(args, timeout: timeout, line: line) })
            }
        }
    }

    static let outputLimit = 1024 * 1024

    private static let builds = Mutex(Set<Int32>())

    /// Builds would outlive the app. Other commands are left to the quit path, which waits for them.
    public static func stopBuilds() {
        for pid in builds.withLock({ $0 }) { kill(pid, SIGTERM) }
    }

    public func runBlocking(_ args: [String], timeout: TimeInterval,
                            line: (@Sendable (String) -> Void)? = nil) throws -> Output {
        guard let executable else { throw Failure.notInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Only the tail is kept: a noisy build can print for minutes.
        let limit = Self.outputLimit
        let collected = Mutex(Data())
        let pending = Mutex(Data())
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collected.withLock { buffer in
                buffer.append(chunk)
                if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
            }
            guard let line else { return }
            let lines: [String] = pending.withLock { buffer in
                buffer.append(chunk)
                var out: [String] = []
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    out.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                if buffer.count > 16 * 1024 {   // A line that never ends.
                    out.append(String(decoding: buffer.prefix(16 * 1024), as: UTF8.self))
                    buffer.removeAll()
                }
                return out
            }
            for text in lines where !text.trimmingCharacters(in: .whitespaces).isEmpty { line(text) }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw Failure.launchFailed(error.localizedDescription)
        }
        let pid = process.processIdentifier
        let isBuild = args.first == "build"
        if isBuild { Self.builds.withLock { _ = $0.insert(pid) } }
        defer { if isBuild { Self.builds.withLock { _ = $0.remove(pid) } } }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            throw Failure.timedOut(args)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        let data = collected.withLock { ($0 + rest).suffix(limit) }
        return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }
}
