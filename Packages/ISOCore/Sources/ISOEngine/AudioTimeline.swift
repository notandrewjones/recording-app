import Foundation
import ISOCore

/// One input's audio, on the same frame timeline as its video ring (`FrameRing.Metadata.timelineFrame`).
///
/// Each packet goes where the card's timestamp says it belongs, measured from the frame it came with, so a
/// packet delivered a frame late still lands under its own picture. A packet that belongs within a few
/// milliseconds of where the last one ended follows straight on from it: the card splits audio into frames
/// on its own cadence, 800 or 801 samples at 59.94, and placing each one exactly would click wherever its
/// cadence and ours disagree by a sample. Where the card sent nothing the timeline holds silence. This is the audio counterpart of a repeated frame: a MOV needs continuous audio, so a hole
/// has to hold something.
///
/// Audio stays readable up to `lagSamples` behind the newest frame whether or not any arrived, and filling it
/// never waits on the video ring. Together those mean ffmpeg, which will not read video far ahead of audio,
/// can always get the audio it needs to keep reading video. When audio came only with frames the ring had room
/// for, a full ring starved ffmpeg of audio and it froze (2026-11-22).
///
/// One capture thread writes. One segment's audio thread reads at a time, through a `Reader`.
public final class AudioTimeline: @unchecked Sendable {
    public struct Stats: Hashable, Sendable {
        /// Audio packets received, with a frame or on their own.
        public var packets = 0
        /// Frames that arrived with no audio.
        public var framesWithoutAudio = 0
        /// Packets that arrived without a picture.
        public var audioOnlyPackets = 0
        /// Packets timed apart from the frame they came with, such as one delivered a frame late.
        public var offsetPackets = 0
        /// Packets that did not follow on from the one before: after a gap, or overlapping it.
        public var discontinuities = 0
        /// Samples of silence put where the card sent no audio.
        public var silentSamples: Int64 = 0
        /// Samples thrown away because their place had already gone to a file, or could not be found.
        public var lateSamples: Int64 = 0
        /// Samples lost because the writer fell so far behind that newer audio replaced them.
        public var overrunSamples: Int64 = 0

        public init() {}

        /// Whether anything other than one packet per frame, timed with it, happened.
        public var hasIrregularities: Bool {
            framesWithoutAudio > 0 || audioOnlyPackets > 0 || offsetPackets > 0 || discontinuities > 0
                || silentSamples > 0 || lateSamples > 0 || overrunSamples > 0
        }

        public static func - (lhs: Stats, rhs: Stats) -> Stats {
            var result = Stats()
            result.packets = lhs.packets - rhs.packets
            result.framesWithoutAudio = lhs.framesWithoutAudio - rhs.framesWithoutAudio
            result.audioOnlyPackets = lhs.audioOnlyPackets - rhs.audioOnlyPackets
            result.offsetPackets = lhs.offsetPackets - rhs.offsetPackets
            result.discontinuities = lhs.discontinuities - rhs.discontinuities
            result.silentSamples = lhs.silentSamples - rhs.silentSamples
            result.lateSamples = lhs.lateSamples - rhs.lateSamples
            result.overrunSamples = lhs.overrunSamples - rhs.overrunSamples
            return result
        }

        public static func + (lhs: Stats, rhs: Stats) -> Stats {
            var result = lhs
            result.packets += rhs.packets
            result.framesWithoutAudio += rhs.framesWithoutAudio
            result.audioOnlyPackets += rhs.audioOnlyPackets
            result.offsetPackets += rhs.offsetPackets
            result.discontinuities += rhs.discontinuities
            result.silentSamples += rhs.silentSamples
            result.lateSamples += rhs.lateSamples
            result.overrunSamples += rhs.overrunSamples
            return result
        }

