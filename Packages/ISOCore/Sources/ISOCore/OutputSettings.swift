import Foundation

/// What one input records. The default applies to every input without its own override.
public struct OutputSettings: Hashable, Codable, Sendable {
    public var codec: Codec
    public var audioChannels: Int

    public init(codec: Codec = .proResLT, audioChannels: Int = 16) {
        self.codec = codec
        self.audioChannels = audioChannels
    }
}

public extension LongGOPSettings {
    /// A starting point for a family: hardware, since software encoders rarely hold live HD.
    static func defaultSettings(for family: VideoFamily) -> LongGOPSettings {
        LongGOPSettings(encoder: family == .hevc ? .hevcHardware : .h264Hardware, rateControl: .abr(kbps: 30_000))
    }

    /// The same settings moved to another encoder, keeping what still applies.
    func switched(to newEncoder: LongGOPEncoder) -> LongGOPSettings {
        var result = self
        result.encoder = newEncoder
        if newEncoder != .hevcHardware { result.chroma422 = false }
        if !newEncoder.supportedModes.contains(rateControl.mode) {
            result.rateControl = rateControl.switched(to: .abr, encoder: newEncoder)
        } else if case .constantQuality(_, let maximum) = rateControl, newEncoder.usesCRF != encoder.usesCRF {
            // CRF and Apple's quality run in opposite directions, so the old number means nothing here.
            result.rateControl = .constantQuality(value: newEncoder.defaultQuality, maximumKbps: maximum)
        }
        return result
    }
}

public extension RateControl {
    var bitrateKbps: Int? {
        switch self {
        case .cbr(let rate), .abr(let rate), .vbr(let rate, _): rate
        case .constantQuality: nil
        }
    }

    /// Changes mode, carrying the bitrate across so that flipping between modes loses nothing.
    func switched(to mode: RateControlMode, encoder: LongGOPEncoder) -> RateControl {
        let rate = bitrateKbps ?? worstCaseKilobitsPerSecond ?? 30_000
        switch mode {
        case .cbr: return .cbr(kbps: rate)
        case .abr: return .abr(kbps: rate)
        case .vbr: return .vbr(kbps: rate, maximumKbps: rate * 3 / 2)
        case .constantQuality: return .constantQuality(value: encoder.defaultQuality, maximumKbps: rate * 2)
        }
    }
}

/// Warns about a recording plan that is known to fail. The limits were measured on an M2 Pro with
/// grain-heavy 1080p59.94, and they belong to the media engine, so a low CPU reading does not mean there is room.
public enum EncoderCapacity {
    /// 1080p59.94-equivalent frames per second that recorded with no repeats.
    private static let hardwareLimits: [(name: String, framesPerSecond: Double)] = [
        ("ProRes", 480),
        ("HEVC hardware", 300),
        ("H.264 hardware", 180),
    ]

    public static func warnings(for inputs: [(codec: Codec, format: VideoFormat)]) -> [String] {
        var load = [0.0, 0.0, 0.0]
        var softwareStreams = 0
        var warnings: [String] = []

        for input in inputs {
            let scale = Double(input.format.width * input.format.height) / (1920 * 1080)
            let frames = input.format.frameRate.doubleValue * scale
            switch input.codec {
            case .longGOP(let settings):
                switch settings.encoder {
                case .hevcHardware: load[1] += frames
                case .h264Hardware: load[2] += frames
                default:
                    softwareStreams += 1
                    if !settings.encoder.isRealTimeOnAppleSilicon {
                        warnings.append("\(settings.encoder.displayName) could not hold one 1080p59.94 stream in testing.")
                    }
                }
            default:
                load[0] += frames
            }
        }

        for (index, limit) in hardwareLimits.enumerated() where load[index] > limit.framesPerSecond {
            let streams = Int(limit.framesPerSecond / 59.94)
            warnings.append("\(limit.name): over the tested limit of \(streams) × 1080p59.94. Expect repeated frames.")
        }
        if softwareStreams > 2 {
            warnings.append("\(softwareStreams) software encoders share the CPU with everything else. Two x264 veryfast streams was the tested limit.")
        }
        return Array(Set(warnings)).sorted()
    }
}
