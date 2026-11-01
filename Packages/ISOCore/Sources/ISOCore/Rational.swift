import Foundation

/// An exact frame rate or duration. Broadcast rates such as 60000/1001 are not representable in floating point.
public struct Rational: Hashable, Codable, Sendable {
    public var numerator: Int64
    public var denominator: Int64

    public init(_ numerator: Int64, _ denominator: Int64) {
        precondition(denominator != 0, "Rational denominator must be non-zero")
        self.numerator = numerator
        self.denominator = denominator
    }

    public var doubleValue: Double { Double(numerator) / Double(denominator) }

    /// ffmpeg's `num/den` notation.
    public var ffmpegString: String { "\(numerator)/\(denominator)" }
}
