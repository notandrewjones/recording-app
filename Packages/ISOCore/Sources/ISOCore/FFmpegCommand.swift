import Foundation

public struct RecorderConfiguration: Hashable, Sendable {
    public var format: VideoFormat
    public var codec: Codec
    public var audio: AudioFormat?
    /// Socket paths, each shorter than `FFmpegCommand.maxSocketPathBytes`.
    public var videoSocketPath: String
    public var audioSocketPath: String?
    public var startTimecode: Timecode
    public var outputPath: String
    public var fragmentMicroseconds: Int
    /// `prores_ks` could not hold one 1080p59.94 stream on an M2 Pro, so software is opt-in, never a silent fallback.
    public var allowSoftwareProRes: Bool

    public init(
        format: VideoFormat,
        codec: Codec,
        audio: AudioFormat?,
        videoSocketPath: String,
        audioSocketPath: String?,
        startTimecode: Timecode,
        outputPath: String,
        fragmentMicroseconds: Int = 500_000,
        allowSoftwareProRes: Bool = false
    ) {
        self.format = format
        self.codec = codec
        self.audio = audio
        self.videoSocketPath = videoSocketPath
        self.audioSocketPath = audioSocketPath
        self.startTimecode = startTimecode
        self.outputPath = outputPath
        self.fragmentMicroseconds = fragmentMicroseconds
        self.allowSoftwareProRes = allowSoftwareProRes
    }
}

public enum FFmpegCommandError: Error, Equatable, Sendable {
    case socketPathTooLong(String)
    case audioSocketMissing
    case unsupportedAudioChannelCount(Int)
    case unsupportedRateControl(LongGOPEncoder)
    case qualityOutOfRange(LongGOPEncoder, Int)
    case invalidBitrate(Int)
}

/// Builds ffmpeg argument lists. The rationale for each non-obvious flag is in docs/decisions.md.
public enum FFmpegCommand {
    /// `sun_path` is 104 bytes on macOS, including the terminator. Longer paths are silently truncated by ffmpeg.
    public static let maxSocketPathBytes = 103

    /// ffmpeg's demuxer has no `32c`/`64c` layout, and no target card exceeds 16 embedded channels.
    public static let supportedAudioChannelCounts = [2, 8, 16]

    public static func recordArguments(_ config: RecorderConfiguration) throws -> [String] {
        var args = ["-hide_banner", "-loglevel", "warning", "-nostats", "-y"]

        try validate(socketPath: config.videoSocketPath)
        args += noProbeArguments
        args += videoInputArguments(config.format)
        args += ["-listen", "1", "-i", "unix:\(config.videoSocketPath)"]

        if let audio = config.audio {
            guard let audioSocket = config.audioSocketPath else { throw FFmpegCommandError.audioSocketMissing }
            guard supportedAudioChannelCounts.contains(audio.channels) else {
                throw FFmpegCommandError.unsupportedAudioChannelCount(audio.channels)
            }
            try validate(socketPath: audioSocket)
            args += noProbeArguments
            args += ["-f", "s32le", "-ar", String(AudioFormat.sampleRate), "-ch_layout", "\(audio.channels)c"]
            args += ["-listen", "1", "-i", "unix:\(audioSocket)"]
            args += ["-map", "0:v", "-map", "1:a"]
        }

        let encoder = try videoEncoder(config)
        args += ["-vf", frameFilter(config.format, encoderPixelFormat: encoder.pixelFormat)]
        args += encoder.arguments
        if config.audio != nil {
            args += ["-c:a", "pcm_s24le"]
        }

        args += ["-timecode", config.startTimecode.string]
        args += ["-frag_duration", String(config.fragmentMicroseconds)]
        args += ["-movflags", "+empty_moov+default_base_moof+skip_trailer"]
        args += ["-f", "mov", config.outputPath]
        return args
    }

    /// Lossless remux of a fragmented segment to a standard MOV. Timecode must be passed again:
    /// a stream copy keeps the frame count but loses the drop-frame flag.
    public static func finalizeArguments(input: String, output: String, startTimecode: String) -> [String] {
        [
            "-hide_banner", "-loglevel", "warning", "-nostats", "-y",
            "-i", input,
            "-map", "0:v", "-map", "0:a?",
            "-c", "copy",
            "-timecode", startTimecode,
            "-movflags", "+faststart",
            output,
        ]
    }

    /// Without these, ffmpeg spends seconds probing a raw input before it opens the output.
    /// Do not add `-fflags +nobuffer`: it discards the first frame, which breaks frame N = index record N.
    private static let noProbeArguments = ["-probesize", "32", "-analyzeduration", "0"]

    private static func validate(socketPath: String) throws {
        if socketPath.utf8.count > maxSocketPathBytes {
            throw FFmpegCommandError.socketPathTooLong(socketPath)
        }
    }

    private static func videoInputArguments(_ format: VideoFormat) -> [String] {
        // One decoder thread: unpacking v210 is cheap, and the default frame threading doubled system load.
        let size = ["-threads", "1", "-video_size", "\(format.width)x\(format.height)", "-framerate", format.frameRate.ffmpegString]
        switch format.pixelLayout {
        case .v210: return ["-f", "v210"] + size
        case .uyvy422: return ["-f", "rawvideo", "-pixel_format", "uyvy422"] + size
        }
    }

