import Darwin
import Foundation
import ISOCore

/// Records one segment: spawns ffmpeg for the first frame's timecode, then feeds it from the ring until
/// the ring closes or ffmpeg dies. Everything runs on its own threads, so a stalled ffmpeg blocks nothing else.
final class SegmentRecorder: @unchecked Sendable {
    struct Configuration {
        var number: Int
        var codec: Codec
        var audio: AudioFormat?
        var workingPath: String
        var indexPath: String
        var logPath: String
        var videoSocketPath: String
        var audioSocketPath: String
        var environment: FFmpegEnvironment
        var streamTimeScale: Int64
        var allowSoftwareProRes: Bool
        var timecodeSource: TimecodeSource
    }

    struct Opening {
        var startTimecode: Timecode
        var timecodeIsEmbedded: Bool
        var timecodeSource: TimecodeSource
        var startHostNanos: UInt64
    }

    struct Outcome {
        var framesWritten: Int
        var repeatedFrames: Int
        var exitCode: Int32?
        /// ffmpeg was never launched because the ring closed before a first frame arrived.
        var neverStarted: Bool
        /// Every queued frame reached ffmpeg, so this was a clean end rather than a failure.
        var drained: Bool
        /// Host time of the last frame written, used to measure the gap to the next segment.
        var lastHostNanos: UInt64 = 0
    }

    let configuration: Configuration
    let ring: FrameRing

    var onOpened: ((Opening) -> Void)?
    var onConnected: (() -> Void)?
    var onFinished: ((Outcome) -> Void)?

    private let lock = UnfairLock()
    private var process: Process?
    private var aborted = false
    private var framesWritten = 0
    private var repeatedFrames = 0
    private var lastHostNanos: UInt64 = 0

    private var isAborted: Bool { lock.withLock { aborted } }
    private var usesEmbeddedTimecode: Bool { configuration.timecodeSource == .source }

    init(configuration: Configuration, ring: FrameRing) {
        self.configuration = configuration
        self.ring = ring
    }