        /// For a session file: "3600 packets, 2 frames without audio, 0 without a picture, 1 timed apart from
        /// its frame, 2 discontinuities; silence 0.033 s, late 0 s, overrun 0 s".
        public var description: String {
            func seconds(_ samples: Int64) -> String {
                samples == 0 ? "0 s" : String(format: "%.3f s", Double(samples) / Double(AudioFormat.sampleRate))
            }
            return "\(packets) packets, \(framesWithoutAudio) frames without audio, \(audioOnlyPackets) without a picture, "
                + "\(offsetPackets) timed apart from its frame, \(discontinuities) discontinuities; "
                + "silence \(seconds(silentSamples)), late \(seconds(lateSamples)), overrun \(seconds(overrunSamples))"
        }
    }

    public enum ReadResult: Equatable {
        case samples(Int)
        case timedOut
        /// The reader reached the end it was given, or was cancelled.
        case finished
    }

    public let channels: Int
    public let frameRate: Rational
    public let bytesPerSample: Int
    public let capacitySamples: Int64
    /// How far behind the newest frame the writer may run on silence when audio has not come. Long enough for
    /// a packet the card delivers a frame or two late, and short against the tenth of a second ffmpeg lets
    /// video run ahead of audio.
    public let lagSamples: Int64
    /// How far a packet may belong from where the last one ended and still follow on from it. Wider than any
    /// cadence difference, narrower than a frame, and short enough that sync never drifts noticeably.
    public let snapSamples: Int64
    public var memoryLock: WiredBuffer.MemoryLock { buffer.memoryLock }
    public var storageBytes: Int { buffer.bytes }

    private let buffer: WiredBuffer
    private let condition = NSCondition()
    /// End of the furthest sample written.
    private var head: Int64 = 0
    /// End of the newest frame's audio. Video arriving moves time on, whether or not audio came with it.
    private var clock: Int64 = 0
    /// The furthest the current reader has read. Audio for earlier than this is too late to use.
    private var readHorizon: Int64 = 0
    /// The card's usual gap between a packet's time and its frame's, in stream ticks, from the first packet.
    /// Placement follows changes from it, so a card with a fixed offset records as it always has.
    private var baselineTicks: Int64?
    /// The newest frame, for placing audio that arrives without one.
    private var anchor: (frame: UInt64, streamTime: Int64)?
    private var stats = Stats()

    /// - Parameter capacitySeconds: how much audio is kept. It must cover a stalled writer until it is
    ///   replaced, so a new segment still finds the audio for the frames it carries over.
    public init(channels: Int, frameRate: Rational, capacitySeconds: Double, lagFrames: UInt64 = 4, budget: MemoryLockBudget = .shared) {
        precondition(channels > 0, "An audio timeline needs at least one channel")
        self.channels = channels
        self.frameRate = frameRate
        bytesPerSample = channels * 4
        capacitySamples = max(Int64(capacitySeconds * Double(AudioFormat.sampleRate)), 1)
        lagSamples = Int64(AudioCadence.cumulativeSamples(throughFrames: lagFrames, frameRate: frameRate))
        let frameSamples = Int64(AudioCadence.cumulativeSamples(throughFrames: 1, frameRate: frameRate))
        snapSamples = min(Int64(AudioFormat.sampleRate) / 100, frameSamples / 2)
        buffer = WiredBuffer(bytes: Int(capacitySamples) * bytesPerSample, budget: budget)
    }

    /// Where a frame of the timeline starts, in samples.
    public func position(ofFrame frame: UInt64) -> Int64 {
        Int64(AudioCadence.cumulativeSamples(throughFrames: frame, frameRate: frameRate))
    }

    public var currentStats: Stats {
        condition.lock()
        defer { condition.unlock() }
        return stats
    }

    /// Starts reading at a frame's audio. Only the newest reader's position counts: a new segment can start
    /// behind where the last one read, with frames it carries over.
    public func makeReader(startingAtFrame frame: UInt64) -> Reader {
        let start = position(ofFrame: frame)
        condition.lock()
        readHorizon = start
        condition.unlock()
        return Reader(timeline: self, start: start)
    }

    // MARK: Capture thread

