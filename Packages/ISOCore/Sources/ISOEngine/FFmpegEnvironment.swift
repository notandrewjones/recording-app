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
        /// Standard output only. Warnings must never be read as an answer: ffprobe's warning about a
        /// cut-off last frame used to be parsed as the frame count, so most crashed segments failed to finalize.
        var output: String
        var errorOutput: String
        /// Both streams, for messages shown to a person.
        var combinedOutput: String { errorOutput.isEmpty ? output : output + errorOutput }
    }

    /// Runs a short-lived tool to completion, draining both pipes as output arrives so neither can wedge it.
    static func run(_ path: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            errorOutput: String(decoding: errData, as: UTF8.self)
        )
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

    public struct ProbeFailure: Error, CustomStringConvertible {
        public var description: String
    }

    /// Throws `ProbeFailure` with ffprobe's own message when the file cannot be read or counted.
    public static func videoFrameCount(_ path: String, environment: FFmpegEnvironment) throws -> Int {
        let result = try ProcessRunner.run(environment.ffprobePath, [
            "-v", "error", "-count_packets", "-select_streams", "v",
            "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", path,
        ])
        let token = result.output.split(whereSeparator: { $0 == "," || $0.isNewline }).first.map(String.init) ?? ""
        guard result.status == 0, let count = Int(token.trimmingCharacters(in: .whitespaces)) else {
            let message = result.errorOutput.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no output"
            throw ProbeFailure(description: "ffprobe exit \(result.status): \(message)")
        }
        return count
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
