import Darwin
import Foundation
import ISOCore
import Testing
@testable import ISOEngine

/// End-to-end tests against the real ffmpeg, with synthetic sources standing in for capture cards.
@Suite(.serialized) struct RecordingIntegrationTests {
    let environment = try! FFmpegEnvironment.locate()

    final class Harness {
        let root: String
        let session: RecordingSession
        let recorder: InputRecorder
        let source: SyntheticSource

        init(environment: FFmpegEnvironment, settings: InputRecorderSettings = InputRecorderSettings(fullSyncSeconds: 0), source: SyntheticSource) throws {
            root = (NSTemporaryDirectory() as NSString).appendingPathComponent("isorec-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            session = try RecordingSession(rootPath: root, name: "test", environment: environment)
            recorder = session.addInput(id: "cam", label: "Cam", settings: settings)
            self.source = source
            let recorder = recorder
            source.onFrame = { recorder.ingest($0) }
        }

        deinit {
            try? FileManager.default.removeItem(atPath: root)
        }

        /// Starts the source, records once frames are flowing, and stops after `frames` have been delivered.
        func record(frames: UInt64) {
            source.start(frames: frames)
            Thread.sleep(forTimeInterval: 0.1)
            recorder.startRecording()
            source.waitUntilFinished()
            Thread.sleep(forTimeInterval: 0.2)
            finish()
        }

        func finish() {
            recorder.stopRecording()
            source.cancel()
            session.waitUntilFinished()
        }

        var segments: [SessionManifest.SegmentRecord] {
            session.store.snapshot.inputs.first?.segments ?? []
        }

        func indexRecords(_ segment: SessionManifest.SegmentRecord) -> [FrameIndexRecord] {
            let data = FileManager.default.contents(atPath: session.layout.absolutePath(segment.indexFile)) ?? Data()
            return FrameIndexFile.decodeRecords(data)
        }

        func info(_ segment: SessionManifest.SegmentRecord, environment: FFmpegEnvironment) throws -> MediaProbe.Info {
            try MediaProbe.info(session.layout.absolutePath(segment.finalFile), environment: environment)
        }
    }

    func audioSeconds(_ path: String) throws -> Double {
        let result = try ProcessRunner.run(environment.ffprobePath, [
            "-v", "error", "-select_streams", "a", "-show_entries", "stream=duration", "-of", "csv=p=0", path,
        ])
        return Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    @Test func cleanRecordingIsFrameExact() throws {
        let harness = try Harness(environment: environment, source: SyntheticSource())
        harness.record(frames: 180)

        let segments = harness.segments
        #expect(segments.count == 1)
        let segment = try #require(segments.first)
        #expect(segment.state == .finalized)
        #expect(segment.endReason == .stopped)

        let info = try harness.info(segment, environment: environment)
        let records = harness.indexRecords(segment)
        #expect(info.videoFrames > 100)
        #expect(info.videoFrames == records.count)
        #expect(info.videoFrames == harness.recorder.status().totalFrames)
        #expect(segment.lostFrames == 0)
        #expect(records.map(\.frameNumber) == (0..<UInt64(records.count)).map { $0 })
        #expect(info.audioChannels == 16)
        #expect(info.codecName == "prores")
        #expect(info.timecode == segment.startTimecode)

        let working = harness.session.layout.absolutePath(segment.workingFile)
        #expect(!FileManager.default.fileExists(atPath: working))
    }

    @Test func recordingArmedBeforeFramesArriveStartsAtSegmentOne() throws {
        let harness = try Harness(environment: environment, source: SyntheticSource())
        harness.recorder.startRecording()
        Thread.sleep(forTimeInterval: 0.1)
        harness.source.start(frames: 60)
        harness.source.waitUntilFinished()
        Thread.sleep(forTimeInterval: 0.2)
        harness.finish()
        #expect(harness.segments.map(\.number) == [1])
    }

    @Test func audioMatchesVideoLength() throws {
        let harness = try Harness(environment: environment, source: SyntheticSource())
        harness.record(frames: 120)
        let segment = try #require(harness.segments.first)
        let path = harness.session.layout.absolutePath(segment.finalFile)
        let videoSeconds = Double(segment.frames) * 1001 / 60000
        #expect(abs(try audioSeconds(path) - videoSeconds) < 1.0 / 59.94)
    }

    @Test func embeddedDropFrameTimecodeReachesTheFinalFile() throws {
        let start = Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, nominalFPS: 60, isDropFrame: true)
        let harness = try Harness(environment: environment, source: SyntheticSource(timecodeStart: start))
        harness.record(frames: 90)
        let segment = try #require(harness.segments.first)
        #expect(segment.timecodeIsEmbedded)
        #expect(segment.startTimecode.contains(";"))
        #expect(try harness.info(segment, environment: environment).timecode == segment.startTimecode)
        let records = harness.indexRecords(segment)
        #expect(records.allSatisfy { $0.flags.contains(.embeddedTimecode) })
        #expect(records[1].timecodeFrames == records[0].timecodeFrames + 1)
    }

