import Foundation
import ISOCore
import ISOEngine
import os

/// Passes frames from a capture thread to the input's recorder, when there is one.
final class RecorderSink: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var recorder: InputRecorder?

    func attach(_ recorder: InputRecorder?) {
        os_unfair_lock_lock(&lock)
        self.recorder = recorder
        os_unfair_lock_unlock(&lock)
    }

    func send(_ frame: IngestFrame) {
        os_unfair_lock_lock(&lock)
        let target = recorder
        os_unfair_lock_unlock(&lock)
        target?.ingest(frame)
    }
}

/// One capture path. DeckLink and synthetic sources are interchangeable from here up.
protocol CaptureSource: AnyObject {
    var input: CaptureInput { get }
    var store: PreviewFrameStore { get }
    var sink: RecorderSink { get }
    /// Channels this source records, as a count ffmpeg can accept.
    var audioChannels: Int { get }
    func start() throws
    func stop()
}

final class DeckLinkCaptureSource: CaptureSource {
    let input: CaptureInput
    let store = PreviewFrameStore()
    let sink = RecorderSink()
    let device: DLInput

    init(device: DLInput) {
        self.device = device
        input = CaptureInput(
            id: device.identifier,
            displayName: device.displayName,
            maxAudioChannels: Int(device.maxAudioChannels),
            supportsFormatDetection: device.supportsFormatDetection
        )
    }

    var audioChannels: Int {
        FFmpegCommand.supportedAudioChannelCounts.last { $0 <= input.maxAudioChannels } ?? 2
    }

    func start() throws {
        let store = store
        let sink = sink
        // Written by the format handler on the capture thread, which is also the only reader.
        var format = VideoFormat.hd1080p5994
        try device.start(
            withAudioChannels: Int32(audioChannels),
            frameHandler: { info, video, audio in
                let current = format
                let frame = info.pointee
                guard frame.rowBytes == current.rowBytes, Int(frame.height) == current.height else { return }
                let timecode = Self.timecode(frame, rate: current.frameRate)
                store.offer(format: current, bytes: video, timecode: timecode, hasSignal: frame.hasSignal)
                sink.send(IngestFrame(
                    format: current,
                    video: video,
                    audio: audio,
                    audioSampleFrames: Int(frame.audioSampleFrames),
                    hostTimeNanos: frame.hostTimeNanos,
                    streamTime: frame.streamTime,
                    streamTimeScale: frame.streamTimeScale,
                    timecode: timecode,
                    hasSignal: frame.hasSignal
                ))
            },
            formatHandler: { dlFormat in
                format = VideoFormat(dlFormat)
            }
        )
    }

    func stop() {
        device.stop()
    }

    private static func timecode(_ info: DLFrameInfo, rate: Rational) -> Timecode? {
        guard info.hasTimecode else { return nil }
        let nominal = Int(rate.doubleValue.rounded())
        return Timecode(
            hours: Int(info.timecodeHours), minutes: Int(info.timecodeMinutes),
            seconds: Int(info.timecodeSeconds), frames: Int(info.timecodeFrames),
            nominalFPS: nominal, isDropFrame: info.timecodeIsDropFrame
        )
    }
}

private extension VideoFormat {
    init(_ format: DLFormat) {
        let scan: ScanMode
        switch format.scan {
        case .interlacedTopFirst: scan = .interlacedTopFieldFirst
        case .interlacedBottomFirst: scan = .interlacedBottomFieldFirst
        case .progressiveSegmented: scan = .progressiveSegmented
        default: scan = .progressive
        }
        self.init(
            width: Int(format.width),
            height: Int(format.height),
            frameRate: Rational(format.timeScale, format.frameDuration),
            scan: scan
        )
    }
}

/// Bars and tone at the format's exact rate, for working on everything above capture without hardware.
final class SyntheticCaptureSource: CaptureSource {
    /// `-syntheticGrain YES` adds grain, so that encoder and disk load match real cameras.
    private static let grainPool: SyntheticFramePool? = UserDefaults.standard.bool(forKey: "syntheticGrain")
        ? SyntheticFramePool(format: .hd1080p5994)
        : nil

    let input: CaptureInput
    let store = PreviewFrameStore()
    let sink = RecorderSink()
    let audioChannels = 16
    private let format: VideoFormat
    private var source: SyntheticSource?

    init(index: Int, format: VideoFormat = .hd1080p5994) {
        self.format = format
        input = CaptureInput(
            id: "synthetic-\(index)",
            displayName: "Synthetic \(index)",
            maxAudioChannels: 16,
            supportsFormatDetection: false,
            isSynthetic: true
        )
    }

    func start() {
        stop()
        let store = store
        let sink = sink
        let source = SyntheticSource(
            format: format,
            audioChannels: audioChannels,
            timecodeStart: Timecode.timeOfDay(date: Date(), frameRate: format.frameRate),
            pool: Self.grainPool
        )
        source.onFrame = { frame in
            store.offer(format: frame.format, bytes: frame.video, timecode: frame.timecode, hasSignal: frame.hasSignal)
            sink.send(frame)
        }
        source.start()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
