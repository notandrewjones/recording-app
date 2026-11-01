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
