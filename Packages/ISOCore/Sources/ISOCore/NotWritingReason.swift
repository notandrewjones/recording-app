import Foundation

/// Why an input that should be recording has no file being written. Raised once it has lasted
/// `InputRecorderSettings.notWritingAlarmSeconds`, so a normal start or a quick restart never shows it.
public enum NotWritingReason: Hashable, Sendable {
    /// No frame has come from the capture card since recording was requested, or none for a while.
    case noVideo
    /// Frames arrive, but the card says there is no signal on the input.
    case noSignal
    /// ffmpeg is starting, or being replaced after a failure.
    case restarting
    /// The recorder gave up after repeated failures.
    case failed(String)

    /// Decides from what the recorder knows. `secondsSinceFrame` is nil when no frame has arrived at all.
    public init(state: RecorderWatchdog.State, secondsSinceFrame: Double?, hasSignal: Bool, frameTimeoutSeconds: Double) {
        if case .failed(let reason) = state {
            self = .failed(reason)
        } else if let seconds = secondsSinceFrame, seconds <= frameTimeoutSeconds {
            self = hasSignal ? .restarting : .noSignal
        } else {
            self = .noVideo
        }
    }

    /// Lowercase, so it reads inside a sentence: "Program: no video from the capture card".
    public var description: String {
        switch self {
        case .noVideo: "no video from the capture card"
        case .noSignal: "no signal"
        case .restarting: "the recorder is restarting"
        case .failed(let reason): "the recorder gave up (\(reason))"
        }
    }
}
