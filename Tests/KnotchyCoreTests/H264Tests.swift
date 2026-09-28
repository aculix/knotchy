import Foundation
import Testing
@testable import KnotchyCore

struct H264Tests {
    private let aud: [UInt8] = [0x09, 0xF0]
    private let sei: [UInt8] = [0x06, 0x05, 0x01, 0xAA, 0x80]
    private let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x1F, 0x8C]
    private let sps2: [UInt8] = [0x67, 0x42, 0xC0, 0x28, 0x8C]
    private let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
    private let pps2: [UInt8] = [0x68, 0xCE, 0x3C, 0x81]
    private let idr: [UInt8] = [0x65, 0x88, 0x84, 0x21]
    private let slice: [UInt8] = [0x41, 0x9A, 0x02]

    private let four: [UInt8] = [0, 0, 0, 1]
    private let three: [UInt8] = [0, 0, 1]

    private func avcc(_ nals: [UInt8]...) -> Data {
        nals.reduce(into: Data()) { data, nal in
            data.appendBE32(UInt32(nal.count))
            data.append(contentsOf: nal)
        }
    }

    @Test func splitsOnThreeAndFourByteStartCodes() {
        let stream = Data(four + aud + three + sps + four + pps + three + idr)
        #expect(AnnexB.nalUnits(in: stream) == [aud, sps, pps, idr].map { Data($0) })
    }

    @Test func ignoresLeadingBytesAndTrailingZeros() {
        let stream = Data([0xFF, 0x00] + three + slice + [0, 0] + four + slice + [0])
        #expect(AnnexB.nalUnits(in: stream) == [Data(slice), Data(slice)])
    }

    @Test func handlesStreamsWithoutStartCodes() {
        #expect(AnnexB.nalUnits(in: Data()) == [])
        #expect(AnnexB.nalUnits(in: Data([0x65, 0x88])) == [])
        #expect(AnnexB.nalUnits(in: Data(four)) == [])
        #expect(AnnexB.nalUnits(in: Data(three + idr + three)) == [Data(idr)])
    }

    @Test func turnsAnIDRAccessUnitIntoAnAVCCSampleWithNewParameterSets() {
        var parser = H264Parser()
        let unit = parser.parse(Data(four + aud + four + sps + four + pps + four + sei + four + idr + four + idr))
        #expect(unit.sample == avcc(idr, idr))
        #expect(unit.isIDR)
        #expect(unit.newParameterSets == ParameterSets(sps: Data(sps), pps: Data(pps)))
        #expect(parser.parameterSets == unit.newParameterSets)
    }

    @Test func repeatedParameterSetsAreNotAChange() {
        var parser = H264Parser()
        _ = parser.parse(Data(four + sps + four + pps + four + idr))
        let again = parser.parse(Data(four + aud + four + sps + four + pps + four + idr))
        #expect(again.newParameterSets == nil)
        let delta = parser.parse(Data(four + aud + four + slice))
        #expect(delta.sample == avcc(slice))
        #expect(!delta.isIDR)
        #expect(delta.newParameterSets == nil)
        // Repeated with every IDR: not a change, so the decoder isn't rebuilt.
        let nextIDR = parser.parse(Data(four + aud + four + sps + four + pps + four + idr))
        #expect(nextIDR.newParameterSets == nil)
    }

    @Test func aChangedSPSOrPPSIsANewFormat() {
        var parser = H264Parser()
        _ = parser.parse(Data(four + sps + four + pps + four + idr))
        let changedSPS = parser.parse(Data(four + sps2 + four + pps + four + idr))
        #expect(changedSPS.newParameterSets == ParameterSets(sps: Data(sps2), pps: Data(pps)))
        let changedPPS = parser.parse(Data(four + sps2 + four + pps2 + four + idr))
        #expect(changedPPS.newParameterSets == ParameterSets(sps: Data(sps2), pps: Data(pps2)))
    }

    @Test func aHalfPairIsNeverAFormat() {
        var parser = H264Parser()
        let spsOnly = parser.parse(Data(four + sps + four + idr))
        #expect(spsOnly.newParameterSets == nil)
        #expect(parser.parameterSets == nil)

        _ = parser.parse(Data(four + sps + four + pps + four + idr))
        let lone = parser.parse(Data(four + sps2 + four + slice))
        #expect(lone.newParameterSets == nil)
        #expect(parser.parameterSets == ParameterSets(sps: Data(sps), pps: Data(pps)))
    }

    @Test func onlyValidSliceUnitsAreDecoded() {
        var parser = H264Parser()
        // Type 21, a 3D extension slice.
        let extensionSlice = parser.parse(Data(four + [0x75, 0x88]))
        #expect(extensionSlice.sample.isEmpty)
        #expect(!extensionSlice.isIDR)
        // Forbidden bit set.
        let forbidden = parser.parse(Data(four + [0xE5, 0x88] + four + slice))
        #expect(forbidden.sample == avcc(slice))
        #expect(!forbidden.isIDR)
        #expect(parser.parse(Data(four + idr + four + slice)).isIDR)
        let long = [UInt8(0x41)] + [UInt8](repeating: 0x9A, count: 299)
        #expect(parser.parse(Data(four + long)).sample.prefix(4) == Data([0, 0, 0x01, 0x2C]))
    }

    @Test func slicesBeforeAnyParameterSetsHaveNoFormat() {
        var parser = H264Parser()
        let unit = parser.parse(Data(four + slice))
        #expect(unit.sample == avcc(slice))
        #expect(unit.newParameterSets == nil)
        #expect(parser.parameterSets == nil)
    }
}
