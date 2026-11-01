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
        let rate = Codec.proResHQ.estimatedVideoBytesPerSecond(for: .hd1080p5994) ?? 0
        #expect(abs(rate - 55_000_000) < 500_000)
    }

    @Test func proRes4KScalesByPixelRate() {
        let hd = Codec.proRes422.estimatedVideoBytesPerSecond(for: .hd1080p5994) ?? 0
        let uhd = Codec.proRes422.estimatedVideoBytesPerSecond(for: .uhd2160p5994) ?? 1
        #expect(abs(uhd / hd - 4) < 0.01)
    }

    @Test func includesAudio() {
        let without = StorageEstimate.bytesPerHour(format: .hd1080p5994, codec: .proResHQ, audio: nil) ?? 0
        let with = StorageEstimate.bytesPerHour(format: .hd1080p5994, codec: .proResHQ, audio: AudioFormat(channels: 16)) ?? 0
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

    @Test func neverUsesNobufferBecauseItDropsTheFirstFrame() throws {
        let args = try FFmpegCommand.recordArguments(config())
        #expect(!args.contains { $0.contains("nobuffer") })
    }

    @Test func hardwareLongGOPPrioritisesSpeed() throws {
        let args = try FFmpegCommand.recordArguments(config(codec: .longGOP(.defaultSettings(for: .hevc)), audio: nil))
        #expect(value(after: "-prio_speed", in: args) == "1")
    }

    @Test func decoderStaysSingleThreaded() throws {
        let args = try FFmpegCommand.recordArguments(config(audio: nil))
        #expect(value(after: "-threads", in: args) == "1")
        #expect(args.firstIndex(of: "-threads")! < args.firstIndex(of: "-i")!)
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
        let args = FFmpegCommand.finalizeArguments(input: "in.mov", output: "out.mov", startTimecode: "01:02:03;04")
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

    @Test func recordingBeforeFirstFrameKeepsSegmentOne() {
        var dog = RecorderWatchdog()
        _ = dog.handle(.recordRequested)
        _ = dog.handle(.noSignalYet)
        #expect(dog.handle(.signalRestored) == [.startProcess(segment: 1)])
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

@Suite struct AudioCadenceTests {
    @Test func averagesExactlyOverTheNTSCCycle() {
        let rate = Rational(60000, 1001)
        let total = (0..<5).map { AudioCadence.sampleCount(forFrame: $0, frameRate: rate) }.reduce(0, +)
        #expect(total == 4004)
        #expect(Set((0..<5).map { AudioCadence.sampleCount(forFrame: $0, frameRate: rate) }) == [800, 801])
    }

    @Test func integerRatesAreConstant() {
        #expect(AudioCadence.sampleCount(forFrame: 123, frameRate: Rational(50, 1)) == 960)
    }

    @Test func doesNotDriftOverADay() {
        let frames: UInt64 = 5_178_816 // 24 hours at 59.94
        let samples = AudioCadence.cumulativeSamples(throughFrames: frames, frameRate: Rational(60000, 1001))
        #expect(samples == frames * 48_000 * 1001 / 60000)
    }

    @Test func maximumCoversEveryFrame() {
        let rate = Rational(60000, 1001)
        #expect((0..<1000).allSatisfy { AudioCadence.sampleCount(forFrame: UInt64($0), frameRate: rate) <= AudioCadence.maximumSamplesPerFrame(frameRate: rate) })
    }
}

@Suite struct FrameGapTests {
    func detector() -> FrameGapDetector {
        FrameGapDetector(frameRate: Rational(60000, 1001), streamTimeScale: 240_000, maximumFill: 10)
    }

    @Test func consecutiveFramesAreContinuous() {
        var gap = detector()
        #expect(gap.observe(streamTime: 0) == .continuous)
        #expect(gap.observe(streamTime: 4004) == .continuous)
    }

    @Test func countsMissingFrames() {
        var gap = detector()
        _ = gap.observe(streamTime: 0)
        #expect(gap.observe(streamTime: 4004 * 4) == .missing(3))
    }

    @Test func largeJumpsAndBackwardsTimeBreakTheTimeline() {
        var gap = detector()
        _ = gap.observe(streamTime: 4004 * 100)
        #expect(gap.observe(streamTime: 4004 * 200) == .discontinuity)
        #expect(gap.observe(streamTime: 0) == .discontinuity)
    }
}

@Suite struct TimeOfDayTimecodeTests {
    @Test func countsFromMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 3600)
        let tc = Timecode.timeOfDay(date: date, frameRate: Rational(50, 1), calendar: calendar)
        #expect(tc.string == "01:00:00:00")
    }

    @Test func advanceKeepsMode() {
        let tc = Timecode(frameCount: 10, nominalFPS: 60, isDropFrame: true).advanced(by: 5)
        #expect(tc.frameCount == 15)
        #expect(tc.isDropFrame)
    }
}

@Suite struct SessionManifestTests {
    @Test func roundTrips() throws {
        var manifest = SessionManifest(name: "Game", createdAt: Date(timeIntervalSince1970: 1_000_000), createdAtHostNanos: 7)
        var input = SessionManifest.InputRecord(id: "a", label: "Cam 1")
        var segment = SessionManifest.SegmentRecord(number: 1, workingFile: "w", finalFile: "f", indexFile: "i", logFile: "l", format: .hd1080p5994, codec: .longGOP(LongGOPSettings(encoder: .h264Hardware, rateControl: .abr(kbps: 50_000))), audioChannels: 16, startTimecode: "01:00:00;00", timecodeIsEmbedded: true, startHostNanos: 9)
        segment.endReason = .signalLost
        input.segments.append(segment)
        manifest.inputs.append(input)
        manifest.markers.append(.init(hostNanos: 3, label: "Goal"))
        let data = try SessionManifest.encoder().encode(manifest)
        #expect(try SessionManifest.decoder().decode(SessionManifest.self, from: data) == manifest)
    }

    @Test func pathsAreRelativeToTheSession() {
        let layout = SessionLayout(rootPath: "/rec", sessionName: "S")
        let relative = layout.relativePath("/rec/S/Cam/Cam_0001.mov")
        #expect(relative == "Cam/Cam_0001.mov")
        #expect(layout.absolutePath(relative) == "/rec/S/Cam/Cam_0001.mov")
    }
}

@Suite struct StoragePolicyTests {
    let policy = StoragePolicy(warningSeconds: 600, criticalFreeBytes: 1000)

    @Test func stopsAtTheFloorEvenWhenIdle() {
        #expect(policy.evaluate(freeBytes: 1000, writeBytesPerSecond: 0) == .critical)
    }

    @Test func warnsWithTimeRemaining() {
        #expect(policy.evaluate(freeBytes: 2000, writeBytesPerSecond: 10) == .low(secondsRemaining: 100))
    }

    @Test func plentyOfRoomIsFine() {
        #expect(policy.evaluate(freeBytes: 10_000_000, writeBytesPerSecond: 10) == .ok)
        #expect(policy.evaluate(freeBytes: 2000, writeBytesPerSecond: 0) == .ok)
    }
}

@Suite struct InputLoadTests {
    @Test func thresholds() {
        #expect(InputLoad(ringFill: 0.1) == .healthy)
        #expect(InputLoad(ringFill: 0.6) == .strained)
        #expect(InputLoad(ringFill: 0.95) == .overloaded)
    }

    @Test func durationText() {
        #expect((3900.0).durationDescription == "1h 05m")
        #expect((750.0).durationDescription == "12m 30s")
    }
}

@Suite struct LongGOPTests {
    func arguments(_ settings: LongGOPSettings, format: VideoFormat = .hd1080p5994) throws -> [String] {
        try FFmpegCommand.recordArguments(RecorderConfiguration(
            format: format, codec: .longGOP(settings), audio: nil,
            videoSocketPath: "/tmp/v.sock", audioSocketPath: nil,
            startTimecode: Timecode(frameCount: 0, nominalFPS: 60, isDropFrame: true),
            outputPath: "/rec/a.mov"
        ))
    }

    func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    @Test func hardwareCBRSetsTheConstantFlag() throws {
        let args = try arguments(LongGOPSettings(encoder: .hevcHardware, rateControl: .cbr(kbps: 20_000)))
        #expect(value(after: "-c:v", in: args) == "hevc_videotoolbox")
        #expect(value(after: "-b:v", in: args) == "20000k")
        #expect(value(after: "-constant_bit_rate", in: args) == "1")
    }

    @Test func softwareEncodersUseCRFAndHardwareUsesQuality() throws {
        let crf = try arguments(LongGOPSettings(encoder: .x264, rateControl: .constantQuality(value: 23, maximumKbps: nil)))
        #expect(value(after: "-crf", in: crf) == "23")
        let quality = try arguments(LongGOPSettings(encoder: .hevcHardware, rateControl: .constantQuality(value: 60, maximumKbps: nil)))
        #expect(value(after: "-q:v", in: quality) == "60")
    }

    @Test func qualityCapBecomesARateLimit() throws {
        let args = try arguments(LongGOPSettings(encoder: .hevcHardware, rateControl: .constantQuality(value: 60, maximumKbps: 80_000)))
        #expect(value(after: "-maxrate", in: args) == "80000k")
    }

    @Test func appleSoftwareIsForced() throws {
        let args = try arguments(LongGOPSettings(encoder: .h264Software, rateControl: .abr(kbps: 20_000)))
        #expect(value(after: "-require_sw", in: args) == "1")
    }

    @Test func keyframeIntervalIsInFrames() throws {
        let args = try arguments(LongGOPSettings(encoder: .hevcHardware, rateControl: .abr(kbps: 20_000), keyframeSeconds: 2))
        #expect(value(after: "-g", in: args) == "120")
        #expect(value(after: "-bf", in: args) == "0")
    }

    @Test func chroma422SelectsTheProfile() throws {
        let args = try arguments(LongGOPSettings(encoder: .hevcHardware, rateControl: .abr(kbps: 50_000), chroma422: true))
        #expect(value(after: "-profile:v", in: args) == "main42210")
        #expect(value(after: "-vf", in: args)?.contains("format=p210le") == true)
    }

    @Test func rejectsOutOfRangeValues() {
        #expect(throws: FFmpegCommandError.qualityOutOfRange(.x264, 90)) {
            try arguments(LongGOPSettings(encoder: .x264, rateControl: .constantQuality(value: 90, maximumKbps: nil)))
        }
        #expect(throws: FFmpegCommandError.invalidBitrate(0)) {
            try arguments(LongGOPSettings(encoder: .hevcHardware, rateControl: .cbr(kbps: 0)))
        }
    }

    @Test func rejectsModesAnEncoderCannotDo() {
        #expect(throws: FFmpegCommandError.unsupportedRateControl(.hevcSoftware)) {
            try arguments(LongGOPSettings(encoder: .hevcSoftware, rateControl: .cbr(kbps: 20_000)))
        }
    }

    @Test func appleH264SoftwareOffersOnlyABR() {
        #expect(LongGOPEncoder.h264Software.supportedModes == [.abr])
    }

    @Test func uncappedQualityHasNoStorageEstimate() {
        let codec = Codec.longGOP(LongGOPSettings(encoder: .hevcHardware, rateControl: .constantQuality(value: 60, maximumKbps: nil)))
        #expect(StorageEstimate.bytesPerHour(format: .hd1080p5994, codec: codec, audio: nil) == nil)
    }

    @Test func storageEstimateUsesTheBitrate() {
        let codec = Codec.longGOP(LongGOPSettings(encoder: .hevcHardware, rateControl: .cbr(kbps: 40_000)))
        #expect(StorageEstimate.bytesPerHour(format: .hd1080p5994, codec: codec, audio: nil) == 18_000_000_000)
    }

    @Test func settingsSurviveJSON() throws {
        let codec = Codec.longGOP(LongGOPSettings(encoder: .x265, rateControl: .constantQuality(value: 26, maximumKbps: 50_000), preset: .ultrafast))
        let data = try JSONEncoder().encode(codec)
        #expect(try JSONDecoder().decode(Codec.self, from: data) == codec)
    }

    @Test func allChoicesHaveValidDefaults() {
        for encoder in LongGOPEncoder.allCases {
            #expect(encoder.qualityRange.contains(encoder.defaultQuality))
            #expect(!encoder.supportedModes.isEmpty)
        }
    }
}

