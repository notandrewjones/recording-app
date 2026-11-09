import Darwin
import Foundation
import ISOCore
import Testing
@testable import ISOEngine

/// Crashed segments as a killed recorder really leaves them, finalized the way recovery at launch does it.
@Suite(.serialized) struct FinalizeSalvageTests {
    let environment = try! FFmpegEnvironment.locate()
    static let format = VideoFormat(width: 640, height: 360, frameRate: Rational(30, 1), pixelLayout: .uyvy422)

    final class Fixture {
        let root: String
        let layout: SessionLayout
        let segment: SessionManifest.SegmentRecord

        init(environment: FFmpegEnvironment, seconds: Int = 4) throws {
            root = (NSTemporaryDirectory() as NSString).appendingPathComponent("isorec-salvage-\(UUID().uuidString)")
            layout = SessionLayout(rootPath: root, sessionName: "salvage")
            try FileManager.default.createDirectory(atPath: layout.inputDirectory(inputLabel: "Cam"), withIntermediateDirectories: true)
            var record = SessionManifest.SegmentRecord(
                number: 1,
                workingFile: layout.relativePath(layout.workingSegmentPath(inputLabel: "Cam", segment: 1)),
                finalFile: layout.relativePath(layout.segmentPath(inputLabel: "Cam", segment: 1)),
                indexFile: layout.relativePath(layout.frameIndexPath(inputLabel: "Cam", segment: 1)),
                logFile: layout.relativePath(layout.logPath(inputLabel: "Cam", segment: 1)),
                format: FinalizeSalvageTests.format,
                codec: .longGOP(.defaultSettings(for: .h264)),
                audioChannels: 1,
                startTimecode: "00:00:00:00",
                timecodeIsEmbedded: false,
                startHostNanos: 1
            )
            record.state = .closed
            record.endReason = .recorderFailed
            record.frames = seconds * 30
            segment = record

            // The same container flags the recorder uses, so the fragments match a real working file.
            let result = try ProcessRunner.run(environment.ffmpegPath, [
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
                "-f", "lavfi", "-i", "sine=sample_rate=48000",
                "-t", "\(seconds)", "-map", "0:v", "-map", "1:a", "-vf", "format=nv12",
                "-c:v", "h264_videotoolbox", "-g", "30", "-bf", "0", "-b:v", "4000k", "-c:a", "pcm_s24le",
                "-timecode", "00:00:00:00", "-frag_duration", "500000",
                "-movflags", "+empty_moov+default_base_moof+skip_trailer", "-f", "mov", working,
            ])
            try #require(result.status == 0, "\(result.combinedOutput)")

            // The index runs ahead of the media after a crash, as frames handed to ffmpeg never reached the file.
            var index = FrameIndexFile.encode(FrameIndexFile.Header(frameRate: Self.rate, streamTimescale: 240_000))
            for frame in 0..<(seconds * 30 + 20) {
                index.append(FrameIndexFile.encode(FrameIndexRecord(frameNumber: UInt64(frame), hostTimeNanos: 1, streamTime: 0, timecodeFrames: UInt32(frame), flags: [])))
            }
            try index.write(to: URL(fileURLWithPath: layout.absolutePath(record.indexFile)))

            var manifest = SessionManifest(name: "salvage", createdAt: Date(), createdAtHostNanos: 1)
            var input = SessionManifest.InputRecord(id: "cam", label: "Cam")
            input.segments = [record]
            manifest.inputs = [input]
            _ = try SessionStore(layout: layout, manifest: manifest)
        }

        static let rate = Rational(30, 1)

        deinit {
            try? FileManager.default.removeItem(atPath: root)
        }

        var working: String { layout.absolutePath(segment.workingFile) }
        var final: String { layout.absolutePath(segment.finalFile) }

        struct Box {
            var type: String
            var offset: Int64
            var size: Int64
        }