    /// A video frame took a place on the timeline, with or without audio. Call it for every frame given a
    /// timeline number, kept or dropped, so time moves on even when the card sends no audio.
    public func frameArrived(timelineFrame frame: UInt64, streamTime: Int64, streamTimeScale: Int64, audio: UnsafeRawPointer?, sampleFrames: Int, audioStreamTime: Int64?) {
        condition.lock()
        anchor = (frame, streamTime)
        if let audio, sampleFrames > 0 {
            var ticks: Int64 = 0
            if let audioStreamTime {
                let offset = audioStreamTime - streamTime
                let baseline = baselineTicks ?? offset
                // More than a second out is a new clock, not a late packet. Its offset becomes the usual one.
                if abs(offset - baseline) > streamTimeScale {
                    baselineTicks = offset
                } else {
                    baselineTicks = baseline
                    ticks = offset - baseline
                }
            }
            if ticks != 0 { stats.offsetPackets += 1 }
            store(at: position(ofFrame: frame, plusTicks: ticks, scale: streamTimeScale), audio, Int64(sampleFrames))
        } else {
            stats.framesWithoutAudio += 1
        }
        clock = max(clock, position(ofFrame: frame + 1))
        condition.broadcast()
        condition.unlock()
    }

    /// Audio the card delivered without a picture, placed by its time against the newest frame.
    public func audioArrived(_ audio: UnsafeRawPointer, sampleFrames: Int, streamTime: Int64, streamTimeScale: Int64) {
        guard sampleFrames > 0 else { return }
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        stats.audioOnlyPackets += 1
        // More than a couple of seconds from the newest frame, it belongs to another clock, such as one the
        // card has just restarted, and there is no telling where it goes.
        guard let anchor, streamTimeScale > 0 else {
            stats.packets += 1
            stats.lateSamples += Int64(sampleFrames)
            return
        }
        let ticks = streamTime - anchor.streamTime - (baselineTicks ?? 0)
        guard abs(ticks) <= 2 * streamTimeScale else {
            stats.packets += 1
            stats.lateSamples += Int64(sampleFrames)
            return
        }
        store(at: position(ofFrame: anchor.frame, plusTicks: ticks, scale: streamTimeScale), audio, Int64(sampleFrames))
    }

    /// Where audio timed `ticks` after a frame belongs. Worked out from the frame's exact place in samples,
    /// not its rounded one, so a packet timed one frame early lands exactly where that frame's audio starts.
    private func position(ofFrame frame: UInt64, plusTicks ticks: Int64, scale: Int64) -> Int64 {
        let base = position(ofFrame: frame)
        guard ticks != 0, scale > 0 else { return base }
        let rate = Int64(AudioFormat.sampleRate)
        let numerator = Int64(frameRate.numerator)
        let remainder = Int64((frame * UInt64(rate) * UInt64(frameRate.denominator)) % UInt64(numerator))
        // base + floor(remainder / numerator + ticks * rate / scale), over a common denominator.
        let top = remainder * scale + ticks * rate * numerator
        let bottom = numerator * scale
        let quotient = top / bottom
        return base + (top % bottom < 0 ? quotient - 1 : quotient)
    }

    /// Puts samples where they belong on the timeline, `start`, or straight after the last packet if that is
    /// within `snapSamples`. The caller holds the lock.
    private func store(at belongs: Int64, _ source: UnsafeRawPointer, _ count: Int64) {
        stats.packets += 1
        var start = belongs
        if abs(belongs - head) <= snapSamples {
            start = head
        } else {
            stats.discontinuities += 1
        }
        var source = source
        var remaining = count

        // Too late to use: a file already has this stretch, it has fallen out of the buffer, or it is before
        // the timeline began.
        let floor = max(readHorizon, head - capacitySamples, 0)
        if start < floor {
            let skip = min(remaining, floor - start)
            stats.lateSamples += skip
            start += skip
            source = source.advanced(by: Int(skip) * bytesPerSample)
            remaining -= skip
        }
        guard remaining > 0 else { return }
        // More than the buffer holds: only the newest part can be kept.
        if remaining > capacitySamples {
            let skip = remaining - capacitySamples
            stats.overrunSamples += skip
            start += skip
            source = source.advanced(by: Int(skip) * bytesPerSample)
            remaining -= skip
        }

        if start > head {
            // Nothing came for the stretch since the last packet, so it is silence. Clearing it also stops a
            // reader finding what the buffer held a lap ago.
            let unread = max(head, readHorizon)
            if start > unread { stats.silentSamples += start - unread }
            fill(from: max(head, start - capacitySamples), to: start, with: nil)
        }
        fill(from: start, to: start + remaining, with: source)
        head = max(head, start + remaining)
    }

