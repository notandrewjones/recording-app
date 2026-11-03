import Foundation

/// Per-input recorder supervision as a pure state machine. The caller feeds events and performs the actions.
public struct RecorderWatchdog: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case idle
        case starting(segment: Int)
        case recording(segment: Int)
        /// Waiting for signal to return before opening the next segment.
        case waitingForSignal(nextSegment: Int)
        case backingOff(nextSegment: Int, attempt: Int)
        case failed(reason: String)
    }

    public enum Event: Hashable, Sendable {
        case recordRequested
        case stopRequested
        case processStarted
        /// Carries the segment so the exit of a closed segment is not mistaken for a crash of its successor.
        case processExited(segment: Int, code: Int32)
        /// No output growth for longer than the stall threshold.
        case outputStalled
        case signalLost
        /// Recording was requested before any valid frame arrived, so the segment number is still unused.
        case noSignalYet
        case signalRestored
        case formatChanged
        case backoffElapsed
    }

    public enum Action: Hashable, Sendable {
        case startProcess(segment: Int)
        case stopProcess
        case killProcess
        case scheduleRetry(afterSeconds: Double)
        case log(String)
    }

    public private(set) var state: State = .idle
    public private(set) var nextSegment = 1
    public var maxAttempts: Int

    public init(maxAttempts: Int = 5) {
        self.maxAttempts = maxAttempts
    }

    public mutating func handle(_ event: Event) -> [Action] {
        switch (state, event) {
        case (.idle, .recordRequested), (.failed, .recordRequested):
            return start(segment: nextSegment)

        case (_, .stopRequested):
            let wasRunning = isProcessActive
            // A segment that was opened is finished, so recording again in this session needs a new number.
            // A segment still waiting for signal or a retry was never opened, and keeps its number.
            if case .starting(let segment) = state { nextSegment = segment + 1 }
            if case .recording(let segment) = state { nextSegment = segment + 1 }
            state = .idle
            return wasRunning ? [.stopProcess] : []

        case (.starting(let segment), .processStarted):
            state = .recording(segment: segment)
            return [.log("segment \(segment) recording")]

        case (.starting(let segment), .processExited(let exited, let code)) where exited == segment,
             (.recording(let segment), .processExited(let exited, let code)) where exited == segment:
            return retry(after: segment, attempt: 1, reason: "ffmpeg exited with code \(code)")

        case (.recording(let segment), .outputStalled), (.starting(let segment), .outputStalled):
            return [.killProcess] + retry(after: segment, attempt: 1, reason: "output stalled")

        case (.recording(let segment), .signalLost), (.starting(let segment), .signalLost):
            state = .waitingForSignal(nextSegment: segment + 1)
            nextSegment = segment + 1
            return [.stopProcess, .log("signal lost, closed segment \(segment)")]

        case (.starting(let segment), .noSignalYet):
            state = .waitingForSignal(nextSegment: segment)
            return []

        case (.recording(let segment), .formatChanged), (.starting(let segment), .formatChanged):
            nextSegment = segment + 1
            state = .starting(segment: nextSegment)
            return [.stopProcess, .startProcess(segment: nextSegment), .log("format changed, closed segment \(segment)")]

        case (.waitingForSignal(let next), .signalRestored):
            return start(segment: next)

        case (.backingOff(let next, _), .signalLost):
            state = .waitingForSignal(nextSegment: next)
            return [.log("signal lost during retry")]

        case (.backingOff(let next, let attempt), .backoffElapsed):
            state = .starting(segment: next)
            nextSegment = next
            pendingAttempt = attempt
            return [.startProcess(segment: next)]

        default:
            return []
        }
    }

    /// Attempt carried from a backoff into the following start, so a process that dies again keeps escalating.
    private var pendingAttempt = 0

    private var isProcessActive: Bool {
        switch state {
        case .starting, .recording: true
        default: false
        }
    }

    private mutating func start(segment: Int) -> [Action] {
        state = .starting(segment: segment)
        nextSegment = segment
        pendingAttempt = 0
        return [.startProcess(segment: segment)]
    }

    private mutating func retry(after segment: Int, attempt: Int, reason: String) -> [Action] {
        let current = max(attempt, pendingAttempt + 1)
        guard current <= maxAttempts else {
            // Recording again after giving up must not reopen the failed segment's files.
            nextSegment = segment + 1
            state = .failed(reason: reason)
            return [.log("giving up after \(maxAttempts) attempts: \(reason)")]
        }
        let next = segment + 1
        nextSegment = next
        state = .backingOff(nextSegment: next, attempt: current)
        return [
            .scheduleRetry(afterSeconds: Self.backoffSeconds(attempt: current)),
            .log("\(reason), retrying as segment \(next) (attempt \(current))"),
        ]
    }

    public static func backoffSeconds(attempt: Int) -> Double {
        min(0.25 * pow(2, Double(attempt - 1)), 5)
    }

    /// A segment that has stayed healthy resets escalation, so unrelated failures hours apart never add up.
    public mutating func markHealthy() {
        pendingAttempt = 0
    }
}
