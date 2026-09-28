import Foundation
import Testing
@testable import KnotchyCore

struct WireProtocolTests {
    private let size = PixelSize(width: 1024, height: 640)

    private func decodeAll(_ bytes: Data, into decoder: inout AgentMessageDecoder) throws -> [AgentMessage] {
        decoder.append(bytes)
        var messages: [AgentMessage] = []
        while let message = try decoder.next() { messages.append(message) }
        return messages
    }

    private func decodeAll(_ bytes: Data) throws -> [AgentMessage] {
        var decoder = AgentMessageDecoder()
        return try decodeAll(bytes, into: &decoder)
    }

    private func violation(_ bytes: Data) -> AgentMessageDecoder.ProtocolViolation? {
        do {
            _ = try decodeAll(bytes)
            return nil
        } catch {
            return error as? AgentMessageDecoder.ProtocolViolation
        }
    }

    private func raw(_ type: UInt8, _ payload: [UInt8]) -> Data {
        framed(type, Data(payload))
    }

    @Test func matchesTheImageProtocolVersion() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let containerfile = try String(contentsOf: root.appending(path: "vm/Containerfile"), encoding: .utf8)
        let arg = containerfile.split(separator: "\n").first { $0.hasPrefix("ARG KNOTCHY_PROTOCOL=") }
        #expect(arg == "ARG KNOTCHY_PROTOCOL=\(WireProtocol.version)")
    }

    @Test func pageURLMustBeShortUTF8() throws {
        let hello = raw(MessageType.hello, [1, 0x04, 0x00, 0x02, 0x80])
        #expect(try decodeAll(hello + raw(MessageType.pageURL, Array("https://a.test/ü".utf8)))
                    == [.hello(version: 1, size: size), .pageURL("https://a.test/ü")])
        #expect(violation(hello + raw(MessageType.pageURL, [0x68, 0xC3])) != nil)          // cut-off UTF-8
        #expect(violation(hello + raw(MessageType.pageURL, [])) != nil)
        let long = [UInt8](repeating: 0x61, count: WireProtocol.maxPageURL + 1)
        #expect(violation(hello + raw(MessageType.pageURL, long)) != nil)
    }

    @Test func helloAndVideoBytesAreAsSpecified() throws {
        #expect(AgentMessage.hello(version: 1, size: size).encoded() == Data([0x01, 0, 0, 0, 5, 1, 0x04, 0x00, 0x02, 0x80]))
        let hello = raw(MessageType.hello, [1, 0x04, 0x00, 0x02, 0x80])
        let video = raw(MessageType.video, [0x04, 0x00, 0x02, 0x80, 0xAA])
        #expect(try decodeAll(hello + video) == [.hello(version: 1, size: size), .video(size: size, accessUnit: Data([0xAA]))])
    }

    @Test func roundTripsEveryAgentMessage() throws {
        let messages: [AgentMessage] = [
            .hello(version: 1, size: size),
            .navigated,
            .progress(0),
            .progress(100),
            .video(size: size, accessUnit: Data([0, 0, 0, 1, 0x09, 0xF0])),
            .pageURL("https://example.com/a?b=c#d"),
            .unknown(type: 0x7F),
        ]
        let stream = messages.reduce(into: Data()) { $0.append($1.encoded()) }
        #expect(try decodeAll(stream) == messages)
    }

    @Test func decodesAcrossArbitraryChunkBoundaries() throws {
        let messages: [AgentMessage] = [
            .hello(version: 1, size: size),
            .video(size: size, accessUnit: Data(repeating: 0xAB, count: 3000)),
            .progress(42),
        ]
        let stream = messages.reduce(into: Data()) { $0.append($1.encoded()) }
        var decoder = AgentMessageDecoder()
        var decoded: [AgentMessage] = []
        for chunkStart in stride(from: 0, to: stream.count, by: 7) {
            decoded += try decodeAll(stream.subdata(in: chunkStart..<min(chunkStart + 7, stream.count)), into: &decoder)
        }
        #expect(decoded == messages)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func readsTheHelloVersionAndAPreV1HelloIsVersionZero() throws {
        #expect(try decodeAll(raw(MessageType.hello, [2, 0x04, 0x00, 0x02, 0x80])) == [.hello(version: 2, size: size)])
        let legacy = raw(MessageType.hello, [0x04, 0x00, 0x02, 0x80])
        #expect(try decodeAll(legacy) == [.hello(version: 0, size: size)])
        #expect(AgentMessage.hello(version: 0, size: size).encoded() == legacy)
    }

    @Test func waitsForTheRestOfATruncatedMessage() throws {
        var decoder = AgentMessageDecoder()
        let hello = AgentMessage.hello(version: 1, size: size).encoded()
        #expect(try decodeAll(hello.prefix(7), into: &decoder) == [])
        #expect(decoder.bufferedByteCount == 7)
        #expect(try decodeAll(hello.dropFirst(7), into: &decoder) == [.hello(version: 1, size: size)])
    }

    @Test func rejectsWrongFixedSizes() {
        let hello = AgentMessage.hello(version: 1, size: size).encoded()
        #expect(violation(raw(MessageType.hello, [1, 2, 3])) != nil)
        #expect(violation(raw(MessageType.hello, [1, 0x04, 0x00, 0x02, 0x80, 0])) != nil)
        #expect(violation(hello + raw(MessageType.progress, [])) != nil)
        #expect(violation(hello + raw(MessageType.progress, [1, 2])) != nil)
        #expect(violation(hello + raw(MessageType.navigated, [0])) != nil)
        #expect(violation(hello + raw(MessageType.video, [0x04, 0x00, 0x02])) != nil)
    }

    @Test func rejectsProgressOver100() {
        let hello = AgentMessage.hello(version: 1, size: size).encoded()
        #expect(violation(hello + raw(MessageType.progress, [101])) != nil)
    }

    @Test func rejectsOversizedMessagesAsSoonAsTheHeaderArrives() {
        let hello = AgentMessage.hello(version: 1, size: size).encoded()
        var video = Data([MessageType.video])
        video.appendBE32(UInt32(WireProtocol.maxVideoPayload + 1))
        #expect(violation(hello + video) != nil)

        var unknown = Data([0x7F])
        unknown.appendBE32(UInt32(WireProtocol.maxOtherPayload + 1))
        #expect(violation(hello + unknown) != nil)
    }

    @Test func acceptsMaximumSizeMessages() throws {
        let hello = AgentMessage.hello(version: 1, size: size)
        let video = AgentMessage.video(size: size, accessUnit: Data(count: WireProtocol.maxVideoPayload - 4))
        let unknown = raw(0x7F, [UInt8](repeating: 0, count: WireProtocol.maxOtherPayload))
        #expect(try decodeAll(hello.encoded() + video.encoded() + unknown) == [hello, video, .unknown(type: 0x7F)])
    }

    @Test func rejectsVideoWhoseSizeDiffersFromHello() {
        let hello = AgentMessage.hello(version: 1, size: size).encoded()
        for other in [PixelSize(width: 800, height: 600), PixelSize(width: 1024, height: 600), PixelSize(width: 800, height: 640)] {
            #expect(violation(hello + AgentMessage.video(size: other, accessUnit: Data([1])).encoded()) != nil)
        }
    }

    @Test func aViolationIsFinal() throws {
        var decoder = AgentMessageDecoder()
        decoder.append(AgentMessage.hello(version: 1, size: size).encoded()
                       + raw(MessageType.progress, [101]) + AgentMessage.progress(50).encoded())
        #expect(try decoder.next() == .hello(version: 1, size: size))
        #expect(throws: AgentMessageDecoder.ProtocolViolation.self) { try decoder.next() }
        #expect(throws: AgentMessageDecoder.ProtocolViolation.self) { try decoder.next() }
        decoder.append(Data(count: 1000))
        #expect(decoder.storedByteCount == 0)
    }

    @Test func staysBoundedWhenReadsNeverEndOnAMessageBoundary() throws {
        let readSize = 4099   // Not a multiple of the 5-byte NAVIGATED, so reads end mid-message.
        var decoder = AgentMessageDecoder()
        var stream = AgentMessage.hello(version: 1, size: size).encoded()
        for _ in 0..<100_000 { stream.append(AgentMessage.navigated.encoded()) }
        var decoded = 0
        var largest = 0
        for chunkStart in stride(from: 0, to: stream.count, by: readSize) {
            decoded += try decodeAll(stream.subdata(in: chunkStart..<min(chunkStart + readSize, stream.count)), into: &decoder).count
            largest = max(largest, decoder.storedByteCount)
        }
        #expect(decoded == 100_001)
        #expect(largest <= readSize + WireProtocol.headerSize)
    }

    @Test func rejectsAnythingBeforeHelloAndASecondHello() {
        let hello = AgentMessage.hello(version: 1, size: size).encoded()
        #expect(violation(AgentMessage.navigated.encoded()) != nil)
        #expect(violation(AgentMessage.progress(10).encoded()) != nil)
        #expect(violation(raw(MessageType.video, [0x04, 0x00, 0x02, 0x80, 0xAA])) != nil)
        #expect(violation(AgentMessage.unknown(type: 0x7F).encoded()) != nil)
        #expect(violation(hello + hello) != nil)
    }
}

