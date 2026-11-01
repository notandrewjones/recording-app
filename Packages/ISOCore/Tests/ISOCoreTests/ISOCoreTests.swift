import Foundation
import Testing
@testable import ISOCore

@Suite struct VideoFormatTests {
    @Test func v210FrameSizesMatchMeasuredRawFiles() {
        #expect(VideoFormat.hd1080p5994.rowBytes == 5120)
        #expect(VideoFormat.hd1080p5994.frameBytes == 5_529_600)
        #expect(VideoFormat.uhd2160p5994.frameBytes == 22_118_400)
    }

    @Test func v210RowsPadTo48PixelBoundary() {
        #expect(PixelLayout.v210.rowBytes(width: 1280) == 3456)
        #expect(PixelLayout.v210.rowBytes(width: 720) == 1920)
    }

    @Test func uyvySizeMatchesMeasuredRawFile() {
        var format = VideoFormat.hd1080p5994
        format.pixelLayout = .uyvy422
        #expect(format.frameBytes == 4_147_200)
    }

    @Test func displayNames() {
        #expect(VideoFormat.hd1080p5994.displayName == "1080p59.94")
        #expect(VideoFormat.hd1080i5994.displayName == "1080i59.94")
        #expect(VideoFormat(width: 1920, height: 1080, frameRate: Rational(25, 1)).displayName == "1080p25")
        #expect(VideoFormat(width: 1920, height: 1080, frameRate: Rational(24000, 1001), scan: .progressiveSegmented).displayName == "1080PsF23.98")
    }
}

@Suite struct TimecodeTests {
    @Test func dropFrameMatchesObservedFfmpegFrameCount() {
        // 01:02:03;04 read back as 01:01:59:20 when ffmpeg lost the drop flag. Same count, different label.
        let drop = Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, nominalFPS: 60, isDropFrame: true)
        let nonDrop = Timecode(hours: 1, minutes: 1, seconds: 59, frames: 20, nominalFPS: 60, isDropFrame: false)
        #expect(drop.frameCount == 223_160)
        #expect(drop.frameCount == nonDrop.frameCount)
        #expect(drop.string == "01:02:03;04")
        #expect(nonDrop.string == "01:01:59:20")
    }

    @Test(arguments: [30, 60])
    func dropFrameRoundTripsEveryMinuteBoundary(nominal: Int) {
        let perMinute = nominal == 60 ? 4 : 2
        for minute in 0..<60 {
            for frame in [perMinute, perMinute + 1, nominal - 1] {
                let tc = Timecode(hours: 0, minutes: minute, seconds: 0, frames: frame, nominalFPS: nominal, isDropFrame: true)
                #expect(tc.components.minutes == minute)
                #expect(tc.components.frames == frame)
            }
        }
    }

    @Test func dropFrameSkipsLabelsAtMinuteBoundary() {
        let last = Timecode(hours: 0, minutes: 0, seconds: 59, frames: 59, nominalFPS: 60, isDropFrame: true)
        let next = Timecode(frameCount: last.frameCount + 1, nominalFPS: 60, isDropFrame: true)
        #expect(next.string == "00:01:00;04")
    }

    @Test func tenthMinuteDoesNotDrop() {
        let last = Timecode(hours: 0, minutes: 9, seconds: 59, frames: 59, nominalFPS: 60, isDropFrame: true)
        let next = Timecode(frameCount: last.frameCount + 1, nominalFPS: 60, isDropFrame: true)
        #expect(next.string == "00:10:00;00")
    }

    @Test func rateSelectsDropFrameMode() {
        #expect(Timecode(frameCount: 0, frameRate: Rational(60000, 1001)).isDropFrame)
        #expect(!Timecode(frameCount: 0, frameRate: Rational(24000, 1001)).isDropFrame)
        #expect(!Timecode(frameCount: 0, frameRate: Rational(50, 1)).isDropFrame)
    }
}

@Suite struct StorageEstimateTests {
    @Test func proResHQMatchesMeasuredRate() {
        // Measured about 55 MB/s per 1080p59.94 HQ stream.
        let rate = Codec.proResHQ.estimatedVideoBytesPerSecond(for: .hd1080p5994)
        #expect(abs(rate - 55_000_000) < 500_000)
    }

    @Test func proRes4KScalesByPixelRate() {
        let hd = Codec.proRes422.estimatedVideoBytesPerSecond(for: .hd1080p5994)
        let uhd = Codec.proRes422.estimatedVideoBytesPerSecond(for: .uhd2160p5994)
        #expect(abs(uhd / hd - 4) < 0.01)
    }

