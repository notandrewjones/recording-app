import Foundation

/// Decides what free disk space means for a recording in progress.
public struct StoragePolicy: Hashable, Sendable {
    public enum Level: Hashable, Sendable {
        case ok
        /// Recording continues, but the operator should know how long is left.
        case low(secondsRemaining: Double)
        /// Stop cleanly while there is still room to close files properly.
        case critical
    }

    public var warningSeconds: Double
    public var criticalFreeBytes: Int64

    public init(warningSeconds: Double = 600, criticalFreeBytes: Int64 = 2 * 1_073_741_824) {
        self.warningSeconds = warningSeconds
        self.criticalFreeBytes = criticalFreeBytes
    }

    public func evaluate(freeBytes: Int64, writeBytesPerSecond: Double) -> Level {
        if freeBytes <= criticalFreeBytes { return .critical }
        guard writeBytesPerSecond > 0 else { return .ok }
        let remaining = Double(freeBytes - criticalFreeBytes) / writeBytesPerSecond
        return remaining <= warningSeconds ? .low(secondsRemaining: remaining) : .ok
    }
}

/// The session's write rate, averaged over a sliding window of cumulative byte counts.
/// ffmpeg writes whole fragments in bursts, so a rate over a second or two swings by half or more.
public struct WriteRateMeter: Sendable {
    public var windowSeconds: Double
    /// No rate is reported until this much writing has been seen, so ffmpeg's startup doesn't skew it.
    public var minimumSeconds: Double
    private var samples: [(seconds: Double, bytes: Int64)] = []

    public init(windowSeconds: Double = 30, minimumSeconds: Double = 5) {
        self.windowSeconds = windowSeconds
        self.minimumSeconds = minimumSeconds
    }

    /// `bytes` is the total written so far. Samples before the first byte are ignored.
    public mutating func add(seconds: Double, bytes: Int64) {
        guard bytes > 0 else { return }
        samples.append((seconds, bytes))
        // Keep one sample at or before the window start, so the span covers the whole window.
        while samples.count > 2, seconds - samples[1].seconds >= windowSeconds {
            samples.removeFirst()
        }
    }

    /// Bytes per second over the window, or zero until `minimumSeconds` of writing has been seen.
    public var bytesPerSecond: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let span = last.seconds - first.seconds
        guard span >= minimumSeconds else { return 0 }
        return Double(max(0, last.bytes - first.bytes)) / span
    }
}

/// How close one input is to losing frames, judged by how full its ring has become.
public enum InputLoad: Hashable, Sendable {
    case healthy
    /// The encoder is falling behind and frames will repeat if this continues.
    case strained
    case overloaded

    public init(ringFill: Double) {
        switch ringFill {
        case ..<0.5: self = .healthy
        case ..<0.9: self = .strained
        default: self = .overloaded
        }
    }
}

public extension Double {
    /// `1h 05m` or `12m 30s`, for time remaining on a drive.
    var durationDescription: String {
        let total = Int(self)
        if total >= 3600 { return String(format: "%dh %02dm", total / 3600, total % 3600 / 60) }
        return String(format: "%dm %02ds", total / 60, total % 60)
    }
}
