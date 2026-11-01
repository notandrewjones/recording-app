import Foundation

/// One captured frame. File frame N in a segment is index record N, because the capture writer
/// fills every drop with a repeat frame, so frame count stays a valid timestamp.
public struct FrameIndexRecord: Hashable, Sendable {
    public struct Flags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// The source frame was missing and the previous frame was repeated.
        public static let repeated = Flags(rawValue: 1 << 0)
        /// Timecode was read from the signal (RP188/VITC) rather than derived from time of day.
        public static let embeddedTimecode = Flags(rawValue: 1 << 1)
        /// The card flagged no valid signal on this frame.
        public static let noSignal = Flags(rawValue: 1 << 2)
    }

    public var frameNumber: UInt64
    /// Monotonic host time in nanoseconds. This is the shared timeline across unsynchronised sources.
    public var hostTimeNanos: UInt64
    /// DeckLink stream time, in the timescale from the index header.
    public var streamTime: Int64
    public var timecodeFrames: UInt32
    public var flags: Flags

    public init(frameNumber: UInt64, hostTimeNanos: UInt64, streamTime: Int64, timecodeFrames: UInt32, flags: Flags) {
        self.frameNumber = frameNumber
        self.hostTimeNanos = hostTimeNanos
        self.streamTime = streamTime
        self.timecodeFrames = timecodeFrames
        self.flags = flags
    }
}

/// Fixed-width little-endian `.idx` format. Fixed records make it append-only, seekable by frame
/// number, and safe to read while it grows: a torn tail is at most one partial record.
public enum FrameIndexFile {
    public static let magic: [UInt8] = Array("ISOIDX01".utf8)
    public static let headerSize = 32
    public static let recordSize = 32

    public enum ReadError: Error, Equatable, Sendable {
        case truncatedHeader
        case badMagic
    }

    public struct Header: Hashable, Sendable {
        public var frameRate: Rational
        public var streamTimescale: Int64

        public init(frameRate: Rational, streamTimescale: Int64) {
            self.frameRate = frameRate
            self.streamTimescale = streamTimescale
        }
    }

    public static func encode(_ header: Header) -> Data {
        var data = Data(magic)
        data.appendLittleEndian(UInt64(header.frameRate.numerator))
        data.appendLittleEndian(UInt32(header.frameRate.denominator))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt64(header.streamTimescale))
        return data
    }

    public static func encode(_ record: FrameIndexRecord) -> Data {
        var data = Data(capacity: recordSize)
        data.appendLittleEndian(record.frameNumber)
        data.appendLittleEndian(record.hostTimeNanos)
        data.appendLittleEndian(UInt64(bitPattern: record.streamTime))
        data.appendLittleEndian(record.timecodeFrames)
        data.appendLittleEndian(record.flags.rawValue)
        return data
    }

    public static func decodeHeader(_ data: Data) throws -> Header {
        guard data.count >= headerSize else { throw ReadError.truncatedHeader }
        let bytes = [UInt8](data.prefix(headerSize))
        guard Array(bytes[0..<8]) == magic else { throw ReadError.badMagic }
        return Header(
            frameRate: Rational(Int64(bytes.littleEndian(UInt64.self, at: 8)), Int64(bytes.littleEndian(UInt32.self, at: 16))),
            streamTimescale: Int64(bytes.littleEndian(UInt64.self, at: 24))
        )
    }

    /// Decodes all whole records after the header and ignores a partial trailing record.
    public static func decodeRecords(_ data: Data) -> [FrameIndexRecord] {
        guard data.count > headerSize else { return [] }
        let bytes = [UInt8](data)
        let count = (bytes.count - headerSize) / recordSize
        return (0..<count).map { i in
            let base = headerSize + i * recordSize
            return FrameIndexRecord(
                frameNumber: bytes.littleEndian(UInt64.self, at: base),
                hostTimeNanos: bytes.littleEndian(UInt64.self, at: base + 8),
                streamTime: Int64(bitPattern: bytes.littleEndian(UInt64.self, at: base + 16)),
                timecodeFrames: bytes.littleEndian(UInt32.self, at: base + 24),
                flags: FrameIndexRecord.Flags(rawValue: bytes.littleEndian(UInt32.self, at: base + 28))
            )
        }
    }
}

/// Finds the frame nearest a moment on the shared host-time timeline. Records must be in capture order.
public enum FrameLookup {
    public static func nearestFrame(in records: [FrameIndexRecord], hostTimeNanos target: UInt64) -> FrameIndexRecord? {
        guard !records.isEmpty else { return nil }
        var low = 0
        var high = records.count - 1
        while low < high {
            let mid = (low + high) / 2
            if records[mid].hostTimeNanos < target { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return records[0] }
        let after = records[low]
        let before = records[low - 1]
        let distanceAfter = after.hostTimeNanos > target ? after.hostTimeNanos - target : target - after.hostTimeNanos
        let distanceBefore = target > before.hostTimeNanos ? target - before.hostTimeNanos : before.hostTimeNanos - target
        return distanceBefore <= distanceAfter ? before : after
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private extension [UInt8] {
    func littleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for i in 0..<(T.bitWidth / 8) {
            value |= T(truncatingIfNeeded: self[offset + i]) << (i * 8)
        }
        return value
    }
}
