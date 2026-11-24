import Foundation
import ISOCore
import Testing
@testable import ISOEngine

@Suite struct FrameRingTests {
    let format = VideoFormat(width: 48, height: 2, frameRate: Rational(50, 1))

    func ring(slots: Int = 4) -> FrameRing {
        FrameRing(format: format, slotCount: slots)
    }

    func frame(_ value: UInt8) -> [UInt8] {
        Array(repeating: value, count: format.frameBytes)
    }

    func metadata() -> FrameRing.Metadata {
        FrameRing.Metadata(hostTimeNanos: 1, streamTime: 2, timecode: nil)
    }

    @discardableResult
    func push(_ ring: FrameRing, _ value: UInt8) -> Bool {
        ring.push(video: frame(value), metadata: metadata()).accepted
    }

    func entry(_ ring: FrameRing) -> FrameRing.Entry? {
        if case .entry(let entry) = ring.next(timeout: 0) { return entry }
        return nil
    }

    func firstByte(_ entry: FrameRing.Entry?) -> UInt8? {
        entry?.video.load(as: UInt8.self)
    }

    @Test func deliversInOrder() {
        let ring = ring()
        push(ring, 1)
        push(ring, 2)
        #expect(firstByte(entry(ring)) == 1)
        ring.advance()
        #expect(firstByte(entry(ring)) == 2)
    }

    @Test func overflowIsCarriedOnTheNextFrame() {
        let ring = ring(slots: 4)
        #expect(push(ring, 1))
        #expect(push(ring, 2))
        #expect(push(ring, 3))
        #expect(!push(ring, 4))
        #expect(!push(ring, 5))
        ring.advance()
        #expect(push(ring, 6))
        ring.advance()
        ring.advance()
        #expect(entry(ring)?.missingBefore == 2)
    }

    /// Audio is placed by these numbers, so a dropped frame must use one up like a kept one.
    @Test func everyFrameOfferedTakesATimelineNumber() {
        let ring = ring(slots: 3)
        let first = ring.push(video: frame(1), metadata: metadata())
        let second = ring.push(video: frame(2), metadata: metadata())
        let dropped = ring.push(video: frame(3), metadata: metadata())
        ring.markMissing(4)
        ring.advance()
        let after = ring.push(video: frame(4), metadata: metadata())
        #expect([first, second, dropped, after].map(\.timelineFrame) == [0, 1, 2, 7])
        #expect([first, second, dropped, after].map(\.accepted) == [true, true, false, true])
        ring.advance()
        let entry = entry(ring)
        #expect(entry?.metadata.timelineFrame == 7)
        #expect(entry?.missingBefore == 5)
    }

    @Test func previousFrameSurvivesWhileTheRingRefills() {
        let ring = ring(slots: 4)
        push(ring, 1)
        ring.advance()
        #expect(push(ring, 2))
        #expect(push(ring, 3))
        #expect(push(ring, 4))
        #expect(!push(ring, 5))
        #expect(ring.previousVideoFrame?.load(as: UInt8.self) == 1)
    }

    @Test func missingFramesAttachToTheNextFrame() {
        let ring = ring()
        ring.markMissing(3)
        push(ring, 1)
        #expect(entry(ring)?.missingBefore == 3)
        #expect(entry(ring)?.metadata.timelineFrame == 3)
    }

    @Test func closeDrainsBeforeReportingClosed() {
        let ring = ring()
        push(ring, 1)
        ring.close()
        #expect(firstByte(entry(ring)) == 1)
        ring.advance()
        if case .closed = ring.next(timeout: 0) {} else { Issue.record("expected closed") }
    }

    @Test func emptyRingTimesOut() {
        if case .timedOut = ring().next(timeout: 0.01) {} else { Issue.record("expected timeout") }
    }

    @Test func ringIsWiredIntoMemory() {
        let budget = MemoryLockBudget(limitBytes: 1 << 30)
        var ring: FrameRing? = FrameRing(format: format, slotCount: 4, budget: budget)
        #expect(ring?.memoryLock == .locked)
        #expect(budget.usedBytes == ring?.storageBytes)
        ring = nil
        #expect(budget.usedBytes == 0)
    }

