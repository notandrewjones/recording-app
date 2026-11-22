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

/// What a capture thread has seen since capture last started. A session file gets a copy, so a recording
/// that comes up empty says whether the card sent nothing or sent frames the app threw away.
final class CaptureCounters: @unchecked Sendable {
    struct Rejection {
        var rowBytes: Int
        var height: Int
        var expectedRowBytes: Int
        var expectedHeight: Int
    }

    private var lock = os_unfair_lock()
    private var delivered: UInt64 = 0
    private var rejected: UInt64 = 0
    private var lastRejection: Rejection?

    func reset() {
        os_unfair_lock_lock(&lock)
        (delivered, rejected, lastRejection) = (0, 0, nil)
        os_unfair_lock_unlock(&lock)
    }

    func frameDelivered() {
        os_unfair_lock_lock(&lock)
        delivered += 1
        os_unfair_lock_unlock(&lock)
    }

    func frameRejected(_ rejection: Rejection) {
        os_unfair_lock_lock(&lock)
        rejected += 1
        lastRejection = rejection
        os_unfair_lock_unlock(&lock)
    }

    /// For example "1083 frames from the card, 0 rejected".
    var summary: String {
        os_unfair_lock_lock(&lock)
        let (delivered, rejected, last) = (delivered, rejected, lastRejection)
        os_unfair_lock_unlock(&lock)
        var text = "\(delivered + rejected) frames from the card, \(rejected) rejected"
        if let last {
            text += " (last: \(last.rowBytes) bytes per row x \(last.height) rows, expected \(last.expectedRowBytes) x \(last.expectedHeight))"
        }
        return text
    }
}

/// One capture path. DeckLink and synthetic sources are interchangeable from here up.
protocol CaptureSource: AnyObject {
    var input: CaptureInput { get }
    var store: PreviewFrameStore { get }
    var sink: RecorderSink { get }
    /// Channels this source records, as a count ffmpeg can accept.
    var audioChannels: Int { get }
    /// The pixel layout this source delivers, chosen to match what the encoder needs.
    var pixelLayout: PixelLayout { get }
    func start() throws
    func stop()
    /// Restarts capture if it is running. Only called between recordings, since a new layout is a new format.
    func setPixelLayout(_ layout: PixelLayout) throws
    /// Whether capture started and has not been stopped. It says nothing about whether frames arrive.
    var isCapturing: Bool { get }
    /// One line for the session file: whether capture is running, in what format, and what has arrived.
    var captureDescription: String { get }
}

final class DeckLinkCaptureSource: CaptureSource {
    let input: CaptureInput
    let store = PreviewFrameStore()
    let sink = RecorderSink()
    let device: DLInput
    private(set) var pixelLayout = PixelLayout.v210
    private var isRunning = false
    private var startError: String?
    private let counters = CaptureCounters()

    var isCapturing: Bool { isRunning }

    var captureDescription: String {
        if let startError { return "capture failed to start: \(startError)" }
        guard isRunning else { return "capture stopped" }
        let detection = input.supportsFormatDetection ? "" : ", no format detection"
        return "capture running, \(pixelLayout == .v210 ? "10-bit" : "8-bit")\(detection), \(counters.summary); card: \(device.captureStatsDescription)"
    }

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

    func setPixelLayout(_ layout: PixelLayout) throws {
        guard layout != pixelLayout else { return }
        pixelLayout = layout
        guard isRunning else { return }
        stop()
        try start()
    }

    func start() throws {
        let store = store
        let sink = sink
        let counters = counters
        counters.reset()
        // Written by the format handler on the capture thread, which is also the only reader.
        var format = VideoFormat.hd1080p5994
        device.captureTenBit = pixelLayout == .v210
        do {
            try device.start(
                withAudioChannels: Int32(audioChannels),
                frameHandler: { info, video, audio in
                    let frame = info.pointee
                    var current = format
                    // Each frame says what it is, so frames still in flight from before a restart are labelled right.
                    current.pixelLayout = frame.isTenBit ? .v210 : .uyvy422
                    guard frame.rowBytes == current.rowBytes, Int(frame.height) == current.height else {
                        counters.frameRejected(.init(rowBytes: Int(frame.rowBytes), height: Int(frame.height), expectedRowBytes: current.rowBytes, expectedHeight: current.height))
                        return
                    }
                    counters.frameDelivered()
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
        } catch {
            startError = error.localizedDescription
            throw error
        }
        startError = nil
        isRunning = true
    }

    func stop() {
        isRunning = false
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
    private var format: VideoFormat
    private var source: SyntheticSource?
    private var framesSent: UInt64 = 0
    private var framesLock = os_unfair_lock()
    /// `-syntheticNoVideo YES` starts capture without ever delivering a frame, like a card that has gone
    /// quiet, for checking what the operator sees when nothing arrives.
    private static let deliversNothing = UserDefaults.standard.bool(forKey: "syntheticNoVideo")

    var pixelLayout: PixelLayout { format.pixelLayout }
    var isCapturing: Bool { source != nil }

    var captureDescription: String {
        guard source != nil else { return "capture stopped" }
        os_unfair_lock_lock(&framesLock)
        let sent = framesSent
        os_unfair_lock_unlock(&framesLock)
        return "synthetic \(format.displayName) \(format.pixelLayout.rawValue), \(sent) frames\(Self.deliversNothing ? ", set to deliver nothing" : "")"
    }

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
            // Grain exists only for v210.
            pool: format.pixelLayout == .v210 ? Self.grainPool : nil
        )
        let deliversNothing = Self.deliversNothing
        source.onFrame = { [weak self] frame in
            guard !deliversNothing else { return }
            if let self {
                os_unfair_lock_lock(&self.framesLock)
                self.framesSent += 1
                os_unfair_lock_unlock(&self.framesLock)
            }
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

    func setPixelLayout(_ layout: PixelLayout) {
        guard layout != format.pixelLayout else { return }
        format.pixelLayout = layout
        if source != nil { start() }
    }
}
