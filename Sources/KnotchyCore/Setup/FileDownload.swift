import Foundation

/// A data task streamed into a file, so a partial download lives only in its own folder.
final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Touched only on the session's serial delegate queue.
    private var continuation: CheckedContinuation<Void, any Error>?
    /// A completion that arrived before anyone waited: a task cancelled before it started.
    private var outcome: Result<Void, any Error>?
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var expected: Int64?
    private var writeError: (any Error)?
    private let destination: URL
    private let progress: @Sendable (_ written: Int64, _ expected: Int64?) -> Void

    private init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    /// `expected` is nil when the server doesn't say.
    static func fetch(_ url: URL, to destination: URL,
                      progress: @escaping @Sendable (_ written: Int64, _ expected: Int64?) -> Void) async throws {
        let delegate = FileDownload(destination: destination, progress: progress)
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
        if response.expectedContentLength > 0 { expected = response.expectedContentLength }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, writeError == nil else { return }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            progress(written, expected)
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

extension FileDownload {
    static func removeFolders(prefix: String) {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
        }
    }
}
