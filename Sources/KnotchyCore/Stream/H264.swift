import Foundation

public enum NALUnitType {
    public static let slice: UInt8 = 1
    public static let idrSlice: UInt8 = 5
    public static let sei: UInt8 = 6
    public static let sps: UInt8 = 7
    public static let pps: UInt8 = 8
    public static let accessUnitDelimiter: UInt8 = 9
}

public enum AnnexB {
    /// Splits an Annex-B stream into NAL units. Trailing zeros are trimmed: a NAL unit never ends in 0x00.
    public static func nalUnits(in stream: Data) -> [Data] {
        let bytes = [UInt8](stream)
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((code: i, payload: i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return starts.indices.compactMap { k in
            var end = k + 1 < starts.count ? starts[k + 1].code : bytes.count
            while end > starts[k].payload, bytes[end - 1] == 0 { end -= 1 }
            return end > starts[k].payload ? Data(bytes[starts[k].payload..<end]) : nil
        }
    }
}

public struct ParameterSets: Equatable, Sendable {
    public var sps: Data
    public var pps: Data

    public init(sps: Data, pps: Data) {
        self.sps = sps
        self.pps = pps
    }
}

public struct ParsedAccessUnit: Equatable, Sendable {
    /// AVCC-framed slice NAL units; empty if the access unit has none, so don't decode it.
    public var sample = Data()
    public var isIDR = false
    /// Set only on the unit that changes the SPS/PPS; if that unit is dropped, check `H264Parser.parameterSets`.
    public var newParameterSets: ParameterSets?
}

public struct H264Parser: Sendable {
    public private(set) var parameterSets: ParameterSets?

    public init() {}

    public mutating func parse(_ accessUnit: Data) -> ParsedAccessUnit {
        var unit = ParsedAccessUnit()
        var sps: Data?
        var pps: Data?
        for nal in AnnexB.nalUnits(in: accessUnit) {
            let header = nal[nal.startIndex]
            guard header & 0x80 == 0 else { continue }   // forbidden_zero_bit
            let type = header & 0x1F
            switch type {
            case NALUnitType.sps:
                sps = nal
            case NALUnitType.pps:
                pps = nal
            case NALUnitType.slice, NALUnitType.idrSlice:
                if type == NALUnitType.idrSlice { unit.isIDR = true }
                unit.sample.appendBE32(UInt32(nal.count))
                unit.sample.append(nal)
            default:
                break
            }
        }
        // SPS and PPS must come from the same access unit; x264 repeats both on every IDR.
        if let sps, let pps {
            let sets = ParameterSets(sps: sps, pps: pps)
            if sets != parameterSets {
                parameterSets = sets
                unit.newParameterSets = sets
            }
        }
        return unit
    }
}
