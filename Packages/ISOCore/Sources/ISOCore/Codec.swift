import Foundation

public enum Codec: Hashable, Codable, Sendable {
    case proResProxy
    case proResLT
    case proRes422
    case proResHQ
    case proRes4444
    case longGOP(LongGOPSettings)

    public var displayName: String {
        switch self {
        case .proResProxy: "ProRes 422 Proxy"
        case .proResLT: "ProRes 422 LT"
        case .proRes422: "ProRes 422"
        case .proResHQ: "ProRes 422 HQ"
        case .proRes4444: "ProRes 4444"
        case .longGOP(let settings): settings.summary
        }
    }

    public var isProRes: Bool {
        switch self {
        case .proResProxy, .proResLT, .proRes422, .proResHQ, .proRes4444: true
        case .longGOP: false
        }
    }

    /// Every frame decodable on its own. Replay cueing and jog depend on this.
    public var isIntraOnly: Bool { isProRes }

    /// What to ask the card for. H.264 here is always 8-bit 4:2:0, so 10-bit capture only costs memory and a
    /// conversion. ProRes, every HEVC path and x265 encode 10-bit, so they keep v210.
    public var sourcePixelLayout: PixelLayout {
        if case .longGOP(let settings) = self, settings.encoder.family == .h264 { return .uyvy422 }
        return .v210
    }

    /// Apple's published target for 1920x1080 at 29.97, scaled by pixel rate for other formats.
    private var proResMegabitsAtHD2997: Double? {
        switch self {
        case .proResProxy: 45
        case .proResLT: 102
        case .proRes422: 147
        case .proResHQ: 220
        case .proRes4444: 330
        case .longGOP: nil
        }
    }

    /// Nil for constant quality with no cap, where the rate depends entirely on the picture.
    public func estimatedVideoBytesPerSecond(for format: VideoFormat) -> Double? {
        if let base = proResMegabitsAtHD2997 {
            let pixelRate = Double(format.width * format.height) * format.frameRate.doubleValue
            let referencePixelRate = 1920.0 * 1080.0 * 30000.0 / 1001.0
            return base * 1_000_000 / 8 * pixelRate / referencePixelRate
        }
        if case .longGOP(let settings) = self {
            return settings.rateControl.worstCaseKilobitsPerSecond.map { Double($0) * 1000 / 8 }
        }
        return nil
    }
}

public struct AudioFormat: Hashable, Codable, Sendable {
    public static let sampleRate = 48_000

    public var channels: Int

    public init(channels: Int) {
        self.channels = channels
    }

    /// Stored as 24-bit PCM regardless of the 32-bit words delivered by the card.
    public var storedBytesPerSecond: Double { Double(Self.sampleRate * 3 * channels) }

    /// Capture transport: 32-bit little-endian words.
    public var captureBytesPerSecond: Double { Double(Self.sampleRate * 4 * channels) }
}

public enum StorageEstimate {
    public static func bytesPerHour(format: VideoFormat, codec: Codec, audio: AudioFormat?) -> Double? {
        guard let video = codec.estimatedVideoBytesPerSecond(for: format) else { return nil }
        return (video + (audio?.storedBytesPerSecond ?? 0)) * 3600
    }

    /// Recording time until `freeBytes` is consumed by the given per-hour data rates.
    public static func hoursRemaining(freeBytes: Double, bytesPerHour rates: [Double]) -> Double? {
        let total = rates.reduce(0, +)
        return total > 0 ? freeBytes / total : nil
    }
}
