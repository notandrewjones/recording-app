import Foundation

/// Compares successive stream times to find frames the card or driver failed to deliver.
public struct FrameGapDetector: Hashable, Sendable {
    public enum Result: Hashable, Sendable {
        case continuous
        /// Frames were lost. Filling them keeps file frame N equal to index record N.
        case missing(Int)
        /// The card's clock ran backwards or jumped, but frames kept arriving on the host clock, as when the
        /// card restarts its input. It is the same picture on a new time base, so the gap is measured by
        /// host time and filled, and the segment carries on.
        case clockReset(missing: Int)
        /// Time broke on both clocks, or jumped too far to fill. The timeline needs a new segment.
        case discontinuity
    }

    public let ticksPerFrame: Double
    public let maximumFill: Int
    private let framesPerSecond: Double
    private var lastStreamTime: Int64?
    private var lastHostNanos: UInt64?

    /// - Parameter maximumFill: the longest gap to fill with repeats, as a frame count.
    public init(frameRate: Rational, streamTimeScale: Int64, maximumFill: Int) {
        ticksPerFrame = Double(streamTimeScale) / frameRate.doubleValue
        framesPerSecond = frameRate.doubleValue
        self.maximumFill = maximumFill
    }

    public mutating func observe(streamTime: Int64, hostNanos: UInt64) -> Result {
        defer {
            lastStreamTime = streamTime
            lastHostNanos = hostNanos
        }
        guard let last = lastStreamTime else { return .continuous }
        let frames = (Double(streamTime - last) / ticksPerFrame).rounded()
        if frames == 1 { return .continuous }
        if frames > 1, Int(frames) - 1 <= maximumFill { return .missing(Int(frames) - 1) }
        if let lastHost = lastHostNanos {
            let elapsed = (HostTime.seconds(from: lastHost, to: hostNanos) * framesPerSecond).rounded()
            if elapsed >= 1, Int(elapsed) - 1 <= maximumFill { return .clockReset(missing: Int(elapsed) - 1) }
        }
        return .discontinuity
    }

    public mutating func reset() {
        lastStreamTime = nil
        lastHostNanos = nil
    }
}
