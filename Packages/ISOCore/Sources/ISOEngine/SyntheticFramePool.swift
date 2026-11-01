import Foundation
import ISOCore

/// Pre-rendered frames with temporal grain. Flat bars compress to almost nothing, which makes the encoder
/// and disk look far less loaded than a real camera would. Sources can share one pool, since it is read-only.
public final class SyntheticFramePool: @unchecked Sendable {
    public let format: VideoFormat
    public let count: Int
    private let storage: UnsafeMutableRawPointer

    public init(format: VideoFormat, count: Int = 16, grain: UInt32 = 48) {
        precondition(format.pixelLayout == .v210, "Grain is implemented for v210")
        self.format = format
        self.count = count
        storage = UnsafeMutableRawPointer.allocate(byteCount: format.frameBytes * count, alignment: 64)

        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        func grained(_ value: UInt32, _ noise: UInt32) -> UInt32 {
            min(940, max(64, value + (noise & (grain * 2 - 1)) - grain))
        }

        for index in 0..<count {
            let frame = storage.advanced(by: index * format.frameBytes)
            SyntheticFrame.fill(UnsafeMutableRawBufferPointer(start: frame, count: format.frameBytes), format: format, frameNumber: UInt64(index) * 40)
            let words = frame.assumingMemoryBound(to: UInt32.self)
            for word in 0..<(format.frameBytes / 4) {
                let noise = next()
                let value = words[word]
                let a = grained(value & 0x3FF, UInt32(truncatingIfNeeded: noise))
                let b = grained((value >> 10) & 0x3FF, UInt32(truncatingIfNeeded: noise >> 16))
                let c = grained((value >> 20) & 0x3FF, UInt32(truncatingIfNeeded: noise >> 32))
                words[word] = a | b << 10 | c << 20
            }
        }
    }

    deinit {
        storage.deallocate()
    }

    func frame(_ number: UInt64) -> UnsafeRawPointer {
        UnsafeRawPointer(storage.advanced(by: Int(number % UInt64(count)) * format.frameBytes))
    }
}
