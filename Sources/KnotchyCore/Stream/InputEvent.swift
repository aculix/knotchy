import Foundation

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let control = Modifiers(rawValue: 1 << 1)
    public static let alt = Modifiers(rawValue: 1 << 2)
    public static let meta = Modifiers(rawValue: 1 << 3)
    public static let leftButton = Modifiers(rawValue: 1 << 4)
    public static let rightButton = Modifiers(rawValue: 1 << 5)
    public static let middleButton = Modifiers(rawValue: 1 << 6)
}

public enum PointerButton: UInt8, Sendable {
    case left = 1
    case right = 2
    case middle = 3
}

/// A viewer → agent message. Coordinates are render pixels from the top left; negative scroll is down/right.
public enum InputEvent: Equatable, Sendable {
    case pointerMove(x: UInt16, y: UInt16, mods: Modifiers)
    case pointerButton(PointerButton, pressed: Bool, x: UInt16, y: UInt16, mods: Modifiers)
    case scroll(ticksX: Int16, ticksY: Int16, x: UInt16, y: UInt16)
    case key(pressed: Bool, mods: Modifiers, name: String)
    case navigate(String)
    case script(String)
    case keyframe

    /// Nil if the agent can't use it: a payload over 64 KiB, an empty KEY name, or a NUL in a string.
    public func encoded() -> Data? {
        var payload = Data()
        let type: UInt8
        switch self {
        case .pointerMove(let x, let y, let mods):
            type = MessageType.pointerMove
            payload.appendBE16(x)
            payload.appendBE16(y)
            payload.append(mods.rawValue)
        case .pointerButton(let button, let pressed, let x, let y, let mods):
            type = MessageType.pointerButton
            payload.append(button.rawValue)
            payload.append(pressed ? 1 : 0)
            payload.appendBE16(x)
            payload.appendBE16(y)
            payload.append(mods.rawValue)
        case .scroll(let ticksX, let ticksY, let x, let y):
            type = MessageType.scroll
            payload.appendBE16(UInt16(bitPattern: ticksX))
            payload.appendBE16(UInt16(bitPattern: ticksY))
            payload.appendBE16(x)
            payload.appendBE16(y)
        case .key(let pressed, let mods, let name):
            guard !name.isEmpty, !name.utf8.contains(0) else { return nil }
            type = MessageType.key
            payload.append(pressed ? 1 : 0)
            payload.append(mods.rawValue)
            payload.append(contentsOf: Array(name.utf8))
        case .navigate(let url):
            guard !url.utf8.contains(0) else { return nil }
            type = MessageType.navigate
            payload.append(contentsOf: Array(url.utf8))
        case .script(let javaScript):
            guard !javaScript.utf8.contains(0) else { return nil }
            type = MessageType.script
            payload.append(contentsOf: Array(javaScript.utf8))
        case .keyframe:
            type = MessageType.keyframe
        }
        guard payload.count <= WireProtocol.maxOtherPayload else { return nil }
        return framed(type, payload)
    }
}