@Suite struct OutputSettingsTests {
    @Test func defaultIsProResLT() {
        #expect(OutputSettings().codec == .proResLT)
    }

    @Test func switchingEncoderDropsAnUnsupportedMode() {
        let settings = LongGOPSettings(encoder: .hevcHardware, rateControl: .cbr(kbps: 25_000))
        let moved = settings.switched(to: .hevcSoftware)
        #expect(moved.rateControl == .abr(kbps: 25_000))
    }

    @Test func switchingBetweenQualityScalesResetsTheNumber() {
        let settings = LongGOPSettings(encoder: .hevcHardware, rateControl: .constantQuality(value: 90, maximumKbps: nil))
        #expect(settings.switched(to: .x265).rateControl == .constantQuality(value: 23, maximumKbps: nil))
    }

    @Test func chromaOnlyStaysOnHEVCHardware() {
        let settings = LongGOPSettings(encoder: .hevcHardware, rateControl: .abr(kbps: 50_000), chroma422: true)
        #expect(!settings.switched(to: .x265).chroma422)
    }

    @Test func modeChangesKeepTheBitrate() {
        #expect(RateControl.cbr(kbps: 40_000).switched(to: .abr, encoder: .hevcHardware) == .abr(kbps: 40_000))
        #expect(RateControl.abr(kbps: 40_000).switched(to: .vbr, encoder: .hevcHardware) == .vbr(kbps: 40_000, maximumKbps: 60_000))
    }

