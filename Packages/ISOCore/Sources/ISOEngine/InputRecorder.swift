import Darwin
import Foundation
import ISOCore

/// One frame as delivered by a capture source. Pointers are valid only for the duration of `ingest`.
public struct IngestFrame {
    public var format: VideoFormat
    public var video: UnsafeRawPointer
    public var audio: UnsafeRawPointer?
    public var audioSampleFrames: Int
    public var hostTimeNanos: UInt64
    public var streamTime: Int64
    public var streamTimeScale: Int64
    public var timecode: Timecode?
    public var hasSignal: Bool

    public init(format: VideoFormat, video: UnsafeRawPointer, audio: UnsafeRawPointer?, audioSampleFrames: Int, hostTimeNanos: UInt64, streamTime: Int64, streamTimeScale: Int64, timecode: Timecode?, hasSignal: Bool) {
        self.format = format
        self.video = video
        self.audio = audio
        self.audioSampleFrames = audioSampleFrames
        self.hostTimeNanos = hostTimeNanos
        self.streamTime = streamTime
        self.streamTimeScale = streamTimeScale
        self.timecode = timecode
        self.hasSignal = hasSignal
    }
}

public struct InputRecorderSettings: Sendable {
    public var codec: Codec
    public var audio: AudioFormat?
    public var ringSeconds: Double
    public var stallSeconds: Double
    public var signalTimeoutSeconds: Double
    public var fullSyncSeconds: Double
    public var allowSoftwareProRes: Bool

    public init(codec: Codec = .proResHQ, audio: AudioFormat? = AudioFormat(channels: 16), ringSeconds: Double = 1, stallSeconds: Double = 5, signalTimeoutSeconds: Double = 1, fullSyncSeconds: Double = 2, allowSoftwareProRes: Bool = false) {
        self.codec = codec
        self.audio = audio
        self.ringSeconds = ringSeconds
        self.stallSeconds = stallSeconds
        self.signalTimeoutSeconds = signalTimeoutSeconds
        self.fullSyncSeconds = fullSyncSeconds
        self.allowSoftwareProRes = allowSoftwareProRes
    }
}

public struct InputRecorderStatus: Sendable {
    public var state: RecorderWatchdog.State
    public var segment: Int?
    public var framesThisSegment: Int
    public var totalFrames: Int
    public var repeatedFrames: Int
    public var restarts: Int
    public var ringFill: Double
    public var peakRingFill: Double
    /// Frames lost between segments, from a crash or restart. They are not in any file.
    public var gapFrames: Int
    public var bytesPerSecond: Double
    public var ffmpegProcessIdentifier: Int32?
}

/// Supervises one input's recording. All decisions come from `RecorderWatchdog`; this class performs them.
/// `ingest` runs on the capture thread and only copies into the ring. Everything else runs on `queue`.
public final class InputRecorder: @unchecked Sendable {
    public let id: String
    public let label: String
    public let settings: InputRecorderSettings

    private let store: SessionStore
    private let finalizer: Finalizer
    private let environment: FFmpegEnvironment
    private let socketDirectory: String
    private let socketPrefix: String
    private let queue: DispatchQueue
    private let group = DispatchGroup()

    // Shared with the capture thread.
    private let lock = UnfairLock()
    private var ring: FrameRing?
    private var lastSignal: Bool?
    private var lastFormat: VideoFormat?
    private var lastIngestUptime: UInt64 = 0
    private var gapDetector: FrameGapDetector?
    private var rolloverPending = false

    // Owned by `queue`.
    private var watchdog = RecorderWatchdog()
    /// True between start and stop, including after a permanent failure, so stop always balances start.
    private var recordingRequested = false
    private var current: SegmentRecorder?
    private var closingReason: SessionManifest.EndReason = .stopped
    private var monitor: DispatchSourceTimer?
    private var lastBytes: Int64 = 0
    private var lastGrowthUptime: UInt64 = 0
    private var lastSampleUptime: UInt64 = 0
    private var lastSyncUptime: UInt64 = 0
    private var healthySinceUptime: UInt64?
    private var bytesPerSecond = 0.0
    private var closedFrames = 0
    private var closedRepeats = 0
    private var restarts = 0
    private var peakRingFill = 0.0
    private var gapFrames = 0
    /// Set when a segment fails, so the next opening can measure what was lost in between.
    private var failedAtHostNanos: UInt64?

