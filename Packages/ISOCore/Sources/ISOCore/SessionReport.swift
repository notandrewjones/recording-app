import Foundation

/// One line of `health.jsonl`, written every few seconds while recording.
public struct HealthSample: Codable, Hashable, Sendable {
    public struct Input: Codable, Hashable, Sendable {
        public var id: String
        public var ringFill: Double
        public var frames: Int
        public var repeatedFrames: Int
        public var restarts: Int

        public init(id: String, ringFill: Double, frames: Int, repeatedFrames: Int, restarts: Int) {
            self.id = id
            self.ringFill = ringFill
            self.frames = frames
            self.repeatedFrames = repeatedFrames
            self.restarts = restarts
        }
    }

    public var seconds: Double
    public var cpu: Double
    public var memoryPressure: Int
    public var memoryUsedBytes: UInt64
    public var appResidentBytes: UInt64
    public var ffmpegResidentBytes: UInt64
    public var freeBytes: Int64
    public var writeBytesPerSecond: Double
    public var inputs: [Input]

    public init(seconds: Double, cpu: Double, memoryPressure: Int, memoryUsedBytes: UInt64, appResidentBytes: UInt64, ffmpegResidentBytes: UInt64, freeBytes: Int64, writeBytesPerSecond: Double, inputs: [Input]) {
        self.seconds = seconds
        self.cpu = cpu
        self.memoryPressure = memoryPressure
        self.memoryUsedBytes = memoryUsedBytes
        self.appResidentBytes = appResidentBytes
        self.ffmpegResidentBytes = ffmpegResidentBytes
        self.freeBytes = freeBytes
        self.writeBytesPerSecond = writeBytesPerSecond
        self.inputs = inputs
    }
}

public enum HostTime {
    /// Zero if `end` is earlier. Timestamps taken on different threads can land in either order, and an
    /// unsigned subtraction that goes negative traps, which would stop every input in the process.
    public static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end > start ? Double(end - start) / 1_000_000_000 : 0
    }

    /// The wall-clock time of a host timestamp, from a (date, host time) pair sampled together just now.
    /// A timestamp later than `nowHostNanos` maps to `now`, since it can only be a moment old.
    public static func date(ofHostNanos hostNanos: UInt64, now: Date, nowHostNanos: UInt64) -> Date {
        now.addingTimeInterval(-seconds(from: hostNanos, to: nowHostNanos))
    }
}

/// First and last real frames of a segment, for checking frame count against elapsed time.
public struct SegmentTiming: Hashable, Sendable {
    public var inputLabel: String
    public var number: Int
    public var records: Int
    public var firstHostNanos: UInt64
    public var lastHostNanos: UInt64
    public var frameRate: Rational
    /// Repeats after the last real frame. A crash can stop partway through a run of them, and each carries
    /// the time of the frame that ended the gap, so they say nothing about the frames before it.
    public var trailingRepeats: Int

    public init(inputLabel: String, number: Int, records: Int, firstHostNanos: UInt64, lastHostNanos: UInt64, frameRate: Rational, trailingRepeats: Int = 0) {
        self.inputLabel = inputLabel
        self.number = number
        self.records = records
        self.firstHostNanos = firstHostNanos
        self.lastHostNanos = lastHostNanos
        self.frameRate = frameRate
        self.trailingRepeats = trailingRepeats
    }

    /// Frames elapsed by the clock minus frames recorded. Non-zero means frames went missing unnoticed.
    public var driftFrames: Double {
        let elapsed = HostTime.seconds(from: firstHostNanos, to: lastHostNanos)
        return elapsed * frameRate.doubleValue - Double(records - 1 - trailingRepeats)
    }
}

/// Judges a finished recording. Anything a viewer or editor would notice is a failure.
public struct SessionReport: Sendable {
    public enum Severity: String, Sendable {
        case failure = "FAIL"
        case warning = "WARN"
    }

    public struct Finding: Hashable, Sendable {
        public var severity: Severity
        public var message: String
    }

    /// Memory growth above this share of the starting size, between the early and late run, is flagged.
    static let memoryGrowthLimit = 0.15
    /// Early memory is ignored while rings and encoders settle.
    static let warmupSeconds = 60.0
    static let driftLimitFrames = 2.0

    public var findings: [Finding] = []
    public var summary: [String] = []

    public var passed: Bool { !findings.contains { $0.severity == .failure } }

