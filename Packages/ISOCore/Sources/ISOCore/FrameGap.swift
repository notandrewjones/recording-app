import Foundation

/// Compares successive stream times to find frames the card or driver failed to deliver.
public struct FrameGapDetector: Hashable, Sendable {
    public enum Result: Hashable, Sendable {
        case continuous
        /// Frames were lost. Filling them keeps file frame N equal to index record N.
        case missing(Int)
        /// Time jumped too far to fill, or ran backwards. The timeline needs a new segment.
        case discontinuity
    }

    public let ticksPerFrame: Double
    public let maximumFill: Int
    private var lastStreamTime: Int64?

    /// - Parameter maximumFill: the longest gap to fill with repeats, as a frame count.
    public init(frameRate: Rational, streamTimeScale: Int64, maximumFill: Int) {
        ticksPerFrame = Double(streamTimeScale) / frameRate.doubleValue
        self.maximumFill = maximumFill
    }

    public mutating func observe(streamTime: Int64) -> Result {
        defer { lastStreamTime = streamTime }
        guard let last = lastStreamTime else { return .continuous }
        let frames = (Double(streamTime - last) / ticksPerFrame).rounded()
        if frames < 1 { return .discontinuity }
        if frames == 1 { return .continuous }
        let missing = Int(frames) - 1
        return missing > maximumFill ? .discontinuity : .missing(missing)
    }

    public mutating func reset() {
        lastStreamTime = nil
    }
}