        /// Top-level boxes of the working file, in order.
        func boxes() throws -> [Box] {
            let data = try Data(contentsOf: URL(fileURLWithPath: working))
            var result: [Box] = []
            var offset = 0
            while offset + 8 <= data.count {
                let size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
                let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
                guard size >= 8 else { break }
                result.append(Box(type: type, offset: Int64(offset), size: Int64(size)))
                offset += size
            }
            return result
        }

        func cut(at length: Int64) {
            #expect(truncate(working, off_t(length)) == 0)
        }

        func recover(environment: FFmpegEnvironment) throws -> SessionManifest.SegmentRecord {
            _ = try SessionRecovery.recover(directory: layout.sessionDirectory, environment: environment)
            return try #require(SessionRecovery.load(directory: layout.sessionDirectory)?.inputs.first?.segments.first)
        }

        func indexCount() -> Int {
            let data = FileManager.default.contents(atPath: layout.absolutePath(segment.indexFile)) ?? Data()
            return FrameIndexFile.decodeRecords(data).count
        }
    }

    /// What most of the 8 GB M1's failed parts were: cut partway through a fragment's media. The file was
    /// fine, but ffprobe's warning about the cut frame was parsed as the frame count.
    @Test func cutInsideMediaDataFinalizes() throws {
        let fixture = try Fixture(environment: environment)
        let mdats = try fixture.boxes().filter { $0.type == "mdat" }
        try #require(mdats.count >= 4)
        fixture.cut(at: mdats[3].offset + mdats[3].size / 2)

        let segment = try fixture.recover(environment: environment)
        #expect(segment.state == .finalized)
        #expect(segment.finalizeError == nil)
        // Fragments are half a second, so three complete ones hold 45 frames and the cut one adds a few more.
        #expect(segment.frames > 45)
        #expect(try MediaProbe.videoFrameCount(fixture.final, environment: environment) == segment.frames)
        #expect(fixture.indexCount() == segment.frames)
        #expect(segment.lostFrames == 4 * 30 + 20 - segment.frames)
        #expect(!FileManager.default.fileExists(atPath: fixture.working))
    }

    /// A cut inside a fragment header makes ffprobe refuse the whole file. Salvage keeps every complete fragment.
    @Test func cutInsideFragmentHeaderIsSalvaged() throws {
        let fixture = try Fixture(environment: environment)
        let moofs = try fixture.boxes().filter { $0.type == "moof" }
        try #require(moofs.count >= 5)
        let clean = moofs[4].offset

        // How many frames the four complete fragments hold, measured on a copy cut cleanly between fragments.
        let reference = fixture.working + ".reference.mov"
        try FileManager.default.copyItem(atPath: fixture.working, toPath: reference)
        #expect(truncate(reference, off_t(clean)) == 0)
        let expected = try MediaProbe.videoFrameCount(reference, environment: environment)
        unlink(reference)

        fixture.cut(at: clean + moofs[4].size / 2)
        #expect(throws: MediaProbe.ProbeFailure.self) { try MediaProbe.videoFrameCount(fixture.working, environment: environment) }

        let segment = try fixture.recover(environment: environment)
        #expect(segment.state == .finalized)
        #expect(segment.finalizeError == nil)
        #expect(segment.frames == expected)
        #expect(try MediaProbe.videoFrameCount(fixture.final, environment: environment) == expected)
        #expect(fixture.indexCount() == expected)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.layout.inputDirectory(inputLabel: "Cam"))
        #expect(!leftovers.contains { $0.contains("salvage") })
        #expect(!FileManager.default.fileExists(atPath: fixture.working))
    }

    @Test func unreadableRecordingSaysWhy() throws {
        let fixture = try Fixture(environment: environment)
        try Data(repeating: 0xAB, count: 4096).write(to: URL(fileURLWithPath: fixture.working))

        let segment = try fixture.recover(environment: environment)
        #expect(segment.state == .finalizeFailed)
        #expect(segment.finalizeError?.hasPrefix("could not read the recording") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.working))
    }
}
