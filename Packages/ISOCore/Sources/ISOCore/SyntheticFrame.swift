import Foundation

/// Generates test frames for running the capture path without hardware.
/// Bars with a moving block, so preview tearing, latency and frame drops are visible.
public enum SyntheticFrame {
    /// 75% bars in 8-bit Rec.709 Y'CbCr: white, yellow, cyan, green, magenta, red, blue.
    private static let bars: [(y: UInt8, cb: UInt8, cr: UInt8)] = [
        (180, 128, 128), (168, 44, 136), (145, 147, 44), (133, 63, 52),
        (63, 193, 204), (51, 109, 212), (28, 212, 120),
    ]

    public static func movingBlockColumn(frameNumber: UInt64, width: Int, blockWidth: Int) -> Int {
        guard width > blockWidth else { return 0 }
        return Int(frameNumber % UInt64(width - blockWidth))
    }

    public static func fill(_ buffer: UnsafeMutableRawBufferPointer, format: VideoFormat, frameNumber: UInt64) {
        precondition(buffer.count >= format.frameBytes, "Synthetic frame buffer is too small")
        let base = buffer.baseAddress!
        let rowBytes = format.rowBytes
        let blockWidth = max(format.width / 16, 6) / 6 * 6
        let blockX = movingBlockColumn(frameNumber: frameNumber, width: format.width, blockWidth: blockWidth) / 6 * 6
        let blockTop = format.height / 3
        let blockBottom = blockTop * 2

        // Only two distinct rows exist, so render each once and copy. This keeps debug builds real-time.
        renderRow(base, format: format, block: nil)
        renderRow(base.advanced(by: blockTop * rowBytes), format: format, block: blockX..<(blockX + blockWidth))
        for line in 1..<format.height where line != blockTop {
            let source = (blockTop..<blockBottom).contains(line) ? blockTop : 0
            base.advanced(by: line * rowBytes).copyMemory(from: base.advanced(by: source * rowBytes), byteCount: rowBytes)
        }
    }

    private static func renderRow(_ row: UnsafeMutableRawPointer, format: VideoFormat, block: Range<Int>?) {
        let barWidth = format.width / bars.count

        func sample(_ x: Int) -> (y: UInt8, cb: UInt8, cr: UInt8) {
            if block?.contains(x) == true { return (235, 128, 128) }
            return bars[min(x / barWidth, bars.count - 1)]
        }

        switch format.pixelLayout {
        case .uyvy422:
            let bytes = row.assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: format.width & ~1, by: 2) {
                let s = sample(x)
                bytes[x * 2] = s.cb
                bytes[x * 2 + 1] = s.y
                bytes[x * 2 + 2] = s.cr
                bytes[x * 2 + 3] = s.y
            }
        case .v210:
            let words = row.assumingMemoryBound(to: UInt32.self)
            var word = 0
            for x in stride(from: 0, to: format.width - format.width % 6, by: 6) {
                let s = sample(x)
                let y = UInt32(s.y) << 2, cb = UInt32(s.cb) << 2, cr = UInt32(s.cr) << 2
                words[word] = (cb | y << 10 | cr << 20).littleEndian
                words[word + 1] = (y | cb << 10 | y << 20).littleEndian
                words[word + 2] = (cr | y << 10 | cb << 20).littleEndian
                words[word + 3] = (y | cr << 10 | y << 20).littleEndian
                word += 4
            }
        }
    }
}
