import Foundation

/// Tells a slow recorder from a stuck one. Killing ffmpeg loses its unwritten fragment and starts a new one
/// at the worst moment: on an 8 GB M1 under memory pressure, a kill every few minutes fed the pressure that
/// caused the next. A slow ffmpeg is left alone, since the ring already drops frames gracefully while it
/// catches up. Only one with no sign of life at all, or none of output for a long time, is replaced.
public struct StallDetector: Hashable, Sendable {
    public enum Verdict: Hashable, Sendable {
        case healthy
        /// Output has not grown for `slowSeconds`, but ffmpeg is still taking frames or using the CPU.
        case slow
        /// No progress of any kind for `hungSeconds`, or no output for `hardSeconds`.
        case hung
    }

    public var slowSeconds: Double
    public var hungSeconds: Double
    public var hardSeconds: Double
    /// CPU use between two samples, as a fraction of one core, that counts as working. A blocked ffmpeg
    /// uses next to none; one that is encoding uses far more.
    public var busyCPUFraction: Double

    private var lastSample: Double?
    private var lastOutputBytes: Int64 = 0
    private var lastInputFrames = 0
    private var lastCPUNanos: UInt64?
    private var outputSince: Double = 0
    private var progressSince: Double = 0

    public init(slowSeconds: Double = 5, hungSeconds: Double = 10, hardSeconds: Double = 30, busyCPUFraction: Double = 0.05) {
        self.slowSeconds = slowSeconds
        self.hungSeconds = hungSeconds
        self.hardSeconds = hardSeconds
        self.busyCPUFraction = busyCPUFraction
    }

    /// Starts timing afresh, for a new ffmpeg writing a new file.
    public mutating func reset(now: Double) {
        lastSample = now
        lastOutputBytes = 0
        lastInputFrames = 0
        lastCPUNanos = nil
        outputSince = now
        progressSince = now
    }

    public func secondsWithoutOutput(now: Double) -> Double { now - outputSince }
    public func secondsWithoutProgress(now: Double) -> Double { now - progressSince }

    /// - Parameters:
    ///   - outputBytes: size of the file being written.
    ///   - inputFrames: frames ffmpeg has accepted from the app so far.
    ///   - cpuNanos: ffmpeg's total CPU time, or nil if it could not be read.
    ///   - backlog: whether frames are waiting. With none, the source has paused, which is not ffmpeg's fault.
    public mutating func observe(now: Double, outputBytes: Int64, inputFrames: Int, cpuNanos: UInt64?, backlog: Bool) -> Verdict {
        let interval = lastSample.map { now - $0 } ?? 0
        if outputBytes > lastOutputBytes {
            outputSince = now
            progressSince = now
        }
        if inputFrames > lastInputFrames {
            progressSince = now
        }
        if let cpu = cpuNanos, let last = lastCPUNanos, interval > 0, cpu > last,
           Double(cpu - last) / 1e9 / interval >= busyCPUFraction {
            progressSince = now
        }
        lastSample = now
        lastOutputBytes = max(lastOutputBytes, outputBytes)
        lastInputFrames = max(lastInputFrames, inputFrames)
        if let cpuNanos { lastCPUNanos = cpuNanos }

        guard backlog else {
            outputSince = now
            progressSince = now
            return .healthy
        }
        if now - outputSince > hardSeconds || now - progressSince > hungSeconds { return .hung }
        if now - outputSince > slowSeconds { return .slow }
        return .healthy
    }
}
