import Foundation

/// The top-level layout of a fragmented MOV: `ftyp`, `moov`, then `moof` + `mdat` pairs. A killed recorder
/// leaves the file cut wherever ffmpeg was writing. A cut inside an `mdat` still reads, but a cut inside a
/// `moof` makes ffprobe refuse the whole file, so salvage cuts back to the end of the last complete pair.
public enum FragmentedMovie {
    /// Reads one box header at `offset`, or nil when fewer than its header's bytes remain.
    public typealias HeaderReader = (_ offset: Int64, _ count: Int) -> Data?

    /// Byte length of the readable part: through the last complete `mdat`, or the last complete box before
    /// any fragment. Nil when the file does not start with complete `ftyp`/`moov` boxes.
    public static func readableLength(fileSize: Int64, read: HeaderReader) -> Int64? {
        var offset: Int64 = 0
        var safeEnd: Int64 = 0
        var sawMovie = false
        var fragmentOpen = false

        while offset + 8 <= fileSize, let header = read(offset, 8), header.count == 8 {
            var size = Int64(header.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: header.suffix(4), as: UTF8.self)
            if size == 1 {
                guard offset + 16 <= fileSize, let large = read(offset + 8, 8), large.count == 8 else { break }
                size = Int64(bitPattern: large.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            }
            // Size 0 means "to the end of the file", which a cut file cannot promise.
            guard size >= 8, offset + size <= fileSize else { break }

            switch type {
            case "moov":
                sawMovie = true
                safeEnd = offset + size
            case "moof":
                fragmentOpen = true
            case "mdat":
                if fragmentOpen || !sawMovie { safeEnd = offset + size }
                fragmentOpen = false
            default:
                if !fragmentOpen { safeEnd = offset + size }
            }
            offset += size
        }
        return sawMovie ? safeEnd : nil
    }

    /// `readableLength` for a file on disk.
    public static func readableLength(path: String) -> Int64? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        return readableLength(fileSize: Int64(size)) { offset, count in
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
            return try? handle.read(upToCount: count)
        }
    }
}