    func plan(_ count: Int, _ codec: Codec, format: VideoFormat = .hd1080p5994) -> [(codec: Codec, format: VideoFormat)] {
        Array(repeating: (codec, format), count: count)
    }

    @Test func measuredLimitsAreNotFlagged() {
        #expect(EncoderCapacity.warnings(for: plan(8, .proResLT)).isEmpty)
        #expect(EncoderCapacity.warnings(for: plan(5, .longGOP(.defaultSettings(for: .hevc)))).isEmpty)
        #expect(EncoderCapacity.warnings(for: plan(3, .longGOP(.defaultSettings(for: .h264)))).isEmpty)
    }

    @Test func exceedingAMeasuredLimitWarns() {
        #expect(EncoderCapacity.warnings(for: plan(6, .longGOP(.defaultSettings(for: .hevc)))).count == 1)
        #expect(EncoderCapacity.warnings(for: plan(4, .longGOP(.defaultSettings(for: .h264)))).count == 1)
    }

    @Test func oneUHDStreamCountsAsFourHD() {
        let uhd = plan(2, .longGOP(.defaultSettings(for: .hevc)), format: .uhd2160p5994)
        #expect(EncoderCapacity.warnings(for: uhd).count == 1)
    }

    @Test func slowSoftwareEncodersAlwaysWarn() {
        let codec = Codec.longGOP(LongGOPSettings(encoder: .x265, rateControl: .constantQuality(value: 26, maximumKbps: nil)))
        #expect(EncoderCapacity.warnings(for: plan(1, codec)).count == 1)
    }
}