    @Test func includesAudio() {
        let without = StorageEstimate.bytesPerHour(format: .hd1080p5994, codec: .proResHQ, audio: nil)
        let with = StorageEstimate.bytesPerHour(format: .hd1080p5994, codec: .proResHQ, audio: AudioFormat(channels: 16))
        let audioBytes: Double = 48_000 * 3 * 16 * 3600
        #expect(with - without == audioBytes)
    }

    @Test func hoursRemaining() {
        #expect(StorageEstimate.hoursRemaining(freeBytes: 100, bytesPerHour: [25, 25]) == 2)
        #expect(StorageEstimate.hoursRemaining(freeBytes: 100, bytesPerHour: []) == nil)
    }
}

@Suite struct FFmpegCommandTests {
    func config(codec: Codec = .proResHQ, format: VideoFormat = .hd1080p5994, audio: AudioFormat? = AudioFormat(channels: 16), software: Bool = false) -> RecorderConfiguration {
        RecorderConfiguration(
            format: format, codec: codec, audio: audio,
            videoSocketPath: "/tmp/iso/v1.sock",
            audioSocketPath: audio == nil ? nil : "/tmp/iso/a1.sock",
            startTimecode: Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, nominalFPS: 60, isDropFrame: true),
            outputPath: "/rec/cam1_0001.mov",
            allowSoftwareProRes: software
        )
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    @Test func disablesProbingOnEveryInput() throws {
        let args = try FFmpegCommand.recordArguments(config())
        #expect(args.filter { $0 == "-probesize" }.count == 2)
        #expect(args.filter { $0 == "-analyzeduration" }.count == 2)
    }

    @Test func probeFlagsPrecedeTheirInput() throws {
        let args = try FFmpegCommand.recordArguments(config(audio: nil))
        #expect(args.firstIndex(of: "-probesize")! < args.firstIndex(of: "-i")!)
    }

    @Test func fragmentsForCrashSafety() throws {
        let args = try FFmpegCommand.recordArguments(config())
        #expect(value(after: "-frag_duration", in: args) == "500000")
        #expect(value(after: "-movflags", in: args)?.contains("empty_moov") == true)
    }

    @Test func proResUsesHardwareUnlessSoftwareIsExplicitlyAllowed() throws {
        #expect(value(after: "-c:v", in: try FFmpegCommand.recordArguments(config())) == "prores_videotoolbox")
        #expect(value(after: "-c:v", in: try FFmpegCommand.recordArguments(config(software: true))) == "prores_ks")
    }

    @Test func eightBitInputUsesRawvideoDemuxer() throws {
        var format = VideoFormat.hd1080p5994
        format.pixelLayout = .uyvy422
        let args = try FFmpegCommand.recordArguments(config(format: format))
        #expect(value(after: "-f", in: args) == "rawvideo")
        #expect(value(after: "-pixel_format", in: args) == "uyvy422")
    }

    @Test func interlacedSetsFieldOrder() throws {
        let args = try FFmpegCommand.recordArguments(config(format: .hd1080i5994))
        #expect(value(after: "-vf", in: args)?.contains("field_mode=tff") == true)
    }

    @Test func colourIsSetOnFramesNotAsEncoderFlags() throws {
        let args = try FFmpegCommand.recordArguments(config())
        #expect(value(after: "-vf", in: args)?.contains("colorspace=bt709") == true)
        #expect(!args.contains("-colorspace"))
    }

    @Test func rejectsChannelCountsFfmpegCannotParse() {
        #expect(throws: FFmpegCommandError.unsupportedAudioChannelCount(32)) {
            try FFmpegCommand.recordArguments(config(audio: AudioFormat(channels: 32)))
        }
    }

    @Test func rejectsSocketPathsBeyondMacOSLimit() {
        var bad = config()
        bad.videoSocketPath = "/" + String(repeating: "a", count: 103)
        #expect(throws: FFmpegCommandError.self) { try FFmpegCommand.recordArguments(bad) }
    }

    @Test func audioRequiresASocket() {
        var bad = config()
        bad.audioSocketPath = nil
        #expect(throws: FFmpegCommandError.audioSocketMissing) { try FFmpegCommand.recordArguments(bad) }
    }

    @Test func finalizeRestatesDropFrameTimecode() {
        let tc = Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, nominalFPS: 60, isDropFrame: true)
        let args = FFmpegCommand.finalizeArguments(input: "in.mov", output: "out.mov", startTimecode: tc)
        #expect(value(after: "-timecode", in: args) == "01:02:03;04")
        #expect(value(after: "-c", in: args) == "copy")
    }
}

