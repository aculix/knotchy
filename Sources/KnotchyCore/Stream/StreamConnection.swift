import CoreVideo

public protocol StreamConnector: Sendable {
    /// Returns once a valid HELLO arrives; a version mismatch is reported before any other HELLO problem.
    func connect(socketPath: String) async throws -> any StreamConnection
}

/// `@unchecked`: a decoded buffer is never written after VideoToolbox returns it.
public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer

    public init(_ pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

public protocol StreamConnection: AnyObject, Sendable {
    /// Unbounded: reading starts only after `connect` returns, and early events must not be lost.
    var events: AsyncStream<StreamEvent> { get }
    var decodeEnabled: Bool { get set }
    /// Called on the decode queue.
    func setFrameHandler(_ handler: @escaping @Sendable (DecodedFrame) -> Void)
    func send(_ input: InputEvent)
    func close()
}

public enum StreamEvent: Equatable, Sendable {
    case hello(version: Int, size: PixelSize)
    case contentReady
    case progress(Int)
    /// Untrusted (from the VM): display only.
    case pageURL(URL)
    case ended(EndReason)
}

public enum EndReason: Equatable, Sendable {
    /// EOF: the browser crashed, the firewall failed, or the VM's watchdog fired.
    case closed
    case protocolViolation(String)
    case noFirstFrame
    case decodeErrors
    case socketError(String)
}

public enum StreamError: Error, Equatable, Sendable {
    case versionMismatch(found: Int, need: Int)
    case protocolViolation(String)
    case timedOut
    case refused
}