@Suite struct MulticamExportTests {
    func segment(_ number: Int, file: String, tc: String, host: UInt64, frames: Int, format: VideoFormat = .hd1080p5994, state: SessionManifest.SegmentState = .finalized) -> SessionManifest.SegmentRecord {
        var record = SessionManifest.SegmentRecord(number: number, workingFile: "\(file).part.mov", finalFile: "\(file).mov", indexFile: "i", logFile: "l", format: format, codec: .proResLT, audioChannels: 16, startTimecode: tc, timecodeIsEmbedded: false, startHostNanos: host)
        record.frames = frames
        record.state = state
        return record
    }

    func manifest() -> SessionManifest {
        var manifest = SessionManifest(name: "Game & Show", createdAt: Date(timeIntervalSince1970: 0), createdAtHostNanos: 0)
        var a = SessionManifest.InputRecord(id: "a", label: "Cam 1")
        a.segments = [segment(1, file: "Cam_1/Cam_1_0001", tc: "01:00:00;04", host: 1_000_000_000, frames: 600)]
        var b = SessionManifest.InputRecord(id: "b", label: "Cam 2")
        b.segments = [
            segment(1, file: "Cam_2/Cam_2_0001", tc: "01:00:01;04", host: 2_001_000_000, frames: 300),
            segment(2, file: "Cam_2/Cam_2_0002", tc: "01:00:10;04", host: 11_010_000_000, frames: 120, state: .finalizeFailed),
        ]
        manifest.inputs = [a, b]
        return manifest
    }

