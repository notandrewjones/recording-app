import Foundation

/// Pixel layouts the DeckLink SDK delivers and ffmpeg can ingest without an intermediate conversion in the app.
public enum PixelLayout: String, Codable, Sendable, CaseIterable {
    case uyvy422
    case v210

    public var bitDepth: Int {
        switch self {
        case .uyvy422: 8
        case .v210: 10
        }
    }

    public func rowBytes(width: Int) -> Int {
        switch self {
        case .uyvy422: width * 2
        // v210 packs 6 pixels into 16 bytes, and lines are padded to a 48-pixel (128-byte) boundary.
        case .v210: ((width + 47) / 48) * 128
        }
    }
}

public enum ScanMode: String, Codable, Sendable {
    case progressive
    case progressiveSegmented
    case interlacedTopFieldFirst
    case interlacedBottomFieldFirst

    public var isInterlaced: Bool {
        self == .interlacedTopFieldFirst || self == .interlacedBottomFieldFirst
    }
}

public struct VideoFormat: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int
    /// Frames per second. For interlaced formats this is the frame rate, not the field rate.
    public var frameRate: Rational
    public var scan: ScanMode
    public var pixelLayout: PixelLayout

    public init(width: Int, height: Int, frameRate: Rational, scan: ScanMode = .progressive, pixelLayout: PixelLayout = .v210) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.scan = scan
        self.pixelLayout = pixelLayout
    }

    public var rowBytes: Int { pixelLayout.rowBytes(width: width) }
    public var frameBytes: Int { rowBytes * height }
    public var bytesPerSecond: Double { Double(frameBytes) * frameRate.doubleValue }

    /// Engineering shorthand, e.g. `1080p59.94`, `1080i59.94`, `1080PsF23.98`, `2160p25`.
    public var displayName: String {
        let suffix: String
        let rate: Double
        switch scan {
        case .progressive:
            suffix = "p"
            rate = frameRate.doubleValue
        case .progressiveSegmented:
            suffix = "PsF"
            rate = frameRate.doubleValue
        case .interlacedTopFieldFirst, .interlacedBottomFieldFirst:
            suffix = "i"
            rate = frameRate.doubleValue * 2
        }
        return "\(height)\(suffix)\(Self.rateString(rate))"
    }

    private static func rateString(_ rate: Double) -> String {
        let rounded = (rate * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.2f", rounded)
    }
}

public extension VideoFormat {
    static let hd1080p5994 = VideoFormat(width: 1920, height: 1080, frameRate: Rational(60000, 1001))
    static let hd1080i5994 = VideoFormat(width: 1920, height: 1080, frameRate: Rational(30000, 1001), scan: .interlacedTopFieldFirst)
    static let hd1080p2997 = VideoFormat(width: 1920, height: 1080, frameRate: Rational(30000, 1001))
    static let uhd2160p5994 = VideoFormat(width: 3840, height: 2160, frameRate: Rational(60000, 1001))
}
