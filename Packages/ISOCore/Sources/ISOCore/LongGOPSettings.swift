import Foundation

public enum VideoFamily: String, Codable, Sendable, CaseIterable {
    case h264
    case hevc
}

/// The same encoder choices OBS lists on a Mac. Apple's use VideoToolbox, and x264 and x265 run on the CPU.
public enum LongGOPEncoder: String, Codable, Sendable, CaseIterable, Identifiable {
    case hevcHardware
    case hevcSoftware
    case x265
    case h264Hardware
    case h264Software
    case x264

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hevcHardware: "Apple VT HEVC Hardware"
        case .hevcSoftware: "Apple VT HEVC Software"
        case .x265: "x265 (software)"
        case .h264Hardware: "Apple VT H.264 Hardware"
        case .h264Software: "Apple VT H.264 Software"
        case .x264: "x264 (software)"
        }
    }

    public var family: VideoFamily {
        switch self {
        case .hevcHardware, .hevcSoftware, .x265: .hevc
        case .h264Hardware, .h264Software, .x264: .h264
        }
    }

    public var isHardware: Bool { self == .hevcHardware || self == .h264Hardware }
    public var isAppleSoftware: Bool { self == .hevcSoftware || self == .h264Software }
    public var usesCRF: Bool { self == .x264 || self == .x265 }

    /// CRF runs 0 to 51 with lower meaning better. Apple's quality runs 1 to 100 with higher meaning better.
    public var qualityRange: ClosedRange<Int> { usesCRF ? 0...51 : 1...100 }

    public var defaultQuality: Int { usesCRF ? 23 : 60 }

    public var supportedModes: [RateControlMode] {
        switch self {
        case .h264Software: [.abr]
        case .hevcSoftware: [.abr, .constantQuality]
        default: RateControlMode.allCases
        }
    }

    /// Software encoders that could not hold one 1080p59.94 stream on an M2 Pro.
    public var isRealTimeOnAppleSilicon: Bool { self != .hevcSoftware && self != .x265 }
}

public enum RateControlMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case cbr
    case abr
    case vbr
    case constantQuality

    public var id: String { rawValue }

    public func displayName(for encoder: LongGOPEncoder) -> String {
        switch self {
        case .cbr: "CBR"
        case .abr: "ABR"
        case .vbr: "VBR (capped)"
        case .constantQuality: encoder.usesCRF ? "CRF" : "Constant Quality"
        }
    }
}

public enum RateControl: Hashable, Codable, Sendable {
    case cbr(kbps: Int)
    case abr(kbps: Int)
    case vbr(kbps: Int, maximumKbps: Int)
    /// CRF on x264 and x265, or Apple's quality scale. An optional cap keeps storage bounded.
    case constantQuality(value: Int, maximumKbps: Int?)

    public var mode: RateControlMode {
        switch self {
        case .cbr: .cbr
        case .abr: .abr
        case .vbr: .vbr
        case .constantQuality: .constantQuality
        }
    }

    public var worstCaseKilobitsPerSecond: Int? {
        switch self {
        case .cbr(let rate), .abr(let rate): rate
        case .vbr(_, let maximum): maximum
        case .constantQuality(_, let maximum): maximum
        }
    }
}

public enum X26xPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case ultrafast
    case superfast
    case veryfast
    case faster
    case fast
    case medium

    public var id: String { rawValue }
}

public struct LongGOPSettings: Hashable, Codable, Sendable {
    public var encoder: LongGOPEncoder
    public var rateControl: RateControl
    public var keyframeSeconds: Double
    public var preset: X26xPreset
    /// 4:2:2 10-bit on Apple's HEVC hardware. Other encoders stay 4:2:0.
    public var chroma422: Bool

    public init(encoder: LongGOPEncoder, rateControl: RateControl, keyframeSeconds: Double = 1, preset: X26xPreset = .veryfast, chroma422: Bool = false) {
        self.encoder = encoder
        self.rateControl = rateControl
        self.keyframeSeconds = keyframeSeconds
        self.preset = preset
        self.chroma422 = chroma422
    }

    public var summary: String {
        let name: String
        switch rateControl {
        case .cbr(let rate): name = "CBR \(Self.megabits(rate)) Mb/s"
        case .abr(let rate): name = "ABR \(Self.megabits(rate)) Mb/s"
        case .vbr(let rate, let maximum): name = "VBR \(Self.megabits(rate))/\(Self.megabits(maximum)) Mb/s"
        case .constantQuality(let value, _): name = "\(encoder.usesCRF ? "CRF" : "Q") \(value)"
        }
        return "\(encoder.displayName) \(name)"
    }

    private static func megabits(_ kilobits: Int) -> String {
        let value = Double(kilobits) / 1000
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    func validate() throws {
        guard encoder.supportedModes.contains(rateControl.mode) else {
            throw FFmpegCommandError.unsupportedRateControl(encoder)
        }
        switch rateControl {
        case .cbr(let rate), .abr(let rate):
            guard rate > 0 else { throw FFmpegCommandError.invalidBitrate(rate) }
        case .vbr(let rate, let maximum):
            guard rate > 0, maximum >= rate else { throw FFmpegCommandError.invalidBitrate(rate) }
        case .constantQuality(let value, let maximum):
            guard encoder.qualityRange.contains(value) else { throw FFmpegCommandError.qualityOutOfRange(encoder, value) }
            if let maximum, maximum <= 0 { throw FFmpegCommandError.invalidBitrate(maximum) }
        }
    }
}
