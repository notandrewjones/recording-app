import Foundation
import ISOCore

/// One capture path. DeckLink and synthetic sources are interchangeable from here up.
protocol CaptureSource: AnyObject {
    var input: CaptureInput { get }
    var store: PreviewFrameStore { get }
    func start() throws
    func stop()
}

final class DeckLinkCaptureSource: CaptureSource {
    let input: CaptureInput
    let store = PreviewFrameStore()
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

    func start() throws {
        let store = store
        // Published by the format handler on the capture thread, which is also the only reader.
        var format = VideoFormat.hd1080p5994
        try device.start(
            withAudioChannels: 0,
            frameHandler: { info, video, _ in
                let current = format
                guard info.pointee.rowBytes == current.rowBytes, Int(info.pointee.height) == current.height else { return }
                store.offer(format: current, bytes: video, timecode: Self.timecode(info.pointee, rate: current.frameRate), hasSignal: info.pointee.hasSignal)
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

/// Generates bars at the format's exact rate, for working on everything above capture without hardware.
final class SyntheticCaptureSource: CaptureSource {
    let input: CaptureInput
    let store = PreviewFrameStore()
    private let format: VideoFormat
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    init(index: Int, format: VideoFormat = .hd1080p5994) {
        self.format = format
        input = CaptureInput(
            id: "synthetic-\(index)",
            displayName: "Synthetic \(index)",
            maxAudioChannels: 16,
            supportsFormatDetection: false,
            isSynthetic: true
        )
        queue = DispatchQueue(label: "synthetic-capture-\(index)", qos: .userInteractive)
    }

    func start() {
        stop()
        let format = format
        let store = store
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: format.frameBytes, alignment: 64)
        let startNanos = DispatchTime.now().uptimeNanoseconds
        var frameNumber: UInt64 = 0

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let period = 1.0 / format.frameRate.doubleValue
        timer.schedule(deadline: .now(), repeating: period, leeway: .microseconds(500))
        timer.setEventHandler {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000_000
            let due = UInt64(elapsed * format.frameRate.doubleValue)
            frameNumber = max(frameNumber + 1, due)
            SyntheticFrame.fill(buffer, format: format, frameNumber: frameNumber)
            let timecode = Timecode(frameCount: Int(frameNumber), frameRate: format.frameRate)
            store.offer(format: format, bytes: UnsafeRawPointer(buffer.baseAddress!), timecode: timecode, hasSignal: true)
        }
        timer.setCancelHandler { buffer.deallocate() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