    @Test func missingFramesAreFilledSoFramesStayExact() throws {
        let source = SyntheticSource(faults: [60: .dropFrames(7)])
        let harness = try Harness(environment: environment, source: source)
        harness.record(frames: 120)

        let segment = try #require(harness.segments.first)
        let records = harness.indexRecords(segment)
        #expect(segment.repeatedFrames == 7)
        #expect(records.filter { $0.flags.contains(.repeated) }.count == 7)
        #expect(try harness.info(segment, environment: environment).videoFrames == records.count)

        let path = harness.session.layout.absolutePath(segment.finalFile)
        let videoSeconds = Double(segment.frames) * 1001 / 60000
        #expect(abs(try audioSeconds(path) - videoSeconds) < 2.0 / 59.94)
    }

    @Test func gapTooLongToFillStartsANewSegment() throws {
        let source = SyntheticSource(faults: [60: .dropFrames(600)])
        let harness = try Harness(environment: environment, source: source)
        harness.record(frames: 150)

        let segments = harness.segments
        #expect(segments.count == 2)
        #expect(segments.first?.endReason == .discontinuity)
        #expect(segments.allSatisfy { $0.state == .finalized })
    }

    @Test func formatChangeClosesTheSegmentAndContinues() throws {
        let newFormat = VideoFormat(width: 1280, height: 720, frameRate: Rational(60000, 1001))
        let source = SyntheticSource(faults: [90: .changeFormat(newFormat)])
        let harness = try Harness(environment: environment, source: source)
        harness.record(frames: 210)

        let segments = harness.segments
        #expect(segments.count == 2)
        #expect(segments.first?.endReason == .formatChanged)
        #expect(segments.first?.format.height == 1080)
        #expect(segments.last?.format.height == 720)
        #expect(try harness.info(try #require(segments.last), environment: environment).width == 1280)
    }

    @Test func signalLossClosesTheSegmentAndResumes() throws {
        let source = SyntheticSource(faults: [90: .loseSignal(frames: 60)])
        let harness = try Harness(environment: environment, source: source)
        harness.record(frames: 240)

        let segments = harness.segments
        #expect(segments.count == 2)
        #expect(segments.first?.endReason == .signalLost)
        let events = harness.session.store.snapshot.inputs[0].events.map(\.kind)
        #expect(events.contains("signal_lost"))
        #expect(events.filter { $0 == "signal_restored" }.count >= 2)
        for segment in segments {
            #expect(try harness.info(segment, environment: environment).videoFrames == harness.indexRecords(segment).count)
        }
    }

    @Test func frameDeliveryStoppingCountsAsSignalLoss() throws {
        let source = SyntheticSource(faults: [90: .stopDelivering(seconds: 2)])
        let harness = try Harness(environment: environment, source: source)
        harness.record(frames: 180)
        #expect(harness.segments.count == 2)
        #expect(harness.segments.first?.endReason == .signalLost)
    }

    @Test func killedFFmpegRestartsIntoANewSegment() throws {
        let harness = try Harness(environment: environment, source: SyntheticSource())
        harness.source.start(frames: 360)
        Thread.sleep(forTimeInterval: 0.1)
        harness.recorder.startRecording()
        Thread.sleep(forTimeInterval: 2)
        let pid = try #require(harness.recorder.status().ffmpegProcessIdentifier)
        #expect(kill(pid, SIGKILL) == 0)
        harness.source.waitUntilFinished()
        Thread.sleep(forTimeInterval: 0.2)
        harness.finish()

        let segments = harness.segments
        #expect(segments.count == 2)
        #expect(segments.first?.endReason == .recorderFailed)
        #expect(segments.allSatisfy { $0.state == .finalized })
        #expect(harness.recorder.status().restarts == 1)

        // The index is trimmed to match, so frame N is still record N in the crashed segment.
        for segment in segments {
            #expect(harness.indexRecords(segment).count == segment.frames)
        }

        // Segment 1 keeps everything up to about the last fragment, and the gap is bounded.
        let total = segments.map(\.frames).reduce(0, +)
        #expect(total > 280)
    }