    init(id: String, label: String, settings: InputRecorderSettings, store: SessionStore, finalizer: Finalizer, environment: FFmpegEnvironment, socketDirectory: String, socketPrefix: String) {
        self.id = id
        self.label = label
        self.settings = settings
        self.store = store
        self.finalizer = finalizer
        self.environment = environment
        self.socketDirectory = socketDirectory
        self.socketPrefix = socketPrefix
        queue = DispatchQueue(label: "input-recorder-\(socketPrefix)", qos: .userInitiated)
        store.update { $0.inputs.append(.init(id: id, label: label)) }
        try? FileManager.default.createDirectory(atPath: store.layout.inputDirectory(inputLabel: label), withIntermediateDirectories: true)
    }

    // MARK: Capture thread

    public func ingest(_ frame: IngestFrame) {
        let uptime = DispatchTime.now().uptimeNanoseconds
        var events: [RecorderWatchdog.Event] = []

        let target: FrameRing? = lock.withLock {
            lastIngestUptime = uptime
            let previous = lastSignal
            lastSignal = frame.hasSignal
            guard frame.hasSignal else {
                if previous != false { events.append(.signalLost) }
                gapDetector?.reset()
                return nil
            }
            if previous == false || previous == nil { events.append(.signalRestored) }
            if let last = lastFormat, last != frame.format { events.append(.formatChanged) }
            lastFormat = frame.format
            guard let ring, ring.format == frame.format else { return nil }
            return ring
        }

        if !events.isEmpty {
            queue.async { [self] in events.forEach { send($0) } }
        }
        guard let target else { return }

        let gap = lock.withLock { gapDetector?.observe(streamTime: frame.streamTime) ?? .continuous }
        switch gap {
        case .continuous:
            break
        case .missing(let count):
            target.markMissing(count)
        case .discontinuity:
            let shouldRoll = lock.withLock {
                defer { rolloverPending = true }
                return !rolloverPending
            }
            if shouldRoll {
                queue.async { [self] in
                    closingReason = .discontinuity
                    send(.formatChanged)
                }
            }
            return
        }

        var metadata = FrameRing.Metadata(hostTimeNanos: frame.hostTimeNanos, streamTime: frame.streamTime, timecode: frame.timecode)
        metadata.noSignal = false
        let bytesPerSample = (settings.audio?.channels ?? 0) * 4
        target.push(video: frame.video, audio: frame.audio, audioBytes: frame.audioSampleFrames * bytesPerSample, metadata: metadata)
    }

    // MARK: Control

    public func startRecording() {
        queue.async { [self] in
            guard !isActive else { return }
            if !recordingRequested {
                recordingRequested = true
                group.enter()
            }
            startMonitor()
            send(.recordRequested)
        }
    }

    public func stopRecording(reason: SessionManifest.EndReason = .stopped) {
        queue.async { [self] in
            guard recordingRequested else { return }
            recordingRequested = false
            closingReason = reason
            send(.stopRequested)
            stopMonitor()
            discardRing()
            group.leave()
        }
    }

    /// The hardware went away. Recording resumes in a new segment if it returns.
    public func inputLost() {
        lock.withLock { lastSignal = false }
        queue.async { [self] in send(.signalLost) }
    }

    public func killRecorderForTesting() {
        queue.async { [self] in current?.kill() }
    }

    public func waitForSegments() {
        queue.sync {}
        group.wait()
        queue.sync {}
    }

    public func status() -> InputRecorderStatus {
        queue.sync {
            let live = current?.counters ?? (0, 0)
            let segment: Int?
            switch watchdog.state {
            case .recording(let number), .starting(let number): segment = number
            default: segment = nil
            }
            return InputRecorderStatus(
                state: watchdog.state,
                segment: segment,
                framesThisSegment: live.0,
                totalFrames: closedFrames + live.0,
                repeatedFrames: closedRepeats + live.1,
                restarts: restarts,
                ringFill: lock.withLock { ring?.fillLevel ?? 0 },
                peakRingFill: peakRingFill,
                gapFrames: gapFrames,
                bytesPerSecond: bytesPerSecond,
                ffmpegProcessIdentifier: current?.processIdentifier
            )
        }
    }

    // MARK: Queue

    private var isActive: Bool {
        switch watchdog.state {
        case .idle, .failed: false
        default: true
        }
    }

    private func send(_ event: RecorderWatchdog.Event) {
        if event == .signalLost { closingReason = .signalLost; log("signal_lost") }
        if event == .signalRestored { log("signal_restored") }
        if event == .formatChanged, closingReason != .discontinuity { closingReason = .formatChanged }
        perform(watchdog.handle(event))
    }

