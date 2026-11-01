import Foundation

/// Samples per video frame at 48 kHz. Fractional rates alternate, such as 800 and 801 at 59.94,
/// so a filled gap needs the exact count for its frame to keep audio aligned over long recordings.
public enum AudioCadence {
    public static func sampleCount(forFrame frame: UInt64, frameRate: Rational) -> Int {
        Int(cumulativeSamples(throughFrames: frame + 1, frameRate: frameRate)
            - cumulativeSamples(throughFrames: frame, frameRate: frameRate))
    }

    public static func cumulativeSamples(throughFrames frames: UInt64, frameRate: Rational) -> UInt64 {
        let rate = UInt64(AudioFormat.sampleRate)
        let (high, low) = (frames * rate).multipliedFullWidth(by: UInt64(frameRate.denominator))
        return UInt64(frameRate.numerator).dividingFullWidth((high, low)).quotient
    }

    public static func maximumSamplesPerFrame(frameRate: Rational) -> Int {
        Int((Double(AudioFormat.sampleRate) / frameRate.doubleValue).rounded(.up)) + 1
    }
}