    @Test func ringOverBudgetStillWorksUnlocked() {
        let budget = MemoryLockBudget(limitBytes: 16)
        let ring = FrameRing(format: format, slotCount: 4, budget: budget)
        #expect(ring.memoryLock == .overBudget)
        #expect(budget.usedBytes == 0)
        push(ring, 7)
        #expect(firstByte(entry(ring)) == 7)
    }
}

@Suite struct AudioTimelineTests {
    /// 59.94, where frames alternate between 800 and 801 samples, so rounding mistakes show.
    let rate = Rational(60000, 1001)
    let scale: Int64 = 240_000
    let ticksPerFrame: Int64 = 4004

    func timeline(seconds: Double = 2, budget: MemoryLockBudget = MemoryLockBudget(limitBytes: 1 << 30)) -> AudioTimeline {
        AudioTimeline(channels: 1, frameRate: rate, capacitySeconds: seconds, budget: budget)
    }

    func samples(_ frame: UInt64) -> Int {
        AudioCadence.sampleCount(forFrame: frame, frameRate: rate)
    }

    /// One channel, each sample holding the number of the frame it was captured with, plus one, so silence
    /// (zero) is told apart from frame 0.
    func packet(frames: ClosedRange<UInt64>) -> [Int32] {
        frames.flatMap { frame in Array(repeating: Int32(frame + 1), count: samples(frame)) }
    }

    func arrive(_ timeline: AudioTimeline, frame: UInt64, audio: [Int32]?, timedAt audioFrame: UInt64? = nil) {
        let streamTime = Int64(frame) * ticksPerFrame
        let audioTime = audioFrame.map { Int64($0) * ticksPerFrame } ?? streamTime
        if let audio {
            audio.withUnsafeBytes {
                timeline.frameArrived(timelineFrame: frame, streamTime: streamTime, streamTimeScale: scale, audio: $0.baseAddress, sampleFrames: audio.count, audioStreamTime: audioTime)
            }
        } else {
            timeline.frameArrived(timelineFrame: frame, streamTime: streamTime, streamTimeScale: scale, audio: nil, sampleFrames: 0, audioStreamTime: nil)
        }
    }

    /// Reads until the reader would have to wait.
    func readAvailable(_ reader: AudioTimeline.Reader) -> [Int32] {
        var output: [Int32] = []
        var chunk = [Int32](repeating: -1, count: 4096)
        while true {
            let result = chunk.withUnsafeMutableBytes { reader.read(into: $0.baseAddress!, maxSamples: 4096, timeout: 0) }
            guard case .samples(let count) = result else { return output }
            output += chunk[0..<count]
        }
    }

    /// Which frame each run of samples came from, with 0 for silence: [(frame + 1 or 0, samples)].
    func runs(_ samples: [Int32]) -> [(Int32, Int)] {
        var result: [(Int32, Int)] = []
        for sample in samples {
            if let last = result.last, last.0 == sample {
                result[result.count - 1].1 += 1
            } else {
                result.append((sample, 1))
            }
        }
        return result
    }

    @Test func packetsInOrderReadBackExactly() {
        let timeline = timeline()
        let reader = timeline.makeReader(startingAtFrame: 0)
        for frame in UInt64(0)..<10 { arrive(timeline, frame: frame, audio: packet(frames: frame...frame)) }
        reader.finish(atFrame: 10)
        let output = readAvailable(reader)
        #expect(output == packet(frames: 0...9))
        #expect(!timeline.currentStats.hasIrregularities)
    }