    private func perform(_ actions: [RecorderWatchdog.Action]) {
        for action in actions {
            switch action {
            case .startProcess(let segment):
                openSegment(segment)
            case .stopProcess:
                closeCurrent()
            case .killProcess:
                current?.kill()
                current = nil
            case .scheduleRetry(let delay):
                restarts += 1
                queue.asyncAfter(deadline: .now() + delay) { [self] in send(.backoffElapsed) }
            case .log(let message):
                log("recorder", detail: message)
            }
        }
        if case .failed = watchdog.state {
            stopMonitor()
            discardRing()
        }
    }

    private func log(_ kind: String, detail: String? = nil) {
        let event = SessionManifest.Event(hostNanos: DispatchTime.now().uptimeNanoseconds, kind: kind, detail: detail)
        let inputID = id
        store.update { manifest in
            guard let index = manifest.inputs.firstIndex(where: { $0.id == inputID }) else { return }
            manifest.inputs[index].events.append(event)
        }
    }

    private func openSegment(_ number: Int) {
        guard let format = lock.withLock({ lastSignal == true ? lastFormat : nil }) else {
            // No usable signal yet. The first valid frame raises `signalRestored`, which reopens this segment.
            send(.noSignalYet)
            return
        }
        let ring = prepareRing(for: format)
        let layout = store.layout

        let configuration = SegmentRecorder.Configuration(
            number: number,
            codec: settings.codec,
            audio: settings.audio,
            workingPath: layout.workingSegmentPath(inputLabel: label, segment: number),
            indexPath: layout.frameIndexPath(inputLabel: label, segment: number),
            logPath: layout.logPath(inputLabel: label, segment: number),
            videoSocketPath: "\(socketDirectory)/\(socketPrefix)v\(number).sock",
            audioSocketPath: "\(socketDirectory)/\(socketPrefix)a\(number).sock",
            environment: environment,
            streamTimeScale: 240_000,
            allowSoftwareProRes: settings.allowSoftwareProRes
        )
        let recorder = SegmentRecorder(configuration: configuration, ring: ring)
        recorder.onOpened = { [self] opening in
            queue.async { [self] in recordOpening(opening, number: number, format: format, configuration: configuration) }
        }
        recorder.onConnected = { [self] in
            queue.async { [self] in
                lastGrowthUptime = DispatchTime.now().uptimeNanoseconds
                healthySinceUptime = lastGrowthUptime
                send(.processStarted)
            }
        }
        recorder.onFinished = { [self] outcome in
            queue.async { [self] in segmentFinished(number: number, outcome: outcome, recorder: recorder) }
        }
        current = recorder
        group.enter()
        recorder.start()
    }

    /// Keeps the ring across a crash so frames not yet written carry over. A new format needs a new one.
    private func prepareRing(for format: VideoFormat) -> FrameRing {
        if let existing = lock.withLock({ self.ring }), existing.format == format, !existing.isClosed {
            existing.alignAudioToVideo()
            return existing
        }
        let rate = format.frameRate.doubleValue
        let slots = max(4, Int((rate * settings.ringSeconds).rounded(.up))) + 1
        let audioBytes = AudioCadence.maximumSamplesPerFrame(frameRate: format.frameRate) * (settings.audio?.channels ?? 0) * 4
        let ring = FrameRing(format: format, slotCount: slots, audioSlotBytes: audioBytes)
        let fill = max(1, Int(rate * 2))
        lock.withLock {
            self.ring = ring
            gapDetector = FrameGapDetector(frameRate: format.frameRate, streamTimeScale: 240_000, maximumFill: fill)
            rolloverPending = false
        }
        return ring
    }

    private func recordOpening(_ opening: SegmentRecorder.Opening, number: Int, format: VideoFormat, configuration: SegmentRecorder.Configuration) {
        if let failedAt = failedAtHostNanos, opening.startHostNanos > failedAt {
            let lost = max(0, Int((seconds(opening.startHostNanos - failedAt) * format.frameRate.doubleValue).rounded()) - 1)
            gapFrames += lost
            log("recording_gap", detail: "\(lost) frames")
        }
        failedAtHostNanos = nil

        let layout = store.layout
        let record = SessionManifest.SegmentRecord(
            number: number,
            workingFile: layout.relativePath(configuration.workingPath),
            finalFile: layout.relativePath(layout.segmentPath(inputLabel: label, segment: number)),
            indexFile: layout.relativePath(configuration.indexPath),
            logFile: layout.relativePath(configuration.logPath),
            format: format,
            codec: settings.codec,
            audioChannels: settings.audio?.channels ?? 0,
            startTimecode: opening.startTimecode.string,
            timecodeIsEmbedded: opening.timecodeIsEmbedded,
            startHostNanos: opening.startHostNanos
        )
        let inputID = id
        store.update { manifest in
            guard let index = manifest.inputs.firstIndex(where: { $0.id == inputID }) else { return }
            manifest.inputs[index].segments.append(record)
        }
    }

