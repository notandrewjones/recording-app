import Foundation

/// Why an input that should be recording is not recording properly. Not writing is raised once it has lasted
/// `InputRecorderSettings.notWritingAlarmSeconds`, so a normal start or a quick restart never shows it.
/// Instability is raised as soon as restarts pass `InputRecorderSettings.instabilityLimit`. A recorder restart
/// is raised at once and stays raised for `InputRecorderSettings.restartAlarmSeconds`.
public enum RecordingProblem: Hashable, Sendable {
    /// No frame has come from the capture card since recording was requested, or none for a while.
    case noVideo
    /// Frames arrive, but the card says there is no signal on the input.
    case noSignal
    /// ffmpeg is starting, or being replaced after a failure.
    case restarting
    /// The recorder gave up after repeated failures.
    case failed(String)
    /// The input keeps restarting: new files, or the card restarting its clock. A file may be open, but
    /// what it holds is broken up or padded with repeats.
    case unstable(restarts: Int, seconds: Int)
    /// ffmpeg had to be replaced while recording, this many times in the last `minutes`. Recording has
    /// carried on in a new file, but each restart lost a moment and repeated frames over it.
    case restarted(times: Int, minutes: Int)

    /// Decides why nothing is being written, from what the recorder knows. `secondsSinceFrame` is nil when
    /// no frame has arrived at all.
    public init(state: RecorderWatchdog.State, secondsSinceFrame: Double?, hasSignal: Bool, frameTimeoutSeconds: Double) {
        if case .failed(let reason) = state {
            self = .failed(reason)
        } else if let seconds = secondsSinceFrame, seconds <= frameTimeoutSeconds {
            self = hasSignal ? .restarting : .noSignal
        } else {
            self = .noVideo
        }
    }

    /// False where frames are still reaching a file.
    public var savesNothing: Bool {
        switch self {
        case .unstable, .restarted: false
        default: true
        }
    }

    /// The short label on an input's tile.
    public var chipText: String {
        switch self {
        case .unstable: "UNSTABLE"
        case .restarted: "RESTARTED"
        default: "NOT RECORDING"
        }
    }

    /// Lowercase, so it reads inside a sentence: "Program: no video from the capture card".
    public var description: String {
        switch self {
        case .noVideo: "no video from the capture card"
        case .noSignal: "no signal"
        case .restarting: "the recorder is restarting"
        case .failed(let reason): "the recorder gave up (\(reason))"
        case .unstable(let restarts, let seconds): "the input keeps restarting (\(restarts) times in \(seconds) s)"
        case .restarted(let times, let minutes):
            "the recorder had to restart (\(times == 1 ? "once" : "\(times) times") in the last \(minutes) min)"
        }
    }
}
