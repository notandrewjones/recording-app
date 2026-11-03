import Darwin
import Foundation
import ISOCore

/// Appends `health.jsonl`, one line per sample, so a crash keeps everything up to the last line.
final class HealthLog {
    private let path: String
    private let start = DispatchTime.now().uptimeNanoseconds
    private let metrics = SystemMetrics()
    private let encoder = JSONEncoder()

    init(sessionDirectory: String) {
        path = (sessionDirectory as NSString).appendingPathComponent("health.jsonl")
        FileManager.default.createFile(atPath: path, contents: nil)
        _ = metrics.sample()
    }

    func record(recorders: [InputRecorder], freeBytes: Int64, writeBytesPerSecond: Double) {
        let statuses = recorders.map { ($0.id, $0.status()) }
        let sample = metrics.sample()
        let health = HealthSample(
            seconds: HostTime.seconds(from: start, to: DispatchTime.now().uptimeNanoseconds),
            cpu: sample.cpuUsage,
            memoryPressure: sample.memoryPressure.rawValue,
            memoryUsedBytes: sample.memoryUsedBytes,
            appResidentBytes: Self.residentBytes([getpid()]),
            ffmpegResidentBytes: Self.residentBytes(statuses.compactMap(\.1.ffmpegProcessIdentifier)),
            freeBytes: freeBytes,
            writeBytesPerSecond: writeBytesPerSecond,
            inputs: statuses.map { id, status in
                HealthSample.Input(id: id, ringFill: status.ringFill, frames: status.totalFrames, repeatedFrames: status.repeatedFrames, restarts: status.restarts)
            }
        )
        guard var line = try? encoder.encode(health) else { return }
        line.append(0x0A)
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private static func residentBytes(_ processes: [Int32]) -> UInt64 {
        guard !processes.isEmpty else { return 0 }
        let list = processes.map(String.init).joined(separator: ",")
        guard let result = try? ProcessRunner.run("/bin/ps", ["-o", "rss=", "-p", list]) else { return 0 }
        let kilobytes = result.output.split(whereSeparator: \.isWhitespace).compactMap { UInt64($0) }
        return kilobytes.reduce(0, +) * 1024
    }
}

public enum SessionAnalysis {
    /// Builds the pass or fail report from what the session folder holds.
    public static func report(directory: String) throws -> SessionReport {
        guard let manifest = SessionRecovery.load(directory: directory) else { throw CocoaError(.fileReadCorruptFile) }
        return SessionReport(manifest: manifest, health: health(directory: directory), timings: timings(manifest, directory: directory))
    }

    private static func health(directory: String) -> [HealthSample] {
        let path = (directory as NSString).appendingPathComponent("health.jsonl")
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let decoder = JSONDecoder()
        // A crash can leave a partial last line, which is skipped.
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(HealthSample.self, from: Data($0)) }
    }

    private static func timings(_ manifest: SessionManifest, directory: String) -> [SegmentTiming] {
        manifest.inputs.flatMap { input in
            input.segments.compactMap { segment -> SegmentTiming? in
                let path = (directory as NSString).appendingPathComponent(segment.indexFile)
                guard let records = endRecords(path), records.first.frameNumber == 0 else { return nil }
                return SegmentTiming(
                    inputLabel: input.label,
                    number: segment.number,
                    records: records.count,
                    firstHostNanos: records.first.hostTimeNanos,
                    lastHostNanos: records.last.hostTimeNanos,
                    frameRate: segment.format.frameRate,
                    trailingRepeats: records.trailingRepeats
                )
            }
        }
    }

    /// Reads only the ends of the index, which stays quick on a long recording. `last` is the last real frame.
    private static func endRecords(_ path: String) -> (first: FrameIndexRecord, last: FrameIndexRecord, count: Int, trailingRepeats: Int)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let header = UInt64(FrameIndexFile.headerSize)
        let recordSize = UInt64(FrameIndexFile.recordSize)
        guard size >= header + recordSize else { return nil }
        let count = (size - header) / recordSize

