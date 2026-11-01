import Foundation

/// SMPTE timecode as a frame count at a nominal rate, with drop-frame numbering for 29.97 and 59.94.
public struct Timecode: Hashable, Codable, Sendable {
    public var frameCount: Int
    public var nominalFPS: Int
    public var isDropFrame: Bool

    public init(frameCount: Int, nominalFPS: Int, isDropFrame: Bool) {
        self.frameCount = frameCount
        self.nominalFPS = nominalFPS
        self.isDropFrame = isDropFrame
    }

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int, nominalFPS: Int, isDropFrame: Bool) {
        var total = (hours * 3600 + minutes * 60 + seconds) * nominalFPS + frames
        if isDropFrame {
            let dropped = Self.droppedPerMinute(nominalFPS)
            let totalMinutes = hours * 60 + minutes
            total -= dropped * (totalMinutes - totalMinutes / 10)
        }
        self.init(frameCount: total, nominalFPS: nominalFPS, isDropFrame: isDropFrame)
    }

    /// The default timecode mode for a rate: drop-frame for NTSC-family rates, non-drop otherwise.
    public init(frameCount: Int, frameRate: Rational) {
        let nominal = Int(frameRate.doubleValue.rounded())
        let drop = frameRate.denominator == 1001 && (nominal == 30 || nominal == 60)
        self.init(frameCount: frameCount, nominalFPS: nominal, isDropFrame: drop)
    }

    public var components: (hours: Int, minutes: Int, seconds: Int, frames: Int) {
        var count = frameCount
        if isDropFrame {
            let dropped = Self.droppedPerMinute(nominalFPS)
            let framesPerMinute = nominalFPS * 60 - dropped
            let framesPer10Minutes = framesPerMinute * 10 + dropped
            let tens = count / framesPer10Minutes
            let remainder = count % framesPer10Minutes
            count += dropped * 9 * tens
            if remainder >= dropped {
                count += dropped * ((remainder - dropped) / framesPerMinute)
            }
        }
        let frames = count % nominalFPS
        let totalSeconds = count / nominalFPS
        return (totalSeconds / 3600 % 24, totalSeconds / 60 % 60, totalSeconds % 60, frames)
    }

    public var string: String {
        let c = components
        let separator = isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", c.hours, c.minutes, c.seconds, separator, c.frames)
    }

    private static func droppedPerMinute(_ nominalFPS: Int) -> Int {
        nominalFPS == 60 ? 4 : 2
    }
}