    @Test func hungFFmpegIsDetectedAndReplaced() throws {
        let settings = InputRecorderSettings(stallSeconds: 1, fullSyncSeconds: 0)
        let harness = try Harness(environment: environment, settings: settings, source: SyntheticSource())
        harness.source.start(frames: 420)
        Thread.sleep(forTimeInterval: 0.1)
        harness.recorder.startRecording()
        Thread.sleep(forTimeInterval: 1.5)
        let pid = try #require(harness.recorder.status().ffmpegProcessIdentifier)
        #expect(kill(pid, SIGSTOP) == 0)
        harness.source.waitUntilFinished()
        Thread.sleep(forTimeInterval: 0.2)
        harness.finish()

        #expect(harness.recorder.status().restarts >= 1)
        #expect(harness.segments.count >= 2)
        #expect(harness.segments.last?.state == .finalized)
    }

    @Test func missingFFmpegFailsWithoutCrashing() throws {
        let broken = FFmpegEnvironment(ffmpegPath: "/nonexistent/ffmpeg", ffprobePath: environment.ffprobePath)
        let harness = try Harness(environment: broken, source: SyntheticSource())
        harness.source.start()
        Thread.sleep(forTimeInterval: 0.1)
        harness.recorder.startRecording()

        // Five attempts with backoff take about 8 seconds.
        var reachedFailure = false
        for _ in 0..<120 where !reachedFailure {
            Thread.sleep(forTimeInterval: 0.1)
            if case .failed = harness.recorder.status().state { reachedFailure = true }
        }
        harness.finish()
        #expect(reachedFailure)
        #expect(harness.segments.isEmpty)
    }