    /// The 2026-11-22 failure: frames with no audio left ffmpeg short of it. Time moves on regardless, and
    /// the missing frame's audio is silence of exactly its length.
    @Test func aFrameWithoutAudioBecomesSilenceOfItsLength() {
        let timeline = timeline()
        let reader = timeline.makeReader(startingAtFrame: 0)
        for frame in UInt64(0)..<10 {
            arrive(timeline, frame: frame, audio: frame == 4 ? nil : packet(frames: frame...frame))
        }
        reader.finish(atFrame: 10)
        let output = readAvailable(reader)
        var expected = packet(frames: 0...9)
        let start = Int(timeline.position(ofFrame: 4))
        expected.replaceSubrange(start..<(start + samples(4)), with: Array(repeating: 0, count: samples(4)))
        #expect(output == expected)
        let stats = timeline.currentStats
        #expect(stats.framesWithoutAudio == 1)
        #expect(stats.discontinuities == 1)
        #expect(stats.silentSamples == Int64(samples(4)))
    }

    /// A packet delivered a frame late, holding two frames' audio, lands under its own picture with nothing
    /// lost and no silence.
    @Test func aLatePacketLandsUnderItsOwnFrame() {
        let timeline = timeline()
        let reader = timeline.makeReader(startingAtFrame: 0)
        for frame in UInt64(0)..<10 {
            switch frame {
            case 4: arrive(timeline, frame: 4, audio: nil)
            case 5: arrive(timeline, frame: 5, audio: packet(frames: 4...5), timedAt: 4)
            default: arrive(timeline, frame: frame, audio: packet(frames: frame...frame))
            }
        }
        reader.finish(atFrame: 10)
        #expect(readAvailable(reader) == packet(frames: 0...9))
        let stats = timeline.currentStats
        #expect(stats.offsetPackets == 1)
        #expect(stats.silentSamples == 0)
        #expect(stats.lateSamples == 0)
    }

    /// The card splits audio into frames on its own cadence, which need not line up with the timeline's. Its
    /// packets still play back to back, with no sample of silence or overlap where the two disagree.
    @Test func aCardOnAnotherCadenceStaysSeamless() {
        let timeline = timeline()
        let reader = timeline.makeReader(startingAtFrame: 0)
        // The card's frame N is the timeline's frame N - 2, so their 800s and 801s fall in different places.
        var expected: [Int32] = []
        for frame in UInt64(0)..<20 {
            let audio = Array(repeating: Int32(frame + 1), count: samples(frame + 2))
            expected += audio
            arrive(timeline, frame: frame, audio: audio)
            _ = readAvailable(reader)
        }
        let second = timeline.makeReader(startingAtFrame: 0)
        second.finish(atFrame: 20)
        let output = readAvailable(second)
        #expect(output.count == Int(timeline.position(ofFrame: 20)))
        #expect(Array(output.prefix(expected.count)) == Array(expected.prefix(output.count)))
        let stats = timeline.currentStats
        #expect(stats.discontinuities == 0)
        #expect(stats.lateSamples == 0)
        #expect(stats.silentSamples <= 1, "at most where the two cadences end apart")
    }

    /// Audio delivered without a picture is placed by its time against the newest frame.
    @Test func audioWithoutAPictureIsPlacedByItsTime() {
        let timeline = timeline()
        let reader = timeline.makeReader(startingAtFrame: 0)
        for frame in UInt64(0)..<10 {
            if frame == 4 {
                let audio = packet(frames: 4...4)
                audio.withUnsafeBytes {
                    timeline.audioArrived($0.baseAddress!, sampleFrames: audio.count, streamTime: 4 * ticksPerFrame, streamTimeScale: scale)
                }
            } else {
                arrive(timeline, frame: frame, audio: packet(frames: frame...frame))
            }
        }
        reader.finish(atFrame: 10)
        #expect(readAvailable(reader) == packet(frames: 0...9))
        #expect(timeline.currentStats.audioOnlyPackets == 1)
    }

    /// A packet arriving twice, or two packets for the same time, overwrite rather than add, so audio never
    /// runs longer than the picture.
    @Test func aRepeatedPacketDoesNotLengthenTheAudio() {
        let timeline = timeline()
        let reader = timeline.makeReader(startingAtFrame: 0)
        for frame in UInt64(0)..<10 {
            arrive(timeline, frame: frame, audio: packet(frames: frame...frame))
            if frame == 3 { arrive(timeline, frame: frame, audio: packet(frames: frame...frame)) }
        }
        reader.finish(atFrame: 10)
        #expect(readAvailable(reader) == packet(frames: 0...9))
    }

