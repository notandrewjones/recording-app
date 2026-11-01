import Foundation
import ISOCore

/// Paced frames plus scripted faults. Stands in for a capture card anywhere above the SDK.
public final class SyntheticSource: @unchecked Sendable {
    public enum Fault: Hashable, Sendable {
        /// The source skips this many frames, as a card does when the host falls behind.
        case dropFrames(Int)
        case loseSignal(frames: Int)
        case changeFormat(VideoFormat)
        /// Frame delivery stops altogether for this long, as when hardware is unplugged.
        case stopDelivering(seconds: Double)
    }

    public static let streamTimeScale: Int64 = 240_000

    public private(set) var format: VideoFormat
    private let audioChannels: Int
    private let faults: [UInt64: Fault]
    private let timecodeStart: Timecode?
    private let realtime: Bool
    private let pool: SyntheticFramePool?
    private let lock = UnfairLock()
    private var cancelled = false
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    /// Sends one frame to whatever is consuming this source.
    public var onFrame: ((IngestFrame) -> Void)?

    /// - Parameter faults: keyed by delivered frame number.
    public init(format: VideoFormat = .hd1080p5994, audioChannels: Int = 16, timecodeStart: Timecode? = nil, faults: [UInt64: Fault] = [:], realtime: Bool = true, pool: SyntheticFramePool? = nil) {
        self.format = format
        self.audioChannels = audioChannels
        self.timecodeStart = timecodeStart
        self.faults = faults
        self.realtime = realtime
        self.pool = pool
    }

    public func start(frames limit: UInt64 = .max) {
        let thread = Thread { [self] in
            run(limit: limit)
            finished.signal()
        }
        thread.name = "synthetic-source"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    public func waitUntilFinished() {
        finished.wait()
    }

    private func run(limit: UInt64) {
        var buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: format.frameBytes, alignment: 64)
        defer { buffer.deallocate() }
        let audioCapacity = AudioCadence.maximumSamplesPerFrame(frameRate: format.frameRate) * max(audioChannels, 1) * 4
        let audio = UnsafeMutableRawPointer.allocate(byteCount: audioCapacity * 4, alignment: 16)
        defer { audio.deallocate() }

        var delivered: UInt64 = 0
        var cadenceFrame: UInt64 = 0
        var streamTicks: Int64 = 0
        var noSignalRemaining = 0
        var samplePhase = 0
        var nextDue = DispatchTime.now().uptimeNanoseconds

        while delivered < limit, !lock.withLock({ cancelled }) {
            if let fault = faults[delivered] {
                switch fault {
                case .dropFrames(let count):
                    streamTicks += Int64(count) * ticksPerFrame
                    cadenceFrame += UInt64(count)
                    nextDue += UInt64(count) * periodNanos
                case .loseSignal(let frames):
                    noSignalRemaining = frames
                case .changeFormat(let newFormat):
                    format = newFormat
                    buffer.deallocate()
                    buffer = .allocate(byteCount: newFormat.frameBytes, alignment: 64)
                case .stopDelivering(let seconds):
                    usleep(UInt32(seconds * 1_000_000))
                    nextDue = DispatchTime.now().uptimeNanoseconds
                }
            }

            let video: UnsafeRawPointer
            if let pool, pool.format == format {
                video = pool.frame(delivered)
            } else {
                SyntheticFrame.fill(buffer, format: format, frameNumber: delivered)
                video = UnsafeRawPointer(buffer.baseAddress!)
            }
            let samples = AudioCadence.sampleCount(forFrame: cadenceFrame, frameRate: format.frameRate)
            if audioChannels > 0 {
                Self.fillTone(audio, samples: samples, channels: audioChannels, phase: &samplePhase)
            }

            let frame = IngestFrame(
                format: format,
                video: video,
                audio: audioChannels > 0 ? UnsafeRawPointer(audio) : nil,
                audioSampleFrames: audioChannels > 0 ? samples : 0,
                hostTimeNanos: DispatchTime.now().uptimeNanoseconds,
                streamTime: streamTicks,
                streamTimeScale: Self.streamTimeScale,
                timecode: timecodeStart?.advanced(by: Int(cadenceFrame)),
                hasSignal: noSignalRemaining == 0
            )
            onFrame?(frame)

            if noSignalRemaining > 0 { noSignalRemaining -= 1 }
            delivered += 1
            cadenceFrame += 1
            streamTicks += ticksPerFrame

            if realtime {
                nextDue += periodNanos
                let now = DispatchTime.now().uptimeNanoseconds
                if nextDue > now { usleep(UInt32((nextDue - now) / 1000)) }
            }
        }
    }

    private var ticksPerFrame: Int64 {
        Self.streamTimeScale * format.frameRate.denominator / format.frameRate.numerator
    }

    private var periodNanos: UInt64 {
        UInt64(1_000_000_000 * format.frameRate.denominator / format.frameRate.numerator)
    }

    /// A 1 kHz tone, which is a whole number of samples at 48 kHz, so phase never jumps at a frame boundary.
    private static func fillTone(_ pointer: UnsafeMutableRawPointer, samples: Int, channels: Int, phase: inout Int) {
        let output = pointer.assumingMemoryBound(to: Int32.self)
        for sample in 0..<samples {
            let value = Int32(sin(Double((phase + sample) % 48) / 48 * 2 * .pi) * 200_000_000)
            for channel in 0..<channels {
                output[sample * channels + channel] = value
            }
        }
        phase = (phase + samples) % 48
    }
}