    @Test func softwareIsNeverChosenSilently() throws {
        let harness = try Harness(environment: environment, source: SyntheticSource())
        harness.record(frames: 30)
        let log = harness.session.layout.absolutePath(try #require(harness.segments.first).logFile)
        #expect(!(FileManager.default.contents(atPath: log).map { String(decoding: $0, as: UTF8.self) } ?? "").contains("prores_ks"))
    }

    @Test func appCrashIsRecoverableFromTheSessionFolder() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("isorec-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let binary = FileManager.default.currentDirectoryPath + "/.build/debug/isorec"
        try #require(FileManager.default.isExecutableFile(atPath: binary))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["record", "--root", root, "--name", "crash", "--inputs", "2", "--seconds", "30"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        Thread.sleep(forTimeInterval: 5)
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        Thread.sleep(forTimeInterval: 1.5)

        let directory = (root as NSString).appendingPathComponent("crash")
        #expect(SessionRecovery.incompleteSessions(root: root) == [directory])

        let report = try SessionRecovery.recover(directory: directory, environment: environment)
        #expect(report.recovered == 2)
        #expect(report.failed == 0)
        #expect(SessionRecovery.incompleteSessions(root: root).isEmpty)

        let manifest = try #require(SessionRecovery.load(directory: directory))
        for input in manifest.inputs {
            let segment = try #require(input.segments.first)
            #expect(segment.endReason == .appInterrupted)
            // About 4.5 s was recording, so at most a little over one fragment is lost.
            #expect(segment.frames > 220)
        }
    }

    @Test func oneInputFailingLeavesTheOthersUntouched() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("isorec-iso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let session = try RecordingSession(rootPath: root, name: "iso", environment: environment)
        let settings = InputRecorderSettings(stallSeconds: 1, fullSyncSeconds: 0)

        var sources: [SyntheticSource] = []
        var recorders: [InputRecorder] = []
        for index in 1...4 {
            let recorder = session.addInput(id: "cam\(index)", label: "Cam \(index)", settings: settings)
            let source = SyntheticSource()
            source.onFrame = { recorder.ingest($0) }
            source.start(frames: 420)
            sources.append(source)
            recorders.append(recorder)
        }
        Thread.sleep(forTimeInterval: 0.1)
        session.startAll()
        Thread.sleep(forTimeInterval: 2)

        // One recorder is killed outright and another hangs. Both must recover alone.
        let killed = try #require(recorders[0].status().ffmpegProcessIdentifier)
        let hung = try #require(recorders[1].status().ffmpegProcessIdentifier)
        #expect(kill(killed, SIGKILL) == 0)
        #expect(kill(hung, SIGSTOP) == 0)

        sources.forEach { $0.waitUntilFinished() }
        Thread.sleep(forTimeInterval: 0.2)
        session.stopAll()
        session.waitUntilFinished()

        let inputs = session.store.snapshot.inputs
        #expect(inputs[0].segments.count >= 2)
        #expect(inputs[1].segments.count >= 2)
        for index in 2...3 {
            #expect(inputs[index].segments.count == 1)
            #expect(inputs[index].segments.first?.repeatedFrames == 0)
            #expect(recorders[index].status().restarts == 0)
            #expect(inputs[index].segments.first?.state == .finalized)
        }
        let failed = try #require(inputs[0].segments.first)
        #expect(failed.lostFrames > 0)
        #expect(failed.lostFrames < 60)
    }

    @Test func mixedFormatsRecordSideBySide() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("isorec-mix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let session = try RecordingSession(rootPath: root, name: "mix", environment: environment)
        let formats: [VideoFormat] = [
            .hd1080p5994,
            .hd1080i5994,
            VideoFormat(width: 1280, height: 720, frameRate: Rational(50, 1)),
            VideoFormat(width: 1920, height: 1080, frameRate: Rational(24000, 1001)),
        ]
        var sources: [SyntheticSource] = []
        for (index, format) in formats.enumerated() {
            let settings = InputRecorderSettings(fullSyncSeconds: 0)
            let recorder = session.addInput(id: "cam\(index)", label: "Cam \(index)", settings: settings)
            let source = SyntheticSource(format: format)
            source.onFrame = { recorder.ingest($0) }
            source.start()
            sources.append(source)
        }
        Thread.sleep(forTimeInterval: 0.2)
        session.startAll()
        Thread.sleep(forTimeInterval: 2.5)
        session.stopAll()
        sources.forEach { $0.cancel() }
        session.waitUntilFinished()

        let inputs = session.store.snapshot.inputs
        for (index, format) in formats.enumerated() {
            let segment = try #require(inputs[index].segments.first)
            let info = try MediaProbe.info(session.layout.absolutePath(segment.finalFile), environment: environment)
            #expect(info.width == format.width)
            #expect(info.videoFrames == segment.frames)
            #expect(segment.repeatedFrames == 0)
            if format.scan.isInterlaced { #expect(info.fieldOrder != "progressive") } else { #expect(info.fieldOrder == "progressive") }
        }
    }

    @Test func driveFillingStopsCleanlyAndKeepsTheFootage() throws {
        let image = (NSTemporaryDirectory() as NSString).appendingPathComponent("isorec-\(UUID().uuidString).dmg")
        let create = try ProcessRunner.run("/usr/bin/hdiutil", ["create", "-size", "400m", "-fs", "APFS", "-volname", "ISORecTest", "-ov", image])
        try #require(create.status == 0, "\(create.output)")
        defer { try? FileManager.default.removeItem(atPath: image) }
        let attach = try ProcessRunner.run("/usr/bin/hdiutil", ["attach", "-nobrowse", image])
        try #require(attach.status == 0, "\(attach.output)")
        let mount = try #require(attach.output.split(separator: "\n").last?.split(separator: "\t").last.map { String($0).trimmingCharacters(in: .whitespaces) })
        defer { _ = try? ProcessRunner.run("/usr/bin/hdiutil", ["detach", "-force", mount]) }

        let policy = StoragePolicy(criticalFreeBytes: 120 * 1_048_576)
        let session = try RecordingSession(rootPath: mount, name: "full", environment: environment, storagePolicy: policy)
        let stopped = DispatchSemaphore(value: 0)
        session.onStoppedForDiskSpace = { stopped.signal() }
        let recorder = session.addInput(id: "cam", label: "Cam", settings: InputRecorderSettings(fullSyncSeconds: 0))
        let pool = SyntheticFramePool(format: .hd1080p5994, count: 8)
        let source = SyntheticSource(pool: pool)
        source.onFrame = { recorder.ingest($0) }
        source.start()
        Thread.sleep(forTimeInterval: 0.1)
        session.startAll()

        #expect(stopped.wait(timeout: .now() + 30) == .success)
        source.cancel()
        session.waitUntilFinished()

        let segment = try #require(session.store.snapshot.inputs.first?.segments.first)
        #expect(segment.endReason == .diskFull)
        #expect(segment.frames > 100)
        // With no room for the copy, the working file is kept rather than risking it.
        let working = session.layout.absolutePath(segment.workingFile)
        let final = session.layout.absolutePath(segment.finalFile)
        #expect(FileManager.default.fileExists(atPath: working) || FileManager.default.fileExists(atPath: final))
        let survivor = FileManager.default.fileExists(atPath: final) ? final : working
        #expect(try MediaProbe.videoFrameCount(survivor, environment: environment) == segment.frames)
    }
}