    /// Copies `source` into the buffer at timeline positions `start..<end`, or zeroes them when it is nil.
    private func fill(from start: Int64, to end: Int64, with source: UnsafeRawPointer?) {
        var position = start
        var source = source
        while position < end {
            let index = position % capacitySamples
            let count = min(end - position, capacitySamples - index)
            let destination = buffer.pointer.advanced(by: Int(index) * bytesPerSample)
            let bytes = Int(count) * bytesPerSample
            if let current = source {
                destination.copyMemory(from: current, byteCount: bytes)
                source = current.advanced(by: bytes)
            } else {
                memset(destination, 0, bytes)
            }
            position += count
        }
    }

    /// Copies timeline positions `start..<start + count` out, as silence where nothing is held. The caller
    /// holds the lock.
    private func copyOut(from start: Int64, count: Int64, to destination: UnsafeMutableRawPointer) {
        var position = start
        var output = destination
        var remaining = count
        let oldest = max(head - capacitySamples, 0)
        while remaining > 0 {
            let run: Int64
            if position >= head {
                run = remaining
                memset(output, 0, Int(run) * bytesPerSample)
                stats.silentSamples += run
            } else if position < oldest {
                run = min(remaining, oldest - position)
                memset(output, 0, Int(run) * bytesPerSample)
                stats.overrunSamples += run
            } else {
                let index = position % capacitySamples
                run = min(remaining, head - position, capacitySamples - index)
                output.copyMemory(from: buffer.pointer.advanced(by: Int(index) * bytesPerSample), byteCount: Int(run) * bytesPerSample)
            }
            position += run
            output = output.advanced(by: Int(run) * bytesPerSample)
            remaining -= run
        }
    }

    /// Reads one segment's audio in order from where its first frame sits on the timeline.
    public final class Reader: @unchecked Sendable {
        private let timeline: AudioTimeline
        private let start: Int64
        private var position: Int64
        private var end: Int64?
        private var cancelled = false

        fileprivate init(timeline: AudioTimeline, start: Int64) {
            self.timeline = timeline
            self.start = start
            position = start
        }

        /// Samples read so far, from the segment's start.
        public var samplesRead: Int64 {
            timeline.condition.lock()
            defer { timeline.condition.unlock() }
            return position - start
        }

        /// Audio thread. Copies up to `maxSamples` into `destination`, waiting up to `timeout` for audio, or for
        /// time to move on far enough that silence is the answer.
        public func read(into destination: UnsafeMutableRawPointer, maxSamples: Int, timeout: TimeInterval) -> ReadResult {
            let timeline = timeline
            timeline.condition.lock()
            defer { timeline.condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if cancelled { return .finished }
                let limit = end ?? max(timeline.head, timeline.clock - timeline.lagSamples)
                if position < limit {
                    let count = min(limit - position, Int64(maxSamples))
                    timeline.copyOut(from: position, count: count, to: destination)
                    position += count
                    timeline.readHorizon = max(timeline.readHorizon, position)
                    return .samples(Int(count))
                }
                if end != nil { return .finished }
                if !timeline.condition.wait(until: deadline) { return .timedOut }
            }
        }

        /// The segment's video ended just before `frame`. The reader delivers audio up to there, as silence
        /// where none came, and then finishes, so audio and video end together.
        public func finish(atFrame frame: UInt64) {
            let target = timeline.position(ofFrame: frame)
            timeline.condition.lock()
            end = target
            timeline.condition.broadcast()
            timeline.condition.unlock()
        }

        public func cancel() {
            timeline.condition.lock()
            cancelled = true
            timeline.condition.broadcast()
            timeline.condition.unlock()
        }
    }
}
