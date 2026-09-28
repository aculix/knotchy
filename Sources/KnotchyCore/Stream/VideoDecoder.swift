import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class VideoDecoder {
    typealias Output = @Sendable (DecodedFrame?, OSStatus) -> Void

    private let session: VTDecompressionSession
    private let format: CMVideoFormatDescription
    private let output: Output

    init?(parameterSets: ParameterSets, output: @escaping Output) {
        var description: CMFormatDescription?
        let sps = [UInt8](parameterSets.sps)
        let pps = [UInt8](parameterSets.pps)
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return nil }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
        var created: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created)
        guard sessionStatus == noErr, let created else { return nil }
        session = created
        format = description
        self.output = output
    }

    deinit {
        VTDecompressionSessionInvalidate(session)
    }

    func decode(_ sample: Data) {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: sample.count, flags: 0, blockBufferOut: &block) == noErr, let block
        else { return output(nil, -1) }
        sample.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: sample.count)
        }
        var sampleBuffer: CMSampleBuffer?
        var size = sample.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer
        else { return output(nil, -1) }
        let output = self.output
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [],
                                                       infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image {
                output(DecodedFrame(image), noErr)
            } else if status != noErr {
                output(nil, status)
            }
        }
        if status != noErr { output(nil, status) }
    }
}