@Suite struct SessionLayoutTests {
    @Test func paths() {
        let layout = SessionLayout(rootPath: "/rec", sessionName: "Game 1")
        #expect(layout.sessionDirectory == "/rec/Game_1")
        #expect(layout.segmentPath(inputLabel: "Cam 1", segment: 7) == "/rec/Game_1/Cam_1/Cam_1_0007.mov")
        #expect(layout.frameIndexPath(inputLabel: "Cam 1", segment: 7) == "/rec/Game_1/Cam_1/Cam_1_0007.idx")
    }

    @Test func sanitizeBlocksTraversalAndEmptyNames() {
        #expect(SessionLayout.sanitize("../../etc") == "etc")
        #expect(SessionLayout.sanitize("///") == "untitled")
    }

    @Test func defaultName() {
        let name = SessionLayout.defaultSessionName(date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "1970-01-01_000000")
    }
}

@Suite struct FrameIndexTests {
    let record = FrameIndexRecord(frameNumber: 42, hostTimeNanos: 9_000_000_000, streamTime: -7, timecodeFrames: 223_160, flags: [.repeated, .embeddedTimecode])

    @Test func recordRoundTrips() {
        var data = FrameIndexFile.encode(FrameIndexFile.Header(frameRate: Rational(60000, 1001), streamTimescale: 60000))
        data.append(FrameIndexFile.encode(record))
        #expect(FrameIndexFile.decodeRecords(data) == [record])
    }

    @Test func headerRoundTrips() throws {
        let header = FrameIndexFile.Header(frameRate: Rational(60000, 1001), streamTimescale: 60000)
        let data = FrameIndexFile.encode(header)
        #expect(data.count == FrameIndexFile.headerSize)
        #expect(try FrameIndexFile.decodeHeader(data) == header)
    }

    @Test func recordSizeIsFixed() {
        #expect(FrameIndexFile.encode(record).count == FrameIndexFile.recordSize)
    }

    @Test func tornTailIsIgnored() {
        var data = FrameIndexFile.encode(FrameIndexFile.Header(frameRate: Rational(50, 1), streamTimescale: 50))
        data.append(FrameIndexFile.encode(record))
        data.append(FrameIndexFile.encode(record).prefix(11))
        #expect(FrameIndexFile.decodeRecords(data).count == 1)
    }

    @Test func rejectsForeignFile() {
        #expect(throws: FrameIndexFile.ReadError.badMagic) {
            try FrameIndexFile.decodeHeader(Data(repeating: 0, count: 32))
        }
    }

    @Test func nearestFrameFindsClosestAcrossUnsyncedInputs() {
        let records = [100, 200, 300].enumerated().map {
            FrameIndexRecord(frameNumber: UInt64($0), hostTimeNanos: UInt64($1), streamTime: 0, timecodeFrames: 0, flags: [])
        }
        #expect(FrameLookup.nearestFrame(in: records, hostTimeNanos: 240)?.frameNumber == 1)
        #expect(FrameLookup.nearestFrame(in: records, hostTimeNanos: 260)?.frameNumber == 2)
        #expect(FrameLookup.nearestFrame(in: records, hostTimeNanos: 1)?.frameNumber == 0)
        #expect(FrameLookup.nearestFrame(in: records, hostTimeNanos: 999)?.frameNumber == 2)
        #expect(FrameLookup.nearestFrame(in: [], hostTimeNanos: 1) == nil)
    }
}

@Suite struct RecorderWatchdogTests {
    func recording() -> RecorderWatchdog {
        var dog = RecorderWatchdog()
        _ = dog.handle(.recordRequested)
        _ = dog.handle(.processStarted)
        return dog
    }

    @Test func startsFirstSegment() {
        var dog = RecorderWatchdog()
        #expect(dog.handle(.recordRequested) == [.startProcess(segment: 1)])
        _ = dog.handle(.processStarted)
        #expect(dog.state == .recording(segment: 1))
    }

    @Test func crashRestartsIntoNewSegment() {
        var dog = recording()
        let actions = dog.handle(.processExited(segment: 1, code: 1))
        #expect(actions.contains(.scheduleRetry(afterSeconds: 0.25)))
        #expect(dog.state == .backingOff(nextSegment: 2, attempt: 1))
        #expect(dog.handle(.backoffElapsed) == [.startProcess(segment: 2)])
    }

