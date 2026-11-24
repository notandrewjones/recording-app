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
    /// When the first audio sample was captured, on the same clock and scale as `streamTime`. The card
    /// stamps each audio packet, and a packet need not belong to the frame it arrives with. Nil means unknown,
    /// and the audio is taken to start with the frame.
    public var audioStreamTime: Int64?

    public init(format: VideoFormat, video: UnsafeRawPointer, audio: UnsafeRawPointer?, audioSampleFrames: Int, hostTimeNanos: UInt64, streamTime: Int64, streamTimeScale: Int64, timecode: Timecode?, hasSignal: Bool, audioStreamTime: Int64? = nil) {
        self.format = format
        self.video = video
        self.audio = audio
        self.audioSampleFrames = audioSampleFrames
        self.hostTimeNanos = hostTimeNanos
        self.streamTime = streamTime
        self.streamTimeScale = streamTimeScale
        self.timecode = timecode
        self.hasSignal = hasSignal
        self.audioStreamTime = audioStreamTime
    }
}

/// Audio the card delivered without a picture. DeckLink does this when it has no buffer free for the frame.
public struct IngestAudio {
    public var audio: UnsafeRawPointer
    public var sampleFrames: Int
    /// When the first sample was captured, on the video stream clock.
    public var streamTime: Int64
    public var streamTimeScale: Int64
    public var hostTimeNanos: UInt64

    public init(audio: UnsafeRawPointer, sampleFrames: Int, streamTime: Int64, streamTimeScale: Int64, hostTimeNanos: UInt64) {
        self.audio = audio
        self.sampleFrames = sampleFrames
        self.streamTime = streamTime
        self.streamTimeScale = streamTimeScale
        self.hostTimeNanos = hostTimeNanos
    }
}

public struct InputRecorderSettings: Sendable {
    public var codec: Codec
    public var audio: AudioFormat?
    public var ringSeconds: Double
    /// No sign of life from ffmpeg for this long, in output, input or CPU, means it is stuck and is replaced.
    public var stallSeconds: Double
    /// No output for this long means ffmpeg is replaced even if it still looks busy.
    public var hardStallSeconds: Double
    /// No output for this long, while ffmpeg is still working, is logged as falling behind.
    public var slowSeconds: Double
    public var signalTimeoutSeconds: Double
    public var fullSyncSeconds: Double
    public var allowSoftwareProRes: Bool
    /// Where each segment's starting timecode comes from. `InputRecorder.setTimecodeSource` changes it later.
    public var timecodeSource: TimecodeSource
    /// Recording requested but no file written for this long raises `InputRecorderStatus.problem`.
    /// Long enough to ride out a normal start or a quick restart.
    public var notWritingAlarmSeconds: Double
    /// This many restarts, new files or card clock resets, within `instabilityWindowSeconds` raise
    /// `RecordingProblem.unstable`. A format change or a punch-in is one; a flapping input is many.
    public var instabilityLimit: Int
    public var instabilityWindowSeconds: Double
    /// A recorder restart raises `RecordingProblem.restarted` for this long. Each one loses a moment of the
    /// recording and repeats frames over it, so even one is worth knowing about while it can still be fixed.
    public var restartAlarmSeconds: Double
    /// How much audio each input keeps. It has to outlast a frozen recorder being found and replaced, so the
    /// new file still has the audio for the frames it carries over.
    public var audioBufferSeconds: Double