    public init(manifest: SessionManifest, health: [HealthSample], timings: [SegmentTiming]) {
        let segments = manifest.inputs.flatMap(\.segments)
        let duration = health.last?.seconds ?? 0
        summary.append("Session: \(manifest.name)")
        summary.append("Inputs: \(manifest.inputs.count), segments: \(segments.count), frames: \(segments.map(\.frames).reduce(0, +))")
        summary.append(String(format: "Health samples: %d over %@", health.count, duration.durationDescription))

        for input in manifest.inputs {
            checkInput(input)
        }
        for timing in timings where abs(timing.driftFrames) > Self.driftLimitFrames {
            findings.append(Finding(severity: .failure, message: String(format: "%@ segment %d: clock and frame count differ by %.1f frames.", timing.inputLabel, timing.number, timing.driftFrames)))
        }
        if let worst = timings.map({ abs($0.driftFrames) }).max() {
            summary.append(String(format: "Worst clock drift: %.2f frames", worst))
        }
        checkHealth(health)
    }

    private mutating func checkInput(_ input: SessionManifest.InputRecord) {
        let repeated = input.segments.map(\.repeatedFrames).reduce(0, +)
        let lost = input.segments.map(\.lostFrames).reduce(0, +)
        let unfinished = input.segments.filter { $0.state != .finalized }.count
        let failures = input.segments.filter { $0.endReason == .recorderFailed }.count
        let signal = input.events.filter { $0.kind == "signal_lost" }.count
        let slow = input.events.filter { $0.kind == "output_slow" }.count
        let unlocked = input.events.filter { $0.kind == "ring_memory" && $0.detail?.hasPrefix("locked") == false }.count
        let finalizeReason = input.segments.compactMap(\.finalizeError).first

        if repeated > 0 { findings.append(Finding(severity: .failure, message: "\(input.label): \(repeated) repeated frames.")) }
        if lost > 0 { findings.append(Finding(severity: .failure, message: "\(input.label): \(lost) frames lost in a crash.")) }
        if failures > 0 { findings.append(Finding(severity: .failure, message: "\(input.label): recorder failed \(failures) times.")) }
        if unfinished > 0 {
            let reason = finalizeReason.map { " First reason: \($0)." } ?? ""
            findings.append(Finding(severity: .failure, message: "\(input.label): \(unfinished) segments not finalized.\(reason)"))
        }
        if slow > 0 { findings.append(Finding(severity: .warning, message: "\(input.label): ffmpeg fell behind \(slow) times.")) }
        if unlocked > 0 { findings.append(Finding(severity: .warning, message: "\(input.label): frame ring could not be locked in memory.")) }
        if signal > 0 { findings.append(Finding(severity: .warning, message: "\(input.label): signal lost \(signal) times.")) }
    }

    private mutating func checkHealth(_ health: [HealthSample]) {
        guard !health.isEmpty else {
            findings.append(Finding(severity: .warning, message: "No health samples were recorded."))
            return
        }
        let peakRing = health.flatMap(\.inputs).map(\.ringFill).max() ?? 0
        let peakCPU = health.map(\.cpu).max() ?? 0
        summary.append(String(format: "Peak ring: %.0f%%, peak CPU: %.0f%%", peakRing * 100, peakCPU * 100))
        if peakRing >= 0.9 {
            findings.append(Finding(severity: .warning, message: String(format: "Ring reached %.0f%%, close to repeating frames.", peakRing * 100)))
        }
        if health.contains(where: { $0.memoryPressure >= 4 }) {
            findings.append(Finding(severity: .warning, message: "Memory pressure reached critical."))
        }
        let pressured = Double(health.filter { $0.memoryPressure >= 2 }.count) / Double(health.count)
        if pressured >= 0.1 {
            findings.append(Finding(severity: .warning, message: String(format: "Memory pressure was raised for %.0f%% of the run.", pressured * 100)))
        }
        checkGrowth(health, name: "App memory", value: \.appResidentBytes)
        checkGrowth(health, name: "ffmpeg memory", value: \.ffmpegResidentBytes)
    }

    /// Compares the first and last fifths of the run, so a brief spike cannot pass for a leak.
    private mutating func checkGrowth(_ health: [HealthSample], name: String, value: KeyPath<HealthSample, UInt64>) {
        let settled = health.filter { $0.seconds >= Self.warmupSeconds }
        let window = settled.count / 5
        guard window >= 1 else { return }
        func average(_ samples: ArraySlice<HealthSample>) -> Double {
            samples.map { Double($0[keyPath: value]) }.reduce(0, +) / Double(samples.count)
        }
        let early = average(settled.prefix(window))
        let late = average(settled.suffix(window))
        guard early > 0 else { return }
        summary.append(String(format: "%@: %.0f MB early, %.0f MB late", name, early / 1_048_576, late / 1_048_576))
        if (late - early) / early > Self.memoryGrowthLimit {
            findings.append(Finding(severity: .warning, message: String(format: "%@ grew %.0f%% during the run.", name, (late - early) / early * 100)))
        }
    }

    public var text: String {
        var lines = ["RESULT: \(passed ? "PASS" : "FAIL")", ""] + summary
        if !findings.isEmpty {
            lines.append("")
            lines += findings.map { "\($0.severity.rawValue): \($0.message)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
