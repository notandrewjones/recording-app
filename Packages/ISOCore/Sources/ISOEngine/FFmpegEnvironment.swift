import Foundation

public enum FFmpegEnvironmentError: Error, Equatable, CustomStringConvertible {
    case notFound
    case missingHardwareProRes(String)

    public var description: String {
        switch self {
        case .notFound: "ffmpeg was not found. Install it with `brew install ffmpeg` or set its path."
        case .missingHardwareProRes(let path): "\(path) has no prores_videotoolbox encoder."
        }
    }
}

/// Paths to the ffmpeg tools, checked for the encoder recording depends on.
public struct FFmpegEnvironment: Hashable, Sendable {
    public var ffmpegPath: String
    public var ffprobePath: String

    public init(ffmpegPath: String, ffprobePath: String) {
        self.ffmpegPath = ffmpegPath
        self.ffprobePath = ffprobePath
    }

    public static func locate(preferredPath: String? = nil) throws -> FFmpegEnvironment {
        let candidates = [preferredPath, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let ffmpeg = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw FFmpegEnvironmentError.notFound
        }
        let directory = (ffmpeg as NSString).deletingLastPathComponent
        let environment = FFmpegEnvironment(ffmpegPath: ffmpeg, ffprobePath: (directory as NSString).appendingPathComponent("ffprobe"))
        let encoders = try ProcessRunner.run(ffmpeg, ["-hide_banner", "-encoders"]).output
        guard encoders.contains("prores_videotoolbox") else {
            throw FFmpegEnvironmentError.missingHardwareProRes(ffmpeg)
        }
        return environment
    }
}

enum ProcessRunner {
    struct Result {
        var status: Int32
        var output: String
    }

    /// Runs a short-lived tool to completion, draining output as it arrives so a full pipe cannot wedge it.
    static func run(_ path: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

public enum MediaProbe {
    public struct Info: Hashable, Sendable {
        public var videoFrames: Int
        public var audioPackets: Int
        public var audioChannels: Int
        public var timecode: String?
        public var width: Int
        public var height: Int
        public var codecName: String
        public var fieldOrder: String
    }

    public static func videoFrameCount(_ path: String, environment: FFmpegEnvironment) throws -> Int {
        let result = try ProcessRunner.run(environment.ffprobePath, [
            "-v", "error", "-count_packets", "-select_streams", "v",
            "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", path,
        ])
        return Int(result.output.split(whereSeparator: { $0 == "," || $0.isNewline }).first ?? "") ?? 0
    }

    public static func info(_ path: String, environment: FFmpegEnvironment) throws -> Info {
        let result = try ProcessRunner.run(environment.ffprobePath, [
            "-v", "error", "-count_packets", "-print_format", "json",
            "-show_entries", "stream=codec_type,codec_name,nb_read_packets,channels,width,height,field_order:stream_tags=timecode", path,
        ])
        guard let object = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              let streams = object["streams"] as? [[String: Any]] else { return .init(videoFrames: 0, audioPackets: 0, audioChannels: 0, timecode: nil, width: 0, height: 0, codecName: "", fieldOrder: "") }
        let video = streams.first { $0["codec_type"] as? String == "video" }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        func count(_ stream: [String: Any]?) -> Int { Int(stream?["nb_read_packets"] as? String ?? "") ?? 0 }
        let tags = video?["tags"] as? [String: Any]
        return Info(
            videoFrames: count(video),
            audioPackets: count(audio),
            audioChannels: audio?["channels"] as? Int ?? 0,
            timecode: tags?["timecode"] as? String,
            width: video?["width"] as? Int ?? 0,
            height: video?["height"] as? Int ?? 0,
            codecName: video?["codec_name"] as? String ?? "",
            fieldOrder: video?["field_order"] as? String ?? ""
        )
    }
}