    func start() {
        let thread = Thread { [self] in
            run()
            // The owner's callbacks capture this recorder, so dropping them is what lets it and its ring go.
            onOpened = nil
            onConnected = nil
            onFinished = nil
        }
        thread.name = "segment-video-\(configuration.number)"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Kills ffmpeg, which unblocks any writer stuck in a socket write.
    func kill() {
        let running: Process? = lock.withLock {
            aborted = true
            return process
        }
        if let running, running.isRunning {
            Darwin.kill(running.processIdentifier, SIGKILL)
        }
    }

    var counters: (frames: Int, repeated: Int) {
        lock.withLock { (framesWritten, repeatedFrames) }
    }

    var bytesOnDisk: Int64 {
        var info = stat()
        return stat(configuration.workingPath, &info) == 0 ? info.st_size : 0
    }

    var processIdentifier: Int32? {
        lock.withLock { process?.processIdentifier }
    }

    private func run() {
        guard let first = waitForFirstFrame() else {
            onFinished?(Outcome(framesWritten: 0, repeatedFrames: 0, exitCode: nil, neverStarted: true, drained: true))
            return
        }

        let embedded = usesEmbeddedTimecode ? first.metadata.timecode : nil
        // Time of day is taken from when the first frame arrived, not from now: frames carried over in the
        // ring after a restart can be most of a second old.
        let arrived = HostTime.date(ofHostNanos: first.metadata.hostTimeNanos, now: Date(), nowHostNanos: DispatchTime.now().uptimeNanoseconds)
        let startTimecode = embedded ?? Timecode.timeOfDay(date: arrived, frameRate: ring.format.frameRate)
        let opening = Opening(startTimecode: startTimecode, timecodeIsEmbedded: embedded != nil, timecodeSource: configuration.timecodeSource, startHostNanos: first.metadata.hostTimeNanos)

        guard let launched = launchProcess(startTimecode: startTimecode) else {
            onFinished?(Outcome(framesWritten: 0, repeatedFrames: 0, exitCode: -1, neverStarted: false, drained: false))
            return
        }
        lock.withLock { process = launched }
        onOpened?(opening)

        let keepTrying = { [self] in launched.isRunning && !isAborted }
        let videoSocket = UnixSocketWriter()
        var drained = false
        let audioDone = DispatchSemaphore(value: 0)
        let hasAudio = configuration.audio != nil

        if videoSocket.connect(path: configuration.videoSocketPath, shouldContinue: keepTrying) {
            onConnected?()
            if hasAudio {
                startAudioThread(process: launched, done: audioDone)
            }
            drained = feedVideo(socket: videoSocket, startTimecode: startTimecode, process: launched)
        }
        videoSocket.close()

        if !drained {
            lock.withLock { aborted = true }
            if launched.isRunning { Darwin.kill(launched.processIdentifier, SIGKILL) }
        }
        if hasAudio && videoSocket.didConnect { audioDone.wait() }
        let exitCode = waitForExit(launched)

        unlink(configuration.videoSocketPath)
        unlink(configuration.audioSocketPath)
        let totals = counters
        onFinished?(Outcome(framesWritten: totals.frames, repeatedFrames: totals.repeated, exitCode: exitCode, neverStarted: false, drained: drained, lastHostNanos: lock.withLock { lastHostNanos }))
    }

    private func waitForFirstFrame() -> FrameRing.Entry? {
        while !isAborted {
            switch ring.next(.video, timeout: 0.1) {
            case .entry(let entry): return entry
            case .closed: return nil
            case .timedOut: continue
            }
        }
        return nil
    }

    private func launchProcess(startTimecode: Timecode) -> Process? {
        unlink(configuration.videoSocketPath)
        unlink(configuration.audioSocketPath)
        let recorderConfiguration = RecorderConfiguration(
            format: ring.format,
            codec: configuration.codec,
            audio: configuration.audio,
            videoSocketPath: configuration.videoSocketPath,
            audioSocketPath: configuration.audio == nil ? nil : configuration.audioSocketPath,
            startTimecode: startTimecode,
            outputPath: configuration.workingPath,
            allowSoftwareProRes: configuration.allowSoftwareProRes
        )
        guard let arguments = try? FFmpegCommand.recordArguments(recorderConfiguration) else { return nil }

        FileManager.default.createFile(atPath: configuration.logPath, contents: nil)
        guard let log = FileHandle(forWritingAtPath: configuration.logPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.environment.ffmpegPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    /// Returns true if the ring closed and every frame was delivered.
    private func feedVideo(socket: UnixSocketWriter, startTimecode: Timecode, process: Process) -> Bool {
        let format = ring.format
        guard let index = FrameIndexWriter(path: configuration.indexPath, frameRate: format.frameRate, streamTimeScale: configuration.streamTimeScale) else { return false }
        defer { index.close() }

        let keepGoing = { [self] in !isAborted }
        var ordinal: UInt64 = 0
        var isFirst = true

        func writeFrame(_ pointer: UnsafeRawPointer, metadata: FrameRing.Metadata, repeated: Bool) -> Bool {
            guard socket.write(pointer, count: format.frameBytes, shouldContinue: keepGoing) == .finished else { return false }
            var flags: FrameIndexRecord.Flags = repeated ? .repeated : []
            // The index records the file's timecode, so a generated time of day ignores the embedded one.
            let timecode = repeated || !usesEmbeddedTimecode ? nil : metadata.timecode
            if timecode != nil { flags.insert(.embeddedTimecode) }
            index.append(FrameIndexRecord(
                frameNumber: ordinal,
                hostTimeNanos: metadata.hostTimeNanos,
                streamTime: metadata.streamTime,
                timecodeFrames: UInt32((timecode ?? startTimecode.advanced(by: Int(ordinal))).frameCount),
                flags: flags
            ))
            ordinal += 1
            lock.withLock {
                framesWritten += 1
                lastHostNanos = metadata.hostTimeNanos
                if repeated { repeatedFrames += 1 }
            }
            return true
        }

        while !isAborted {
            switch ring.next(.video, timeout: 0.1) {
            case .closed:
                return true
            case .timedOut:
                if !process.isRunning { return false }
            case .entry(let entry):
                // A gap before a segment's first frame belongs to the break between segments, not this file.
                if !isFirst, let previous = ring.previousVideoFrame {
                    for _ in 0..<entry.missingBefore {
                        guard writeFrame(previous, metadata: entry.metadata, repeated: true) else { return false }
                    }
                }
                guard writeFrame(entry.video, metadata: entry.metadata, repeated: false) else { return false }
                isFirst = false
                ring.advance(.video)
            }
        }
        return false
    }

    private func startAudioThread(process: Process, done: DispatchSemaphore) {
        let thread = Thread { [self] in
            feedAudio(process: process)
            done.signal()
        }
        thread.name = "segment-audio-\(configuration.number)"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func feedAudio(process: Process) {
        guard let audio = configuration.audio else { return }
        let keepTrying = { [self] in process.isRunning && !isAborted }
        let socket = UnixSocketWriter()
        guard socket.connect(path: configuration.audioSocketPath, shouldContinue: keepTrying) else { return }
        defer { socket.close() }

        let frameRate = ring.format.frameRate
        let bytesPerSample = audio.channels * 4
        let silence = UnsafeMutableRawPointer.allocate(byteCount: ring.audioSlotBytes, alignment: 16)
        memset(silence, 0, ring.audioSlotBytes)
        defer { silence.deallocate() }

        var ordinal: UInt64 = 0
        var isFirst = true
        while !isAborted {
            switch ring.next(.audio, timeout: 0.1) {
            case .closed:
                return
            case .timedOut:
                if !process.isRunning { return }
            case .entry(let entry):
                if !isFirst {
                    for _ in 0..<entry.missingBefore {
                        let bytes = AudioCadence.sampleCount(forFrame: ordinal, frameRate: frameRate) * bytesPerSample
                        guard socket.write(silence, count: bytes, shouldContinue: keepTrying) == .finished else { return }
                        ordinal += 1
                    }
                }
                guard socket.write(entry.audio, count: entry.audioBytes, shouldContinue: keepTrying) == .finished else { return }
                ordinal += 1
                isFirst = false
                ring.advance(.audio)
            }
        }
    }

    private func waitForExit(_ process: Process) -> Int32 {
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        return process.terminationStatus
    }
}

/// Appends `.idx` records straight to the file, so the index survives a crash as well as the media does.
final class FrameIndexWriter {
    private let descriptor: Int32

    init?(path: String, frameRate: Rational, streamTimeScale: Int64) {
        descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { return nil }
        write(FrameIndexFile.encode(FrameIndexFile.Header(frameRate: frameRate, streamTimescale: streamTimeScale)))
    }

    func append(_ record: FrameIndexRecord) {
        write(FrameIndexFile.encode(record))
    }

    private func write(_ data: Data) {
        data.withUnsafeBytes { _ = Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    func close() {
        Darwin.close(descriptor)
    }
}