    @Test func stallKillsThenRestarts() {
        var dog = recording()
        let actions = dog.handle(.outputStalled)
        #expect(actions.first == .killProcess)
        #expect(dog.state == .backingOff(nextSegment: 2, attempt: 1))
    }

    @Test func repeatedFailuresEscalateThenGiveUp() {
        var dog = RecorderWatchdog(maxAttempts: 3)
        _ = dog.handle(.recordRequested)
        for expected in 1...3 {
            _ = dog.handle(.processExited(segment: expected, code: 1))
            if case .backingOff(_, let attempt) = dog.state { #expect(attempt == expected) } else { Issue.record("expected backoff") }
            _ = dog.handle(.backoffElapsed)
        }
        _ = dog.handle(.processExited(segment: 4, code: 1))
        if case .failed = dog.state {} else { Issue.record("expected failed, got \(dog.state)") }
    }

    @Test func healthySegmentResetsEscalation() {
        var dog = RecorderWatchdog(maxAttempts: 2)
        _ = dog.handle(.recordRequested)
        _ = dog.handle(.processExited(segment: 1, code: 1))
        _ = dog.handle(.backoffElapsed)
        _ = dog.handle(.processStarted)
        dog.markHealthy()
        _ = dog.handle(.processExited(segment: 2, code: 1))
        #expect(dog.state == .backingOff(nextSegment: 3, attempt: 1))
    }

    @Test func signalLossClosesSegmentAndResumesInNext() {
        var dog = recording()
        #expect(dog.handle(.signalLost).first == .stopProcess)
        #expect(dog.state == .waitingForSignal(nextSegment: 2))
        #expect(dog.handle(.signalRestored) == [.startProcess(segment: 2)])
    }

    @Test func formatChangeRollsSegmentImmediately() {
        var dog = recording()
        let actions = dog.handle(.formatChanged)
        #expect(actions.prefix(2) == [.stopProcess, .startProcess(segment: 2)])
    }

    @Test func stopDuringWaitDoesNothingToProcess() {
        var dog = recording()
        _ = dog.handle(.signalLost)
        #expect(dog.handle(.stopRequested) == [])
        #expect(dog.state == .idle)
    }

    @Test func staleExitAfterStopIsIgnored() {
        var dog = recording()
        _ = dog.handle(.stopRequested)
        #expect(dog.handle(.processExited(segment: 1, code: 0)) == [])
        #expect(dog.state == .idle)
    }

    @Test func exitOfClosedSegmentDoesNotKillItsSuccessor() {
        var dog = recording()
        _ = dog.handle(.formatChanged)
        _ = dog.handle(.processStarted)
        #expect(dog.handle(.processExited(segment: 1, code: 0)) == [])
        #expect(dog.state == .recording(segment: 2))
    }

    @Test func backoffIsCapped() {
        #expect(RecorderWatchdog.backoffSeconds(attempt: 1) == 0.25)
        #expect(RecorderWatchdog.backoffSeconds(attempt: 20) == 5)
    }
}

@Suite struct SyntheticFrameTests {
    @Test(arguments: PixelLayout.allCases)
    func fillsWholeFrameWithoutOverrun(layout: PixelLayout) {
        var format = VideoFormat.hd1080p5994
        format.pixelLayout = layout
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: format.frameBytes, alignment: 16)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        SyntheticFrame.fill(buffer, format: format, frameNumber: 5)
        #expect(buffer.contains { $0 != 0 })
    }

    @Test func v210FirstWordIsWhiteBar() {
        let format = VideoFormat.hd1080p5994
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: format.frameBytes, alignment: 16)
        defer { buffer.deallocate() }
        SyntheticFrame.fill(buffer, format: format, frameNumber: 0)
        let word = buffer.load(as: UInt32.self).littleEndian
        let cb: UInt32 = word & 0x3FF
        let luma: UInt32 = (word >> 10) & 0x3FF
        let cr: UInt32 = (word >> 20) & 0x3FF
        #expect(cb == 512)
        #expect(luma == 720)
        #expect(cr == 512)
    }

    @Test func blockMovesAndWraps() {
        #expect(SyntheticFrame.movingBlockColumn(frameNumber: 0, width: 100, blockWidth: 10) == 0)
        #expect(SyntheticFrame.movingBlockColumn(frameNumber: 91, width: 100, blockWidth: 10) == 1)
    }
}
