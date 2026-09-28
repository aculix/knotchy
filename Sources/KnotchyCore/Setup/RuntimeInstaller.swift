import AppKit
import CryptoKit
import Foundation

public struct DownloadedPackage: Equatable, Sendable {
    public let directory: URL
    /// Apple's own file name, which Installer shows.
    public let name: String
    public var file: URL { directory.appendingPathComponent(name) }

    public init(directory: URL, name: String) {
        self.directory = directory
        self.name = name
    }
}

public enum DownloadError: Error, Equatable, Sendable {
    case failed(String)
    /// Size or SHA-256 differ from the pinned release; the download is already deleted.
    case mismatch
}

@MainActor
public protocol InstallerSession: AnyObject {
    var hasQuit: Bool { get }
}

public enum InstallerOpening {
    case opened(any InstallerSession)
    /// Size or SHA-256 no longer match; the download is already deleted.
    case changed
    case failed(String)
}

public protocol RuntimeInstalling: Sendable {
    func download(_ release: ContainerRuntime.Release,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> DownloadedPackage
    /// Re-checks the size and hash off the main thread, then opens the package in Installer.
    @MainActor func openInInstaller(_ package: DownloadedPackage, release: ContainerRuntime.Release) async -> InstallerOpening
    func discard(_ package: DownloadedPackage)
}

public struct SystemRuntimeInstaller: RuntimeInstalling {
    static let installerApp = URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app")

    public init() {}

    public func download(_ release: ContainerRuntime.Release,
                         progress: @escaping @Sendable (Int64) -> Void) async throws -> DownloadedPackage {
        Self.removeLeftovers()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knotchy-runtime-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw DownloadError.failed(error.localizedDescription)
        }
        let package = DownloadedPackage(directory: directory, name: release.url.lastPathComponent)
        do {
            try await PackageDownload.fetch(release.url, to: package.file, progress: progress)
        } catch {
            discard(package)
            throw DownloadError.failed(error.localizedDescription)
        }
        guard Self.matches(package.file, release) else {
            discard(package)
            throw DownloadError.mismatch
        }
        return package
    }

    public func discard(_ package: DownloadedPackage) {
        try? FileManager.default.removeItem(at: package.directory)
    }

    /// Folders left by quitting mid-download or a crash.
    public static func removeLeftovers() {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix("knotchy-runtime-") {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
        }
    }

    @MainActor
    public func openInInstaller(_ package: DownloadedPackage, release: ContainerRuntime.Release) async -> InstallerOpening {
        let file = package.file
        guard await Task.detached(operation: { Self.matches(file, release) }).value else {
            discard(package)
            return .changed
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            let app = try await NSWorkspace.shared.open([file], withApplicationAt: Self.installerApp,
                                                        configuration: configuration)
            return .opened(RunningInstaller(app: app))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func matches(_ file: URL, _ release: ContainerRuntime.Release) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
              size.int64Value == release.size,
              let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == release.sha256
    }
}

@MainActor
private final class RunningInstaller: InstallerSession {
    let app: NSRunningApplication

    init(app: NSRunningApplication) {
        self.app = app
    }

    var hasQuit: Bool { app.isTerminated }
}

/// A data task streamed into the package file, so the partial download lives only in its own folder.
private final class PackageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Touched only on the session's serial delegate queue.
    private var continuation: CheckedContinuation<Void, any Error>?
    /// A completion that arrived before anyone waited: a task cancelled before it started.
    private var outcome: Result<Void, any Error>?
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var writeError: (any Error)?
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void

    private init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = PackageDownload(destination: destination, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        // Created up front: cancelling before it exists would invalidate the session, and creating it then throws.
        let task = session.dataTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.addOperation {
                    if let outcome = delegate.outcome {
                        continuation.resume(with: outcome)
                    } else {
                        delegate.continuation = continuation
                        task.resume()
                    }
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            writeError = URLError(.badServerResponse)
            return completionHandler(.cancel)
        }
        do {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
            }
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            writeError = error
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, writeError == nil else { return }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            progress(written)
        } catch {
            writeError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? handle?.close()
        handle = nil
        // Ours comes first: cancelling after it adds a "cancelled" error.
        let result: Result<Void, any Error> = if let failure = writeError ?? error { .failure(failure) } else { .success(()) }
        if let waiting = continuation {
            continuation = nil
            waiting.resume(with: result)
        } else {
            outcome = result
        }
    }
}