struct InputEventTests {
    @Test func encodesPointerMessages() {
        #expect(InputEvent.pointerMove(x: 0x0102, y: 0x0304, mods: [.shift, .leftButton]).encoded()
            == Data([0x10, 0, 0, 0, 5, 0x01, 0x02, 0x03, 0x04, 0x11]))
        #expect(InputEvent.pointerButton(.right, pressed: true, x: 10, y: 20, mods: .control).encoded()
            == Data([0x11, 0, 0, 0, 7, 2, 1, 0, 10, 0, 20, 0x02]))
        #expect(InputEvent.pointerButton(.left, pressed: false, x: 0, y: 0, mods: []).encoded()
            == Data([0x11, 0, 0, 0, 7, 1, 0, 0, 0, 0, 0, 0]))
    }

    @Test func encodesScrollTicksAsSignedBigEndian() {
        #expect(InputEvent.scroll(ticksX: 0, ticksY: -3, x: 1, y: 2).encoded()
            == Data([0x12, 0, 0, 0, 8, 0, 0, 0xFF, 0xFD, 0, 1, 0, 2]))
    }

    @Test func encodesKeysAndStrings() {
        #expect(InputEvent.key(pressed: true, mods: .meta, name: "Return").encoded()
            == Data([0x13, 0, 0, 0, 8, 1, 0x08]) + Data("Return".utf8))
        #expect(InputEvent.navigate("https://a.example").encoded()
            == Data([0x14, 0, 0, 0, 17]) + Data("https://a.example".utf8))
        #expect(InputEvent.script("history.back()").encoded()
            == Data([0x15, 0, 0, 0, 14]) + Data("history.back()".utf8))
        #expect(InputEvent.keyframe.encoded() == Data([0x16, 0, 0, 0, 0]))
    }

    @Test func modifierBitsMatchTheAgent() {
        let bits: [Modifiers] = [.shift, .control, .alt, .meta, .leftButton, .rightButton, .middleButton]
        #expect(bits.map(\.rawValue) == [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40])
    }

    @Test func refusesMessagesTheAgentCouldNotUse() {
        #expect(InputEvent.script(String(repeating: "a", count: WireProtocol.maxOtherPayload)).encoded() != nil)
        #expect(InputEvent.script(String(repeating: "a", count: WireProtocol.maxOtherPayload + 1)).encoded() == nil)
        #expect(InputEvent.key(pressed: true, mods: [], name: "").encoded() == nil)
        #expect(InputEvent.key(pressed: true, mods: [], name: "\u{0}x").encoded() == nil)
        #expect(InputEvent.navigate("https://a.example/\u{0}").encoded() == nil)
        #expect(InputEvent.script("history.back()\u{0}").encoded() == nil)
    }
}
