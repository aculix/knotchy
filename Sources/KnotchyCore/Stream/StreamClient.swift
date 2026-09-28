import CoreVideo
import Darwin
import Foundation

public struct StreamClient: StreamConnector {
    public let renderSize: PixelSize

    public init(renderSize: PixelSize) {
        self.renderSize = renderSize
    }

    public func connect(socketPath: String) async throws -> any StreamConnection {
        let renderSize = renderSize
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.connectBlocking(path: socketPath, renderSize: renderSize) })
            }
        }
    }

    static func connectBlocking(path: String, renderSize: PixelSize) throws -> StreamSession {
        let deadline = Date().addingTimeInterval(30)
        var connectedOnce = false
        while Date() < deadline {
            if let fd = openSocket(path) {
                connectedOnce = true
                setReadTimeout(fd, seconds: 2)
                var decoder = AgentMessageDecoder()
                switch readHello(fd, into: &decoder) {
                case .hello(let version, let size):
                    guard version == WireProtocol.version else {
                        Darwin.close(fd)
                        throw StreamError.versionMismatch(found: version, need: WireProtocol.version)
                    }
                    guard size == renderSize else {
                        Darwin.close(fd)
                        throw StreamError.protocolViolation("HELLO is \(size), asked for \(renderSize)")
                    }
                    setReadTimeout(fd, seconds: 0)
                    // A VM that stops reading input must not wedge the session's queue.
                    setSendTimeout(fd, seconds: 2)
                    return StreamSession(fd: fd, decoder: decoder, size: size)
                case .violation(let detail):
                    Darwin.close(fd)
                    throw StreamError.protocolViolation(detail)
                case .none:
                    Darwin.close(fd)
                }
            }
            usleep(100_000)
        }
        throw connectedOnce ? StreamError.timedOut : StreamError.refused
    }

    private enum HelloOutcome {
        case hello(version: Int, size: PixelSize)
        case violation(String)
        case none
    }

    private static func readHello(_ fd: Int32, into decoder: inout AgentMessageDecoder) -> HelloOutcome {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return .none }
            decoder.append(Data(buffer[0..<n]))
            do {
                if case .hello(let version, let size)? = try decoder.next() { return .hello(version: version, size: size) }
            } catch {
                return .violation(error.description)
            }
        }
    }

    private static func openSocket(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval.init(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func setSendTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval.init(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Its reader thread must never stop (the VM's watchdog needs a connected viewer); all else runs on `queue`.
final class StreamSession: StreamConnection, @unchecked Sendable {
    static let firstFrameTimeout: TimeInterval = 20
    static let decodeErrorLimit = 10

    let events: AsyncStream<StreamEvent>
    private let continuation: AsyncStream<StreamEvent>.Continuation
    private let queue = DispatchQueue(label: "aculix.knotchy.stream")

    private let fd: Int32
    private var decoder: AgentMessageDecoder
    private var parser = H264Parser()
    private var video: VideoDecoder?
    private var readiness = ContentReadiness()
    private var announcedReady = false
    private var enabled = true
    private var waitingForIDR = false
    private var frameHandler: (@Sendable (DecodedFrame) -> Void)?
    private var readinessTimer: DispatchSourceTimer?
    private var firstFrameTimer: DispatchSourceTimer?
    private var pendingPageURL: URL?
    private var pageURLTimer: DispatchSourceTimer?
    private var decodeErrors: [Date] = []
    private var ended = false

    init(fd: Int32, decoder: AgentMessageDecoder, size: PixelSize) {
        self.fd = fd
        self.decoder = decoder
        let (stream, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        events = stream
        self.continuation = continuation
        continuation.yield(.hello(version: WireProtocol.version, size: size))
        queue.async { self.begin() }
        let reader = Thread { [self] in readLoop() }
        reader.name = "knotchy stream reader"
        reader.start()
    }

    // MARK: StreamConnection

    var decodeEnabled: Bool {
        get { queue.sync { enabled } }
        set {
            queue.async {
                if newValue, !self.enabled {
                    self.waitingForIDR = true
                    self.write(.keyframe)
                }
                self.enabled = newValue
            }
        }
    }

    func setFrameHandler(_ handler: @escaping @Sendable (DecodedFrame) -> Void) {
        queue.async { self.frameHandler = handler }
    }

    func send(_ input: InputEvent) {
        queue.async { self.write(input) }
    }

    func close() {
        queue.async { self.end(nil) }
    }

    // MARK: Reading

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            let chunk = Data(buffer[0..<n])
            queue.async { self.received(chunk) }
        }
        queue.async {
            self.end(.closed)
            Darwin.close(self.fd)
        }
    }

    private func begin() {
        readiness.hello(at: .now)
        scheduleReadinessTick()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.firstFrameTimeout)
        timer.setEventHandler { [weak self] in self?.end(.noFirstFrame) }
        timer.resume()
        firstFrameTimer = timer
        received(Data())   // Messages that arrived together with HELLO.
    }

    private func received(_ chunk: Data) {
        guard !ended else { return }
        decoder.append(chunk)
        do {
            while let message = try decoder.next() { handle(message) }
        } catch {
            end(.protocolViolation(error.description))
        }
    }

    private func handle(_ message: AgentMessage) {
        switch message {
        case .navigated:
            readiness.navigated(at: .now)
            scheduleReadinessTick()
        case .progress(let percent):
            readiness.progress(percent)
            continuation.yield(.progress(percent))
            announceIfReady()
        case .video(_, let accessUnit):
            firstFrameTimer?.cancel()
            firstFrameTimer = nil
            let unit = parser.parse(accessUnit)
            if unit.newParameterSets != nil || video == nil, let sets = parser.parameterSets {
                video = VideoDecoder(parameterSets: sets) { [weak self] frame, status in
                    guard let self else { return }
                    self.queue.async { self.decoded(frame, status: status) }
                }
            }
            guard enabled, !unit.sample.isEmpty, let video else { return }
            if waitingForIDR {
                guard unit.isIDR else { return }
                waitingForIDR = false
            }
            video.decode(unit.sample)
        case .pageURL(let text):
            guard let url = URL(string: text) else { return }
            pendingPageURL = url
            passOnPageURL()
        case .hello, .unknown:
            break
        }
    }

    private func decoded(_ frame: DecodedFrame?, status: OSStatus) {
        guard !ended else { return }
        guard let frame else { return decodeFailed() }
        if !readiness.isReady {
            readiness.frame(isUniform: Self.isUniform(frame.pixelBuffer))
            announceIfReady()
        }
        frameHandler?(frame)
    }

    private func decodeFailed() {
        let now = Date()
        decodeErrors = decodeErrors.filter { now.timeIntervalSince($0) < 60 } + [now]
        if decodeErrors.count > Self.decodeErrorLimit { return end(.decodeErrors) }
        waitingForIDR = true
        write(.keyframe)
    }

    private static func isUniform(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return true }
        let bytes = UnsafeRawBufferPointer(start: base, count: CVPixelBufferGetDataSize(buffer))
        return FrameSampler.isUniform(bytes, width: CVPixelBufferGetWidth(buffer),
                                      height: CVPixelBufferGetHeight(buffer),
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
    }

    // MARK: Readiness

    private func announceIfReady() {
        guard readiness.isReady, !announcedReady else { return }
        announcedReady = true
        readinessTimer?.cancel()
        readinessTimer = nil
        continuation.yield(.contentReady)
    }

    private func scheduleReadinessTick() {
        readinessTimer?.cancel()
        readinessTimer = nil
        guard let deadline = readiness.nextDeadline else { return }
        let wait = deadline - .now
        let seconds = max(0, Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.readiness.tick(now: .now)
            self.announceIfReady()
        }
        timer.resume()
        readinessTimer = timer
    }

    /// At most 10 a second, always including the last: a page can change its address in a loop.
    private func passOnPageURL() {
        guard pageURLTimer == nil, let url = pendingPageURL else { return }
        pendingPageURL = nil
        continuation.yield(.pageURL(url))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.ended else { return }
            self.pageURLTimer = nil
            self.passOnPageURL()
        }
        timer.resume()
        pageURLTimer = timer
    }

    // MARK: Writing and ending

    private func write(_ input: InputEvent) {
        guard !ended, let data = input.encoded() else { return }
        let stalled = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else {
                    return n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
                }
            }
            return false
        }
        if stalled { end(.socketError("The VM stopped taking input.")) }
    }

    private func end(_ reason: EndReason?) {
        guard !ended else { return }
        ended = true
        shutdown(fd, SHUT_RDWR)
        readinessTimer?.cancel()
        firstFrameTimer?.cancel()
        pageURLTimer?.cancel()
        video = nil
        frameHandler = nil
        if let reason { continuation.yield(.ended(reason)) }
        continuation.finish()
    }
}
