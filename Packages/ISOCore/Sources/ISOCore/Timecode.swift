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

    /// Time-of-day timecode, used when the signal carries none or the input is set to generate it.
    /// Drop-frame numbering tracks the wall clock at the real rate. Non-drop numbering counts at the nominal
    /// rate, so 23.976 reads the right time when it starts rather than falling behind through the day.
    public static func timeOfDay(date: Date, frameRate: Rational, calendar: Calendar = .current) -> Timecode {
        let midnight = calendar.startOfDay(for: date)
        let seconds = max(0, date.timeIntervalSince(midnight))
        let mode = Timecode(frameCount: 0, frameRate: frameRate)
        let rate = mode.isDropFrame ? frameRate.doubleValue : Double(mode.nominalFPS)
        return Timecode(frameCount: Int(seconds * rate), nominalFPS: mode.nominalFPS, isDropFrame: mode.isDropFrame)
    }

    public func advanced(by frames: Int) -> Timecode {
        Timecode(frameCount: frameCount + frames, nominalFPS: nominalFPS, isDropFrame: isDropFrame)
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

/// Where an input's recorded timecode comes from.
public enum TimecodeSource: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The signal's embedded timecode, or time of day when it carries none.
    case source
    /// Always time of day from this Mac's clock, ignoring any embedded timecode.
    case timeOfDay

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .source: "Source timecode (time of day if none)"
        case .timeOfDay: "Time of day"
        }
    }

    public var shortLabel: String {
        switch self {
        case .source: "SRC"
        case .timeOfDay: "TOD"
        }
    }
}
