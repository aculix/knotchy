/// Tells a blank frame from one with page content.
public enum FrameSampler {
    public static let grid = 48
    public static let maxDimension = 1 << 15
    public static let maxBytesPerRow = 1 << 20

    /// Malformed input counts as uniform so it can never pose as content; the caps prevent overflow.
    public static func isUniform(_ pixels: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> Bool {
        guard (1...maxDimension).contains(width), (1...maxDimension).contains(height),
              bytesPerRow >= width * 4, bytesPerRow <= maxBytesPerRow,
              pixels.count >= (height - 1) * bytesPerRow + width * 4
        else { return true }
        let first = pixels.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        for gy in 0..<grid {
            for gx in 0..<grid {
                let offset = (gy * height / grid) * bytesPerRow + (gx * width / grid) * 4
                if pixels.loadUnaligned(fromByteOffset: offset, as: UInt32.self) != first { return false }
            }
        }
        return true
    }
}
