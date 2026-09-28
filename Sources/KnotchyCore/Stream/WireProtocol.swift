import Foundation

/// knotchy-agent ↔ viewer framing, both directions: `[u8 type][u32 big-endian payload length][payload]`.
public enum WireProtocol {
    /// Must equal `ARG KNOTCHY_PROTOCOL` in vm/Containerfile. 2: proxy/VPN routes. 3: PAGE_URL.
    public static let version = 3
    public static let headerSize = 5
    public static let maxVideoPayload = 2 * 1024 * 1024
    /// Also the agent's cap on viewer messages; unknown agent messages up to this size are skipped.
    public static let maxOtherPayload = 64 * 1024
    public static let maxPageURL = 16 * 1024
}

enum MessageType {
    static let hello: UInt8 = 0x01
    static let video: UInt8 = 0x02
    static let progress: UInt8 = 0x03
    static let navigated: UInt8 = 0x04
    static let pageURL: UInt8 = 0x05
    static let pointerMove: UInt8 = 0x10
    static let pointerButton: UInt8 = 0x11
    static let scroll: UInt8 = 0x12
    static let key: UInt8 = 0x13
    static let navigate: UInt8 = 0x14
    static let script: UInt8 = 0x15
    static let keyframe: UInt8 = 0x16
}

public struct PixelSize: Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }
}

public enum AgentMessage: Equatable, Sendable {
    /// Version 0 means a pre-v1 image, whose HELLO has no version byte.
    case hello(version: Int, size: PixelSize)
    case video(size: PixelSize, accessUnit: Data)
    case progress(Int)
    case navigated
    case pageURL(String)
    case unknown(type: UInt8)
}

extension AgentMessage {
    /// For tests and fake agents: out-of-range values trap, so build malformed frames by hand.
    func encoded() -> Data {
        var payload = Data()
        let type: UInt8
        switch self {
        case .hello(let version, let size):
            type = MessageType.hello
            if version != 0 { payload.append(UInt8(version)) }
            payload.appendBE16(UInt16(size.width))
            payload.appendBE16(UInt16(size.height))
        case .video(let size, let accessUnit):
            type = MessageType.video
            payload.appendBE16(UInt16(size.width))
            payload.appendBE16(UInt16(size.height))
            payload.append(accessUnit)
        case .progress(let percent):
            type = MessageType.progress
            payload.append(UInt8(percent))
        case .navigated:
            type = MessageType.navigated
        case .pageURL(let url):
            type = MessageType.pageURL
            payload.append(Data(url.utf8))
        case .unknown(let unknownType):
            type = unknownType
        }
        return framed(type, payload)
    }
}

func framed(_ type: UInt8, _ payload: Data) -> Data {
    var message = Data([type])
    message.appendBE32(UInt32(payload.count))
    message.append(payload)
    return message
}

extension Data {
    mutating func appendBE16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBE32(_ value: UInt32) {
        appendBE16(UInt16(value >> 16))
        appendBE16(UInt16(truncatingIfNeeded: value))
    }
}

/// Strict incremental parser; the VM is untrusted, so any bad message is a final violation.
/// Call `next()` until nil after each `append`: that keeps the buffer to one message plus one read.
public struct AgentMessageDecoder: Sendable {
    public struct ProtocolViolation: Error, Equatable, Sendable, CustomStringConvertible {
        public let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    public private(set) var helloSize: PixelSize?
    private var buffer: [UInt8] = []
    private var start = 0
    private var violation: ProtocolViolation?

    public init() {}

    public mutating func append(_ bytes: Data) {
        guard violation == nil else { return }
        if start > 0 {
            buffer.removeFirst(start)
            start = 0
        }
        buffer.append(contentsOf: bytes)
    }

    public var bufferedByteCount: Int { buffer.count - start }

    /// Includes bytes already returned; for tests of the bound.
    var storedByteCount: Int { buffer.count }

    public mutating func next() throws(ProtocolViolation) -> AgentMessage? {
        if let violation { throw violation }
        do {
            return try decodeNext()
        } catch {
            violation = error
            buffer = []
            start = 0
            throw error
        }
    }

    private mutating func decodeNext() throws(ProtocolViolation) -> AgentMessage? {
        guard bufferedByteCount >= WireProtocol.headerSize else { return nil }
        let type = buffer[start]
        let length = Int(be32(at: start + 1))
        try checkHeader(type: type, length: length)
        guard bufferedByteCount - WireProtocol.headerSize >= length else { return nil }

        let p = start + WireProtocol.headerSize
        start = p + length
        switch type {
        case MessageType.hello:
            let version = length == 5 ? Int(buffer[p]) : 0
            let sizeAt = p + length - 4
            let size = PixelSize(width: Int(be16(at: sizeAt)), height: Int(be16(at: sizeAt + 2)))
            helloSize = size
            return .hello(version: version, size: size)
        case MessageType.video:
            let size = PixelSize(width: Int(be16(at: p)), height: Int(be16(at: p + 2)))
            guard size == helloSize else {
                throw ProtocolViolation("VIDEO is \(size) but HELLO said \(helloSize.map(\.description) ?? "nothing")")
            }
            return .video(size: size, accessUnit: Data(buffer[(p + 4)..<(p + length)]))
        case MessageType.progress:
            let percent = Int(buffer[p])
            guard percent <= 100 else { throw ProtocolViolation("PROGRESS \(percent) is over 100") }
            return .progress(percent)
        case MessageType.navigated:
            return .navigated
        case MessageType.pageURL:
            guard let url = String(validating: buffer[p..<(p + length)], as: UTF8.self) else {
                throw ProtocolViolation("PAGE_URL isn't UTF-8")
            }
            return .pageURL(url)
        default:
            return .unknown(type: type)
        }
    }

    private func checkHeader(type: UInt8, length: Int) throws(ProtocolViolation) {
        func name() -> String { String(format: "type 0x%02x", type) }
        if helloSize == nil, type != MessageType.hello {
            throw ProtocolViolation("\(name()) before HELLO")
        }
        let valid: Bool
        switch type {
        case MessageType.hello:
            guard helloSize == nil else { throw ProtocolViolation("a second HELLO") }
            valid = length == 5 || length == 4
        case MessageType.video:
            valid = (4...WireProtocol.maxVideoPayload).contains(length)
        case MessageType.progress:
            valid = length == 1
        case MessageType.navigated:
            valid = length == 0
        case MessageType.pageURL:
            valid = (1...WireProtocol.maxPageURL).contains(length)
        default:
            valid = length <= WireProtocol.maxOtherPayload
        }
        guard valid else { throw ProtocolViolation("\(name()) with a \(length)-byte payload") }
    }

    private func be16(at i: Int) -> UInt16 {
        UInt16(buffer[i]) << 8 | UInt16(buffer[i + 1])
    }

    private func be32(at i: Int) -> UInt32 {
        UInt32(be16(at: i)) << 16 | UInt32(be16(at: i + 2))
    }
}