    private static func videoEncoder(_ config: RecorderConfiguration) throws -> (arguments: [String], pixelFormat: String) {
        switch config.codec {
        case .longGOP(let settings):
            return try longGOPEncoder(settings, format: config.format)
        case .proResProxy, .proResLT, .proRes422, .proResHQ, .proRes4444:
            return config.allowSoftwareProRes ? softwareProRes(config.codec) : hardwareProRes(config.codec)
        }
    }

    private static func longGOPEncoder(_ settings: LongGOPSettings, format: VideoFormat) throws -> (arguments: [String], pixelFormat: String) {
        try settings.validate()
        let encoder = settings.encoder
        var arguments: [String]
        let pixelFormat: String

        // `prio_speed` is what lets five HEVC hardware streams hold 59.94. Without it they repeat frames.
        switch encoder {
        case .h264Hardware, .h264Software:
            arguments = ["-c:v", "h264_videotoolbox", "-realtime", "1", "-prio_speed", "1"]
            pixelFormat = "nv12"
        case .hevcHardware, .hevcSoftware:
            arguments = ["-c:v", "hevc_videotoolbox", "-realtime", "1", "-prio_speed", "1", "-tag:v", "hvc1"]
            if settings.chroma422 {
                arguments += ["-profile:v", "main42210"]
                pixelFormat = "p210le"
            } else {
                pixelFormat = "p010le"
            }
        case .x264:
            arguments = ["-c:v", "libx264", "-preset", settings.preset.rawValue]
            pixelFormat = "yuv420p"
        case .x265:
            arguments = ["-c:v", "libx265", "-preset", settings.preset.rawValue, "-tag:v", "hvc1"]
            pixelFormat = "yuv420p10le"
        }
        if encoder.isAppleSoftware {
            arguments += ["-require_sw", "1"]
        }

        let frames = max(1, Int((settings.keyframeSeconds * format.frameRate.doubleValue).rounded()))
        arguments += ["-g", String(frames), "-bf", "0"]
        arguments += rateControlArguments(settings)
        return (arguments, pixelFormat)
    }

    private static func rateControlArguments(_ settings: LongGOPSettings) -> [String] {
        let isX26x = settings.encoder == .x264 || settings.encoder == .x265
        let extraParameters = isX26x ? settings.encoder == .x264 ? "-x264-params" : "-x265-params" : ""
        var hrd = "log-level=warning"

        var arguments: [String]
        switch settings.rateControl {
        case .cbr(let rate):
            arguments = ["-b:v", "\(rate)k"]
            if isX26x {
                arguments += ["-minrate", "\(rate)k", "-maxrate", "\(rate)k", "-bufsize", "\(rate)k"]
                hrd = settings.encoder == .x264 ? "nal-hrd=cbr" : "log-level=warning:hrd=1:strict-cbr=1"
            } else {
                arguments += ["-constant_bit_rate", "1"]
            }
        case .abr(let rate):
            arguments = ["-b:v", "\(rate)k"]
        case .vbr(let rate, let maximum):
            arguments = ["-b:v", "\(rate)k", "-maxrate", "\(maximum)k", "-bufsize", "\(maximum)k"]
        case .constantQuality(let value, let maximum):
            arguments = isX26x ? ["-crf", String(value)] : ["-q:v", String(value)]
            if let maximum {
                arguments += ["-maxrate", "\(maximum)k", "-bufsize", "\(maximum)k"]
            }
        }
        if isX26x {
            // x264 reads log-level differently, and only the CBR flag is needed there.
            if settings.encoder == .x265 || hrd != "log-level=warning" {
                arguments += [extraParameters, hrd]
            }
        }
        return arguments
    }

    private static func hardwareProRes(_ codec: Codec) -> (arguments: [String], pixelFormat: String) {
        let profile: String
        switch codec {
        case .proResProxy: profile = "proxy"
        case .proResLT: profile = "lt"
        case .proRes422: profile = "standard"
        case .proRes4444: profile = "4444"
        default: profile = "hq"
        }
        let arguments = ["-c:v", "prores_videotoolbox", "-profile:v", profile, "-realtime", "1"]
        return (arguments, codec == .proRes4444 ? "p416le" : "p210le")
    }

    private static func softwareProRes(_ codec: Codec) -> (arguments: [String], pixelFormat: String) {
        let profile: Int
        switch codec {
        case .proResProxy: profile = 0
        case .proResLT: profile = 1
        case .proRes422: profile = 2
        case .proRes4444: profile = 4
        default: profile = 3
        }
        return (["-c:v", "prores_ks", "-profile:v", String(profile)], codec == .proRes4444 ? "yuv444p10le" : "yuv422p10le")
    }

    /// Field order and colour must be set on the frames: `prores_videotoolbox` ignores
    /// `-field_order` and `-colorspace`, which would tag 1080i as progressive with unknown colour.
    private static func frameFilter(_ format: VideoFormat, encoderPixelFormat: String) -> String {
        let fieldMode: String
        switch format.scan {
        case .progressive, .progressiveSegmented: fieldMode = "prog"
        case .interlacedTopFieldFirst: fieldMode = "tff"
        case .interlacedBottomFieldFirst: fieldMode = "bff"
        }
        let matrix = format.height >= 720 ? "bt709" : "smpte170m"
        return "setparams=field_mode=\(fieldMode):range=tv:colorspace=\(matrix):color_primaries=\(matrix):color_trc=bt709,format=\(encoderPixelFormat)"
    }
}