    func plan() throws -> MulticamPlan {
        try #require(MulticamPlan(manifest: manifest(), sessionDirectory: "/rec/My Session"))
    }

    @Test func positionsComeFromHostTime() throws {
        let plan = try plan()
        #expect(plan.angles[0].clips[0].offsetFrames == 0)
        #expect(plan.angles[1].clips[0].offsetFrames == 60)
        #expect(plan.angles[1].clips[1].offsetFrames == 600)
        #expect(plan.startTimecode.string == "01:00:00;04")
    }

    @Test func unfinalizedSegmentsPointAtTheWorkingFile() throws {
        #expect(try plan().angles[1].clips[1].fileName == "Cam_2_0002.part.mov")
    }

    @Test func totalCoversTheLastClip() throws {
        #expect(try plan().totalFrames == 720)
    }

    @Test func emptySessionHasNoPlan() {
        #expect(MulticamPlan(manifest: SessionManifest(name: "x", createdAt: Date(), createdAtHostNanos: 0), sessionDirectory: "/x") == nil)
    }

    @Test func sequenceFollowsTheMostCommonFormat() throws {
        var manifest = manifest()
        manifest.inputs[1].segments = [segment(1, file: "c", tc: "00:00:00:00", host: 1_000_000_000, frames: 5, format: VideoFormat(width: 1280, height: 720, frameRate: Rational(50, 1)))]
        #expect(try #require(MulticamPlan(manifest: manifest, sessionDirectory: "/r")).format == .hd1080p5994)
    }

    @Test func mixedRatesScaleOntoTheTimeline() throws {
        var manifest = manifest()
        manifest.inputs[1].segments = [segment(1, file: "c", tc: "00:00:00:00", host: 1_000_000_000, frames: 100, format: VideoFormat(width: 1280, height: 720, frameRate: Rational(30000, 1001)))]
        #expect(try #require(MulticamPlan(manifest: manifest, sessionDirectory: "/r")).angles[1].clips[0].timelineFrames == 200)
    }

    @Test func parsesTimecodeStrings() {
        let rate = Rational(60000, 1001)
        #expect(Timecode(string: "01:02:03;04", frameRate: rate)?.frameCount == 223_160)
        #expect(Timecode(string: "01:02:03;04", frameRate: rate)?.isDropFrame == true)
        #expect(Timecode(string: "garbage", frameRate: rate) == nil)
    }

    @Test func xmlIsEscapedAndWellFormed() throws {
        let plan = try plan()
        let fcpxml = MulticamExporter.fcpxml(plan)
        #expect(fcpxml.contains("Game &amp; Show"))
        #expect(fcpxml.contains("file:///rec/My%20Session/"))
        _ = try XMLDocument(xmlString: fcpxml)
        _ = try XMLDocument(xmlString: MulticamExporter.fcp7XML(plan))
    }

    @Test func fcp7PathsUseLocalhost() throws {
        #expect(MulticamExporter.fcp7XML(try plan()).contains("file://localhost/rec/My%20Session/"))
    }

    @Test func edlLinesUpAgainstTheSequence() throws {
        let plan = try plan()
        let edl = MulticamExporter.edl(plan, angle: plan.angles[1])
        #expect(edl.contains("FCM: DROP FRAME"))
        #expect(edl.contains("001  CAM2     AV    C        01:00:01;04 01:00:06;04 01:00:01;04 01:00:06;04"))
        #expect(edl.contains("* FROM CLIP NAME: Cam_2_0001.mov"))
    }