    public init(codec: Codec = .proResLT, audio: AudioFormat? = AudioFormat(channels: 16), ringSeconds: Double = 1, stallSeconds: Double = 10, signalTimeoutSeconds: Double = 1, fullSyncSeconds: Double = 2, allowSoftwareProRes: Bool = false, timecodeSource: TimecodeSource = .source, hardStallSeconds: Double = 30, slowSeconds: Double = 5, notWritingAlarmSeconds: Double = 5, instabilityLimit: Int = 5, instabilityWindowSeconds: Double = 10, restartAlarmSeconds: Double = 300, audioBufferSeconds: Double = 15) {
        self.codec = codec
        self.audio = audio
        self.ringSeconds = ringSeconds
        self.stallSeconds = stallSeconds
        self.hardStallSeconds = hardStallSeconds
        self.slowSeconds = slowSeconds
        self.signalTimeoutSeconds = signalTimeoutSeconds
        self.fullSyncSeconds = fullSyncSeconds
        self.allowSoftwareProRes = allowSoftwareProRes
        self.timecodeSource = timecodeSource
        self.notWritingAlarmSeconds = notWritingAlarmSeconds
        self.instabilityLimit = instabilityLimit
        self.instabilityWindowSeconds = instabilityWindowSeconds
        self.restartAlarmSeconds = restartAlarmSeconds
        self.audioBufferSeconds = audioBufferSeconds
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
    /// Bytes written across every segment so far, for the session's write rate.
    public var bytesWritten: Int64
    public var ffmpegProcessIdentifier: Int32?
    /// A file is being written. False while waiting for signal, starting, restarting or after giving up.
    public var isWriting: Bool
    /// Set once recording has been requested with no file written for `notWritingAlarmSeconds`, while
    /// the input keeps restarting, or for a while after the recorder had to restart.
    public var problem: RecordingProblem?
    /// Frames the capture source has handed over since this recorder was created, with or without signal.
    public var framesReceived: Int
    /// What the card's audio has done since recording was first requested.
    public var audio: AudioTimeline.Stats
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
    /// Paired with `ring`: both number frames on the same timeline, and both are replaced together.
    private var audioTimeline: AudioTimeline?
    private var lastSignal: Bool?
    private var lastFormat: VideoFormat?
    private var lastIngestUptime: UInt64 = 0
    private var gapDetector: FrameGapDetector?
    private var rolloverPending = false
    private var timecodeSource: TimecodeSource
    /// Unlike `lastIngestUptime`, which the monitor resets, these only change when a frame really arrives.
    private var lastFrameUptime: UInt64?
    private var framesReceived = 0

    // Owned by `queue`.
    private var watchdog = RecorderWatchdog()
    /// True between start and stop, including after a permanent failure, so stop always balances start.
    private var recordingRequested = false
    private var current: SegmentRecorder?
    private var closingReason: SessionManifest.EndReason = .stopped
    private var monitor: DispatchSourceTimer?
    private var lastBytes: Int64 = 0
    private var stall: StallDetector
    /// When the current recorder started falling behind, for the event logged once it catches up.
    private var slowSinceUptime: UInt64?
    private var lastSyncUptime: UInt64 = 0
    private var healthySinceUptime: UInt64?
    private var bytesWritten: Int64 = 0
    private var closedFrames = 0
    private var closedRepeats = 0
    private var restarts = 0
    private var peakRingFill = 0.0
    private var gapFrames = 0
    /// Set when a segment fails, so the next opening can measure what was lost in between.
    private var failedAtHostNanos: UInt64?
    /// When recording was requested, or last stopped writing, while it is still requested. Nil while writing.
    private var notWritingSinceUptime: UInt64?
    /// Identifies the current not-writing stretch, so an alarm scheduled for an earlier one does nothing.
    private var notWritingEpisode = 0
    /// Whether this stretch has been logged as `not_writing`, so its end is logged too.
    private var notWritingLogged = false
    /// Recent new files and card clock resets, oldest first, for spotting an input that keeps restarting.
    private var recentRestarts: [(uptime: UInt64, isNewFile: Bool)] = []
    private var lastUnstableLogUptime: UInt64?
    /// When the recorder had to be restarted while recording, oldest first, for `RecordingProblem.restarted`.
    private var recorderRestarts: [UInt64] = []
    /// Audio stats of timelines already replaced, and how much of the current one is in the session file.
    private var closedAudioStats = AudioTimeline.Stats()
    private var loggedAudioStats = AudioTimeline.Stats()
    private var lastAudioLogUptime: UInt64 = 0

    init(id: String, label: String, settings: InputRecorderSettings, store: SessionStore, finalizer: Finalizer, environment: FFmpegEnvironment, socketDirectory: String, socketPrefix: String) {
        self.id = id
        self.label = label
        self.settings = settings
        timecodeSource = settings.timecodeSource
        stall = StallDetector(slowSeconds: settings.slowSeconds, hungSeconds: settings.stallSeconds, hardSeconds: settings.hardStallSeconds)
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
        var firstFrame: String?

        let target: (ring: FrameRing, audio: AudioTimeline?)? = lock.withLock {
            lastIngestUptime = uptime
            lastFrameUptime = uptime
            framesReceived += 1
            if framesReceived == 1 {
                firstFrame = "\(frame.format.displayName) \(frame.format.pixelLayout.rawValue), \(frame.hasSignal ? "signal" : "no signal")"
            }
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
            return (ring, audioTimeline)
        }

        if firstFrame != nil || !events.isEmpty {
            queue.async { [self] in
                if let firstFrame { log("first_frame", detail: firstFrame) }
                events.forEach { send($0) }
            }
        }
        guard let target else { return }

        let gap = lock.withLock { gapDetector?.observe(streamTime: frame.streamTime, hostNanos: frame.hostTimeNanos) ?? .continuous }
        switch gap {
        case .continuous:
            break
        case .missing(let count):
            target.ring.markMissing(count)
        case .clockReset(let missing):
            if missing > 0 { target.ring.markMissing(missing) }
            queue.async { [self] in noteRestart(isNewFile: false) }
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
        let pushed = target.ring.push(video: frame.video, metadata: metadata)
        // Even a frame the ring had no room for moves the audio on, so ffmpeg never waits on a full ring.
        target.audio?.frameArrived(
            timelineFrame: pushed.timelineFrame,
            streamTime: frame.streamTime,
            streamTimeScale: frame.streamTimeScale,
            audio: frame.audio,
            sampleFrames: frame.audioSampleFrames,
            audioStreamTime: frame.audioStreamTime
        )
    }

    /// Audio that arrived without a picture. It goes on the timeline by its own time.
    public func ingestAudio(_ packet: IngestAudio) {
        let timeline = lock.withLock { lastSignal == true ? audioTimeline : nil }
        timeline?.audioArrived(packet.audio, sampleFrames: packet.sampleFrames, streamTime: packet.streamTime, streamTimeScale: packet.streamTimeScale)
    }

    // MARK: Control

    /// Applies from the next segment. A segment already open keeps the timecode it started with.
    public func setTimecodeSource(_ source: TimecodeSource) {
        lock.withLock { timecodeSource = source }
    }

    public var currentTimecodeSource: TimecodeSource {
        lock.withLock { timecodeSource }
    }

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

    /// Adds an event to this input in the session file, for what only the caller knows, such as the state
    /// of the capture card.
    public func note(_ kind: String, detail: String? = nil) {
        queue.async { [self] in log(kind, detail: detail) }
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
            let now = DispatchTime.now().uptimeNanoseconds
            let notWriting = notWritingSinceUptime.map { HostTime.seconds(from: $0, to: now) >= settings.notWritingAlarmSeconds } ?? false
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
                bytesWritten: bytesWritten,
                ffmpegProcessIdentifier: current?.processIdentifier,
                isWriting: isWriting,
                problem: notWriting ? notWritingReason(now: now) : instability(now: now) ?? restartProblem(now: now),
                framesReceived: lock.withLock { framesReceived },
                audio: closedAudioStats + (lock.withLock { audioTimeline }?.currentStats ?? .init())
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

    private var isWriting: Bool {
        if case .recording = watchdog.state { return true }
        return false
    }

    private func send(_ event: RecorderWatchdog.Event) {
        if event == .signalLost { closingReason = .signalLost; log("signal_lost") }
        if event == .signalRestored { log("signal_restored") }
        if event == .formatChanged, closingReason != .discontinuity { closingReason = .formatChanged }
        perform(watchdog.handle(event))
        updateWritingState()
    }

    /// Times each stretch where recording is requested but no file is being written, and logs the ones
    /// that last long enough to matter. Nothing else in the session file shows them: waiting for a first
    /// frame that never comes leaves no segments and no other events.
    private func updateWritingState() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard recordingRequested, !isWriting else {
            if recordingRequested, notWritingLogged, let since = notWritingSinceUptime {
                log("writing_resumed", detail: String(format: "after %.1f s", HostTime.seconds(from: since, to: now)))
            }
            notWritingSinceUptime = nil
            notWritingLogged = false
            return
        }
        guard notWritingSinceUptime == nil else { return }
        notWritingSinceUptime = now
        notWritingEpisode += 1
        let episode = notWritingEpisode
        queue.asyncAfter(deadline: .now() + settings.notWritingAlarmSeconds) { [self] in
            guard episode == notWritingEpisode, notWritingSinceUptime != nil else { return }
            notWritingLogged = true
            log("not_writing", detail: notWritingReason(now: DispatchTime.now().uptimeNanoseconds).description)
        }
    }

    /// Counts a restart, and logs `unstable` at most once per window while restarts keep coming.
    private func noteRestart(isNewFile: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        recentRestarts.append((now, isNewFile))
        guard let problem = instability(now: now) else { return }
        if let last = lastUnstableLogUptime, HostTime.seconds(from: last, to: now) < settings.instabilityWindowSeconds { return }
        lastUnstableLogUptime = now
        let files = recentRestarts.filter(\.isNewFile).count
        log("unstable", detail: "\(problem.description): \(files) new files, \(recentRestarts.count - files) card clock resets")
    }

    private func instability(now: UInt64) -> RecordingProblem? {
        recentRestarts.removeAll { HostTime.seconds(from: $0.uptime, to: now) > settings.instabilityWindowSeconds }
        guard recentRestarts.count >= settings.instabilityLimit else { return nil }
        return .unstable(restarts: recentRestarts.count, seconds: Int(settings.instabilityWindowSeconds.rounded()))
    }

    private func restartProblem(now: UInt64) -> RecordingProblem? {
        recorderRestarts.removeAll { HostTime.seconds(from: $0, to: now) > settings.restartAlarmSeconds }
        guard !recorderRestarts.isEmpty else { return nil }
        return .restarted(times: recorderRestarts.count, minutes: max(1, Int((settings.restartAlarmSeconds / 60).rounded())))
    }

    private func notWritingReason(now: UInt64) -> RecordingProblem {
        let (lastFrame, hasSignal) = lock.withLock { (lastFrameUptime, lastSignal == true) }
        return RecordingProblem(
            state: watchdog.state,
            secondsSinceFrame: lastFrame.map { HostTime.seconds(from: $0, to: now) },
            hasSignal: hasSignal,
            frameTimeoutSeconds: settings.signalTimeoutSeconds
        )
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
                if recordingRequested { recorderRestarts.append(DispatchTime.now().uptimeNanoseconds) }
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
        try? FileManager.default.createDirectory(atPath: layout.workingDirectory(inputLabel: label), withIntermediateDirectories: true)

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
            allowSoftwareProRes: settings.allowSoftwareProRes,
            timecodeSource: currentTimecodeSource
        )
        let recorder = SegmentRecorder(configuration: configuration, ring: ring.video, audioTimeline: ring.audio)
        noteRestart(isNewFile: true)
        recorder.onOpened = { [self] opening in
            queue.async { [self] in recordOpening(opening, number: number, format: format, configuration: configuration) }
        }
        recorder.onConnected = { [self] in
            queue.async { [self] in
                let now = DispatchTime.now().uptimeNanoseconds
                stall.reset(now: Self.seconds(now))
                slowSinceUptime = nil
                healthySinceUptime = now
                send(.processStarted)
            }
        }
        recorder.onFinished = { [self] outcome in
            queue.async { [self] in segmentFinished(number: number, outcome: outcome, recorder: recorder) }
        }
        current = recorder
        // The new file starts empty, so growth is counted from zero.
        lastBytes = 0
        group.enter()
        recorder.start()
    }

    /// Keeps the ring and audio across a crash so frames not yet written carry over, with their sound. A new
    /// format needs new ones.
    private func prepareRing(for format: VideoFormat) -> (video: FrameRing, audio: AudioTimeline?) {
        // `self.` is needed: older compilers bind a bare `ring` here to the local declared further down.
        let existing: (video: FrameRing?, audio: AudioTimeline?) = lock.withLock { (self.ring, self.audioTimeline) }
        if let kept = existing.video, kept.format == format, !kept.isClosed {
            return (kept, existing.audio)
        }
        if existing.audio != nil { logAudio(replacing: true) }
        let rate = format.frameRate.doubleValue
        let slots = max(4, Int((rate * settings.ringSeconds).rounded(.up))) + 1
        let ring = FrameRing(format: format, slotCount: slots)
        log("ring_memory", detail: "\(ring.memoryLock), \(ring.storageBytes / 1_048_576) MB")
        let timeline = settings.audio.map {
            AudioTimeline(channels: $0.channels, frameRate: format.frameRate, capacitySeconds: settings.audioBufferSeconds)
        }
        if let timeline {
            let megabytes = Double(timeline.storageBytes) / 1_048_576
            log("audio_memory", detail: "\(timeline.memoryLock), \(String(format: "%.1f", megabytes)) MB for \(Int(settings.audioBufferSeconds.rounded())) s")
        }
        let fill = max(1, Int(rate * 2))
        lock.withLock {
            self.ring = ring
            audioTimeline = timeline
            gapDetector = FrameGapDetector(frameRate: format.frameRate, streamTimeScale: 240_000, maximumFill: fill)
            rolloverPending = false
        }
        return (ring, timeline)
    }

    /// Logs what the card's audio did since the last report, if anything was out of the ordinary. Call it
    /// with `replacing` before the timeline is dropped, so its last stretch is not lost.
    private func logAudio(replacing: Bool = false) {
        guard let timeline = lock.withLock({ audioTimeline }) else { return }
        let stats = timeline.currentStats
        let since = stats - loggedAudioStats
        if since.hasIrregularities {
            log("audio", detail: since.description)
            loggedAudioStats = stats
        }
        lastAudioLogUptime = DispatchTime.now().uptimeNanoseconds
        if replacing {
            closedAudioStats = closedAudioStats + stats
            loggedAudioStats = .init()
        }
    }

    private func recordOpening(_ opening: SegmentRecorder.Opening, number: Int, format: VideoFormat, configuration: SegmentRecorder.Configuration) {
        if let failedAt = failedAtHostNanos, opening.startHostNanos > failedAt {
            let lost = max(0, Int((HostTime.seconds(from: failedAt, to: opening.startHostNanos) * format.frameRate.doubleValue).rounded()) - 1)
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
            startHostNanos: opening.startHostNanos,
            timecodeSource: opening.timecodeSource
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
        discardRing()
        current = nil
    }

    /// The writer keeps its own references, so it can still drain what the ring and timeline hold.
    private func discardRing() {
        logAudio(replacing: true)
        lock.withLock {
            ring?.close()
            ring = nil
            audioTimeline = nil
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
        Finalizer.removeWorkingDirectoryIfEmpty(containing: configuration.workingPath)
        let inputID = id
        store.update { manifest in
            guard let index = manifest.inputs.firstIndex(where: { $0.id == inputID }) else { return }
            manifest.inputs[index].segments.removeAll { $0.number == number }
        }
    }

    private func startMonitor() {
        let now = DispatchTime.now().uptimeNanoseconds
        lastSyncUptime = now
        lastBytes = 0
        lock.withLock { lastIngestUptime = now }
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
            (HostTime.seconds(from: lastIngestUptime, to: now), lastSignal == true, ring?.queuedFrames ?? 0, ring?.fillLevel ?? 0)
        }
        peakRingFill = max(peakRingFill, fill)
        if wasReceiving, sinceIngest > settings.signalTimeoutSeconds {
            lock.withLock { lastSignal = false }
            send(.signalLost)
        }

        guard let current else { return }

        let bytes = current.bytesOnDisk
        if bytes > lastBytes {
            bytesWritten += bytes - lastBytes
            lastBytes = bytes
        }

        if case .recording = watchdog.state {
            let verdict = stall.observe(
                now: Self.seconds(now),
                outputBytes: bytes,
                inputFrames: current.counters.frames,
                cpuNanos: current.processIdentifier.flatMap(ProcessCPU.nanoseconds),
                backlog: queued > 0
            )
            switch verdict {
            case .hung:
                log("output_stuck", detail: String(
                    format: "no output for %.1f s, no sign of life for %.1f s",
                    stall.secondsWithoutOutput(now: Self.seconds(now)), stall.secondsWithoutProgress(now: Self.seconds(now))
                ))
                slowSinceUptime = nil
                send(.outputStalled)
                return
            case .slow:
                if slowSinceUptime == nil {
                    slowSinceUptime = now
                    log("output_slow", detail: String(format: "ring %.0f%%", fill * 100))
                }
            case .healthy:
                if let since = slowSinceUptime {
                    log("output_resumed", detail: String(format: "after %.1f s", HostTime.seconds(from: since, to: now)))
                    slowSinceUptime = nil
                }
            }
        }

        if HostTime.seconds(from: lastAudioLogUptime, to: now) >= 60 { logAudio() }

        if let since = healthySinceUptime, HostTime.seconds(from: since, to: now) > 30 {
            watchdog.markHealthy()
            healthySinceUptime = nil
        }

        if settings.fullSyncSeconds > 0, HostTime.seconds(from: lastSyncUptime, to: now) >= settings.fullSyncSeconds {
            lastSyncUptime = now
            let working = current.configuration.workingPath
            let index = current.configuration.indexPath
            DispatchQueue.global(qos: .utility).async {
                Self.fullSync(working)
                Self.fullSync(index)
            }
        }
    }

    private static func seconds(_ uptimeNanos: UInt64) -> Double {
        Double(uptimeNanos) / 1_000_000_000
    }

    /// ffmpeg never forces data to the drive, so without this a power cut could lose more than the last fragment.
    private static func fullSync(_ path: String) {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fcntl(descriptor, F_FULLFSYNC)
        close(descriptor)
    }
}