    /// Closes the ring so the writer drains it, and ffmpeg exits on EOF.
    private func closeCurrent() {
        guard current != nil else { return }
        lock.withLock {
            ring?.close()
            ring = nil
        }
        current = nil
    }

    private func discardRing() {
        lock.withLock {
            ring?.close()
            ring = nil
        }
    }

    private func segmentFinished(number: Int, outcome: SegmentRecorder.Outcome, recorder: SegmentRecorder) {
        defer { group.leave() }
        closedFrames += outcome.framesWritten
        closedRepeats += outcome.repeatedFrames

        let wasCurrent = current === recorder
        if wasCurrent { current = nil }

        if outcome.neverStarted || outcome.framesWritten == 0 {
            removeEmpty(number: number, recorder: recorder)
        } else {
            let reason: SessionManifest.EndReason = wasCurrent || !outcome.drained ? .recorderFailed : closingReason
            if reason == .recorderFailed { failedAtHostNanos = outcome.lastHostNanos }
            store.updateSegment(inputID: id, number: number) {
                $0.state = .closed
                $0.frames = outcome.framesWritten
                $0.repeatedFrames = outcome.repeatedFrames
                $0.endReason = reason
            }
            finalizer.enqueue(store: store, inputID: id, number: number)
        }
        if closingReason == .discontinuity { closingReason = .stopped }

        if wasCurrent {
            send(.processExited(segment: number, code: outcome.exitCode ?? -1))
        }
    }

    private func removeEmpty(number: Int, recorder: SegmentRecorder) {
        let configuration = recorder.configuration
        for path in [configuration.workingPath, configuration.indexPath, configuration.logPath] {
            unlink(path)
        }
        let inputID = id
        store.update { manifest in
            guard let index = manifest.inputs.firstIndex(where: { $0.id == inputID }) else { return }
            manifest.inputs[index].segments.removeAll { $0.number == number }
        }
    }

    private func startMonitor() {
        lastSampleUptime = DispatchTime.now().uptimeNanoseconds
        lastSyncUptime = lastSampleUptime
        lastBytes = 0
        lock.withLock { lastIngestUptime = lastSampleUptime }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [self] in monitorTick() }
        timer.resume()
        monitor = timer
    }

    private func stopMonitor() {
        monitor?.cancel()
        monitor = nil
    }

    private func monitorTick() {
        let now = DispatchTime.now().uptimeNanoseconds

        let (sinceIngest, wasReceiving, queued, fill) = lock.withLock {
            (seconds(now - lastIngestUptime), lastSignal == true, ring?.queuedFrames ?? 0, ring?.fillLevel ?? 0)
        }
        peakRingFill = max(peakRingFill, fill)
        if wasReceiving, sinceIngest > settings.signalTimeoutSeconds {
            lock.withLock { lastSignal = false }
            send(.signalLost)
        }

        guard let current else { return }

        let bytes = current.bytesOnDisk
        let elapsed = seconds(now - lastSampleUptime)
        if elapsed >= 1 {
            bytesPerSecond = Double(max(0, bytes - lastBytes)) / elapsed
            lastSampleUptime = now
        }
        if bytes != lastBytes {
            if elapsed >= 1 { lastBytes = bytes }
            lastGrowthUptime = now
        }

        // An empty ring means the source paused, which is not ffmpeg's fault.
        if case .recording = watchdog.state, queued > 0, seconds(now - lastGrowthUptime) > settings.stallSeconds {
            send(.outputStalled)
            return
        }

        if let since = healthySinceUptime, seconds(now - since) > 30 {
            watchdog.markHealthy()
            healthySinceUptime = nil
        }

        if settings.fullSyncSeconds > 0, seconds(now - lastSyncUptime) >= settings.fullSyncSeconds {
            lastSyncUptime = now
            let working = current.configuration.workingPath
            let index = current.configuration.indexPath
            DispatchQueue.global(qos: .utility).async {
                Self.fullSync(working)
                Self.fullSync(index)
            }
        }
    }

    private func seconds(_ nanos: UInt64) -> Double {
        Double(nanos) / 1_000_000_000
    }

    /// ffmpeg never forces data to the drive, so without this a power cut could lose more than the last fragment.
    private static func fullSync(_ path: String) {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fcntl(descriptor, F_FULLFSYNC)
        close(descriptor)
    }
}