    /// The reader waits a few frames for audio that is late, then moves on with silence, so ffmpeg is never
    /// left without audio for longer than that.
    @Test func readerGivesSilenceOnceTimeHasMovedOn() {
        let timeline = timeline()
        let reader = timeline.makeReader(startingAtFrame: 0)
        arrive(timeline, frame: 0, audio: packet(frames: 0...0))
        #expect(readAvailable(reader).count == samples(0))
        for frame in UInt64(1)...3 { arrive(timeline, frame: frame, audio: nil) }
        #expect(readAvailable(reader).isEmpty, "still within the lag")
        for frame in UInt64(4)...8 { arrive(timeline, frame: frame, audio: nil) }
        // Nine frames have gone by, so all but the last four frames' audio is due.
        let due = readAvailable(reader)
        #expect(due.count == Int(timeline.position(ofFrame: 9) - timeline.lagSamples) - samples(0))
        #expect(due.allSatisfy { $0 == 0 })
    }

    @Test func readerTimesOutAndIsWokenByAudio() {
        let timeline = timeline()
        let reader = timeline.makeReader(startingAtFrame: 0)
        var chunk = [Int32](repeating: 0, count: 2000)
        let empty = chunk.withUnsafeMutableBytes { reader.read(into: $0.baseAddress!, maxSamples: 2000, timeout: 0.01) }
        #expect(empty == .timedOut)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            self.arrive(timeline, frame: 0, audio: self.packet(frames: 0...0))
        }
        let woken = chunk.withUnsafeMutableBytes { reader.read(into: $0.baseAddress!, maxSamples: 2000, timeout: 2) }
        #expect(woken == .samples(samples(0)))
    }

    /// A stopped file's audio ends with its last picture, padded with silence if the card sent too little.
    @Test func finishPadsToTheLastFrame() {
        let timeline = timeline()
        let reader = timeline.makeReader(startingAtFrame: 0)
        for frame in UInt64(0)..<5 { arrive(timeline, frame: frame, audio: packet(frames: frame...frame)) }
        arrive(timeline, frame: 5, audio: nil)
        reader.finish(atFrame: 6)
        let output = readAvailable(reader)
        #expect(output.count == Int(timeline.position(ofFrame: 6)))
        #expect(Array(output.prefix(Int(timeline.position(ofFrame: 5)))) == packet(frames: 0...4))
        var chunk = [Int32](repeating: 0, count: 16)
        #expect(chunk.withUnsafeMutableBytes { reader.read(into: $0.baseAddress!, maxSamples: 16, timeout: 0) } == .finished)
    }

    /// After a crash, a new file starts at the first frame not yet written, behind where the last file's
    /// audio had got to, and still finds that audio.
    @Test func aNewReaderCanStartBehindTheLastOne() {
        let timeline = timeline()
        let first = timeline.makeReader(startingAtFrame: 0)
        for frame in UInt64(0)..<10 { arrive(timeline, frame: frame, audio: packet(frames: frame...frame)) }
        _ = readAvailable(first)
        first.cancel()
        let second = timeline.makeReader(startingAtFrame: 6)
        second.finish(atFrame: 10)
        #expect(readAvailable(second) == packet(frames: 6...9))
    }

    /// Audio is kept for `capacitySeconds`. A writer further behind than that gets silence, counted as lost,
    /// rather than audio from the wrong place.
    @Test func aWriterTooFarBehindGetsSilenceNotStaleAudio() {
        let timeline = timeline(seconds: 0.1)
        let reader = timeline.makeReader(startingAtFrame: 0)
        for frame in UInt64(0)..<20 { arrive(timeline, frame: frame, audio: packet(frames: frame...frame)) }
        reader.finish(atFrame: 20)
        let output = readAvailable(reader)
        #expect(output.count == Int(timeline.position(ofFrame: 20)))
        let kept = Int(timeline.capacitySamples)
        #expect(Array(output.suffix(kept)) == Array(packet(frames: 0...19).suffix(kept)))
        #expect(output.prefix(output.count - kept).allSatisfy { $0 == 0 })
        #expect(timeline.currentStats.overrunSamples == Int64(output.count - kept))
    }

    /// A gap clears what the buffer held a lap earlier, so a reader starting inside it hears silence.
    @Test func aGapNeverReplaysOldAudio() {
        let timeline = timeline(seconds: 0.1)
        let lap = UInt64(8)
        let reader = timeline.makeReader(startingAtFrame: 0)
        for frame in UInt64(0)..<lap { arrive(timeline, frame: frame, audio: packet(frames: frame...frame)) }
        _ = readAvailable(reader)
        reader.cancel()
        for frame in lap..<(lap + 4) { arrive(timeline, frame: frame, audio: nil) }
        arrive(timeline, frame: lap + 4, audio: packet(frames: (lap + 4)...(lap + 4)))
        let late = timeline.makeReader(startingAtFrame: lap)
        late.finish(atFrame: lap + 5)
        let output = readAvailable(late)
        let gap = Int(timeline.position(ofFrame: lap + 4) - timeline.position(ofFrame: lap))
        #expect(output.prefix(gap).allSatisfy { $0 == 0 })
        #expect(Array(output.suffix(from: gap)) == packet(frames: (lap + 4)...(lap + 4)))
    }

    @Test func audioTooLateForItsFileIsDropped() {
        let timeline = timeline()
        let reader = timeline.makeReader(startingAtFrame: 0)
        for frame in UInt64(0)..<10 { arrive(timeline, frame: frame, audio: frame == 2 ? nil : packet(frames: frame...frame)) }
        _ = readAvailable(reader)
        let late = packet(frames: 2...2)
        late.withUnsafeBytes {
            timeline.audioArrived($0.baseAddress!, sampleFrames: late.count, streamTime: 2 * ticksPerFrame, streamTimeScale: scale)
        }
        #expect(timeline.currentStats.lateSamples == Int64(late.count))
    }

    /// A card whose audio is always timed a little apart from its pictures records as it always did.
    @Test func aSteadyOffsetIsTheBaseline() {
        let timeline = timeline()
        let reader = timeline.makeReader(startingAtFrame: 0)
        for frame in UInt64(0)..<10 {
            let audio = packet(frames: frame...frame)
            audio.withUnsafeBytes {
                timeline.frameArrived(timelineFrame: frame, streamTime: Int64(frame) * ticksPerFrame, streamTimeScale: scale, audio: $0.baseAddress, sampleFrames: audio.count, audioStreamTime: Int64(frame) * ticksPerFrame - 1000)
            }
        }
        reader.finish(atFrame: 10)
        #expect(readAvailable(reader) == packet(frames: 0...9))
        #expect(timeline.currentStats.offsetPackets == 0)
    }

    @Test func timelineIsWiredAndReleased() {
        let budget = MemoryLockBudget(limitBytes: 1 << 30)
        var timeline: AudioTimeline? = timeline(seconds: 1, budget: budget)
        #expect(timeline?.memoryLock == .locked)
        #expect(budget.usedBytes == 48_000 * 4)
        timeline = nil
        #expect(budget.usedBytes == 0)
    }

    @Test func statsDescribeOnlyWhatHappened() {
        var stats = AudioTimeline.Stats()
        stats.packets = 3600
        stats.framesWithoutAudio = 2
        stats.silentSamples = 1601
        #expect(stats.hasIrregularities)
        #expect(stats.description == "3600 packets, 2 frames without audio, 0 without a picture, 0 timed apart from its frame, 0 discontinuities; silence 0.033 s, late 0 s, overrun 0 s")
        #expect(!AudioTimeline.Stats().hasIrregularities)
    }
}