    @Test func oneFilePerToolAndAnEDLPerInput() throws {
        let names = MulticamExporter.files(for: try plan()).map(\.name)
        #expect(names.filter { $0.hasSuffix(".edl") }.count == 2)
        #expect(names.contains { $0.hasSuffix(".fcpxml") })
        #expect(names.contains { $0.hasSuffix(".xml") })
        #expect(names.allSatisfy { !$0.contains("&") && !$0.contains(" ") })
    }
}

@Suite struct ControlAPITests {
    func request(_ method: String, _ path: String, headers: String = "Host: 127.0.0.1:9455\r\n", body: String = "") -> ControlRequest? {
        let length = body.isEmpty ? "" : "Content-Length: \(body.utf8.count)\r\n"
        let raw = "\(method) \(path) HTTP/1.1\r\n\(headers)\(length)\r\n\(body)"
        if case .request(let parsed) = ControlRequest.parse(Data(raw.utf8)) { return parsed }
        return nil
    }

    func route(_ method: String, _ path: String, headers: String = "Host: 127.0.0.1:9455\r\n", body: String = "") throws -> ControlRouter.Result {
        ControlRouter.route(try #require(request(method, path, headers: headers, body: body)))
    }

    @Test func routesCommands() throws {
        #expect(try route("GET", "/api/v1/status") == .command(.status))
        #expect(try route("POST", "/api/v1/record/start") == .command(.startRecording))
        #expect(try route("POST", "/api/v1/record/stop") == .command(.stopRecording))
        #expect(try route("POST", "/api/v1/inputs/cam%201/arm") == .command(.setArmed(inputID: "cam 1", armed: true)))
        #expect(try route("POST", "/api/v1/inputs/cam1/disarm") == .command(.setArmed(inputID: "cam1", armed: false)))
    }

    @Test func markerReadsItsLabel() throws {
        #expect(try route("POST", "/api/v1/marker", body: "{\"label\":\"Goal\"}") == .command(.addMarker(label: "Goal")))
        #expect(try route("POST", "/api/v1/marker") == .command(.addMarker(label: "Marker")))
        #expect(try route("POST", "/api/v1/marker", body: "not json") == .command(.addMarker(label: "Marker")))
    }

    func status(_ result: ControlRouter.Result) -> Int? {
        if case .rejected(let response) = result { return response.status }
        return nil
    }

    @Test func browsersAreRefused() throws {
        #expect(status(try route("POST", "/api/v1/record/stop", headers: "Host: 127.0.0.1:9455\r\nOrigin: https://evil.example\r\n")) == 403)
    }

    @Test func dnsRebindingIsRefused() throws {
        #expect(status(try route("POST", "/api/v1/record/stop", headers: "Host: evil.example\r\n")) == 403)
        #expect(status(try route("POST", "/api/v1/record/stop", headers: "")) == 403)
    }

    @Test func acceptsEveryLoopbackHostForm() throws {
        for host in ["localhost:9455", "127.0.0.1", "[::1]:9455"] {
            #expect(try route("GET", "/api/v1/status", headers: "Host: \(host)\r\n") == .command(.status))
        }
    }

    @Test func wrongMethodAndUnknownPaths() throws {
        #expect(status(try route("GET", "/api/v1/record/stop")) == 405)
        #expect(status(try route("POST", "/nope")) == 404)
    }

    @Test func parserWaitsForTheWholeBody() {
        let raw = "POST /api/v1/marker HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc"
        #expect(ControlRequest.parse(Data(raw.utf8)) == .incomplete)
        #expect(ControlRequest.parse(Data("GET /a".utf8)) == .incomplete)
    }

    @Test func parserRejectsGarbageAndOversizedRequests() {
        #expect(ControlRequest.parse(Data("nonsense\r\n\r\n".utf8)) == .invalid)
        #expect(ControlRequest.parse(Data(repeating: 65, count: ControlRequest.maximumSize + 1)) == .invalid)
        #expect(ControlRequest.parse(Data("GET / HTTP/1.1\r\nContent-Length: nope\r\n\r\n".utf8)) == .invalid)
    }

    @Test func responsesAreValidHTTP() {
        let text = String(decoding: ControlResponse(status: 404, error: "x").serialized, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(text.contains("Connection: close"))
    }
}