        func record(at index: UInt64) -> FrameIndexRecord? {
            try? handle.seek(toOffset: header + index * recordSize)
            guard let data = try? handle.read(upToCount: FrameIndexFile.recordSize) else { return nil }
            return FrameIndexFile.decodeRecords(Data(count: FrameIndexFile.headerSize) + data).first
        }
        guard let first = record(at: 0) else { return nil }
        var position = count - 1
        while true {
            guard let last = record(at: position) else { return nil }
            if !last.flags.contains(.repeated) || position == 0 {
                return (first, last, Int(count), Int(count - 1 - position))
            }
            position -= 1
        }
    }
}

/// A zip that can be sent to someone debugging a session. It holds logs and metadata, never media.
public enum DiagnosticsBundle {
    /// `settings` is any extra context the caller holds, such as the app's output settings.
    /// The result contains file paths from this Mac, so check it before sharing it publicly.
    @discardableResult
    public static func write(sessionDirectory: String, environment: FFmpegEnvironment?, settings: String? = nil, destinationDirectory: String) throws -> String {
        let fileManager = FileManager.default
        let name = "diagnostics-\((sessionDirectory as NSString).lastPathComponent)"
        let work = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(name)-\(UUID().uuidString)")
        let folder = (work as NSString).appendingPathComponent(name)
        try fileManager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(atPath: work) }

        for file in ["session.json", "health.jsonl"] {
            let source = (sessionDirectory as NSString).appendingPathComponent(file)
            if fileManager.fileExists(atPath: source) {
                try fileManager.copyItem(atPath: source, toPath: (folder as NSString).appendingPathComponent(file))
            }
        }

        let logs = (folder as NSString).appendingPathComponent("ffmpeg-logs")
        try fileManager.createDirectory(atPath: logs, withIntermediateDirectories: true)
        for relative in fileManager.subpaths(atPath: sessionDirectory) ?? [] where relative.hasSuffix(".log") {
            let destination = (logs as NSString).appendingPathComponent(relative.replacingOccurrences(of: "/", with: "_"))
            try fileManager.copyItem(atPath: (sessionDirectory as NSString).appendingPathComponent(relative), toPath: destination)
        }

        if let report = try? SessionAnalysis.report(directory: sessionDirectory) {
            try report.text.write(toFile: (folder as NSString).appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        }
        try systemDescription(environment: environment, sessionDirectory: sessionDirectory)
            .write(toFile: (folder as NSString).appendingPathComponent("system.txt"), atomically: true, encoding: .utf8)
        if let settings {
            try settings.write(toFile: (folder as NSString).appendingPathComponent("output-settings.json"), atomically: true, encoding: .utf8)
        }

        try fileManager.createDirectory(atPath: destinationDirectory, withIntermediateDirectories: true)
        let archive = (destinationDirectory as NSString).appendingPathComponent("\(name).zip")
        try? fileManager.removeItem(atPath: archive)
        let result = try ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", folder, archive])
        guard result.status == 0 else { throw CocoaError(.fileWriteUnknown) }
        return archive
    }

    private static func systemDescription(environment: FFmpegEnvironment?, sessionDirectory: String) -> String {
        func command(_ path: String, _ arguments: [String]) -> String {
            ((try? ProcessRunner.run(path, arguments))?.output ?? "unavailable").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var sections = [
            "macOS:\n\(command("/usr/bin/sw_vers", []))",
            "Chip: \(command("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]))",
            "Memory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB",
            "Free on recording drive: \(SystemMetrics.freeBytes(at: sessionDirectory) / 1_000_000_000) GB",
            "Desktop Video framework: \(command("/usr/libexec/PlistBuddy", ["-c", "Print CFBundleShortVersionString", "/Library/Frameworks/DeckLinkAPI.framework/Resources/Info.plist"]))",
        ]
        if let environment {
            let version = command(environment.ffmpegPath, ["-hide_banner", "-version"]).split(separator: "\n").first.map(String.init) ?? "unknown"
            sections.append("ffmpeg: \(environment.ffmpegPath)\n\(version)")
        } else {
            sections.append("ffmpeg: not found")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }
}
