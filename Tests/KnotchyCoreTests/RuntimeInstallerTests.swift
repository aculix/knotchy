import CryptoKit
import Foundation
import Testing
@testable import KnotchyCore

// Serialized: each download clears leftover download folders, which other tests would still be using.
@Suite(.serialized)
struct RuntimeInstallerTests {
    private func release(for data: Data, url: URL) -> ContainerRuntime.Release {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ContainerRuntime.Release(version: "1.4.1", url: url, sha256: hash, size: Int64(data.count))
    }

    private func source(_ data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).pkg")
        try data.write(to: file)
        return file
    }

    private static func downloadDirectories() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(names.filter { $0.hasPrefix("knotchy-runtime-") })
    }

    @Test func aMatchingDownloadIsKeptUntilDiscarded() async throws {
        let data = Data("package".utf8)
        let url = try source(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let installer = SystemRuntimeInstaller()
        let package = try await installer.download(release(for: data, url: url)) { _ in }
        #expect(try Data(contentsOf: package.file) == data)
        #expect(package.file.lastPathComponent == url.lastPathComponent)
        installer.discard(package)
        #expect(!FileManager.default.fileExists(atPath: package.directory.path))
    }

    @Test func aMismatchedDownloadIsDeleted() async throws {
        let url = try source(Data("tampered".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = release(for: Data("package".utf8), url: url)
        await #expect(throws: DownloadError.mismatch) {
            _ = try await SystemRuntimeInstaller().download(expected) { _ in }
        }
        #expect(Self.downloadDirectories().isEmpty)
    }

    @Test func aNewDownloadClearsLeftovers() async throws {
        let leftover = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("knotchy-runtime-LEFTOVER")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let data = Data("package".utf8)
        let url = try source(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let installer = SystemRuntimeInstaller()
        let package = try await installer.download(release(for: data, url: url)) { _ in }
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        installer.discard(package)
    }

    @Test func aFailedDownloadSaysSo() async {
        let missing = URL(fileURLWithPath: "/nonexistent/container.pkg")
        await #expect(throws: DownloadError.self) {
            _ = try await SystemRuntimeInstaller().download(release(for: Data(), url: missing)) { _ in }
        }
    }

    // Only this path of the real `openInInstaller` may run in tests: any other would open Installer.
    @MainActor
    @Test func aChangedPackageIsNotOpened() async throws {
        let data = Data("package".utf8)
        let url = try source(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let installer = SystemRuntimeInstaller()
        let expected = release(for: data, url: url)
        let package = try await installer.download(expected) { _ in }
        try Data("pAckage".utf8).write(to: package.file)   // Same size, so the hash has to catch it.
        guard case .changed = await installer.openInInstaller(package, release: expected) else {
            Issue.record("Expected the changed package not to be opened")
            installer.discard(package)
            return
        }
        #expect(!FileManager.default.fileExists(atPath: package.directory.path))
    }
}
