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

        let encoder = videoEncoder(config)
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
    public static func finalizeArguments(input: String, output: String, startTimecode: Timecode) -> [String] {
        [
            "-hide_banner", "-loglevel", "warning", "-nostats", "-y",
            "-i", input,
            "-map", "0:v", "-map", "0:a?",
            "-c", "copy",
            "-timecode", startTimecode.string,
            "-movflags", "+faststart",
            output,
        ]
    }

    private static let noProbeArguments = ["-fflags", "+nobuffer", "-probesize", "32", "-analyzeduration", "0"]

    private static func validate(socketPath: String) throws {
        if socketPath.utf8.count > maxSocketPathBytes {
            throw FFmpegCommandError.socketPathTooLong(socketPath)
        }
    }

    private static func videoInputArguments(_ format: VideoFormat) -> [String] {
        let size = ["-video_size", "\(format.width)x\(format.height)", "-framerate", format.frameRate.ffmpegString]
        switch format.pixelLayout {
        case .v210: return ["-f", "v210"] + size
        case .uyvy422: return ["-f", "rawvideo", "-pixel_format", "uyvy422"] + size
        }
    }

    private static func videoEncoder(_ config: RecorderConfiguration) -> (arguments: [String], pixelFormat: String) {
        switch config.codec {
        case .h264(let rate):
            return (["-c:v", "h264_videotoolbox", "-b:v", "\(rate)M", "-realtime", "1"], "nv12")
        case .hevc(let rate):
            return (["-c:v", "hevc_videotoolbox", "-b:v", "\(rate)M", "-realtime", "1", "-tag:v", "hvc1"], "p010le")
        case .proResProxy, .proResLT, .proRes422, .proResHQ, .proRes4444:
            return config.allowSoftwareProRes ? softwareProRes(config.codec) : hardwareProRes(config.codec)
        }
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
