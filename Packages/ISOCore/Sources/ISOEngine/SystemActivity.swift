import Foundation
import IOKit.pwr_mgt

/// Keeps macOS from slowing this process down, or treating the Mac as idle, while it records.
///
/// On 2026-11-22 the church Mac was left alone through a service. Jump Desktop stopped declaring the user
/// active, the display went off at 11:17, and at 11:19 macOS started `mediaanalysisd`'s hour-long video
/// analysis, which it saves for an idle Mac. That load made the encoder fall behind. App Nap was also active
/// on the app. Recording now holds three things:
///
/// - A `ProcessInfo` activity that turns App Nap off, keeps timers precise, and stops idle system sleep.
/// - No idle display sleep, so the display stays on and alarms stay visible.
/// - The user declared active every `refreshSeconds`, which is what keeps idle-only maintenance from starting.
///   A declaration times out on its own, so it is repeated for as long as the activity lasts.
///
/// Every assertion is named after `reason`, so `pmset -g assertions` shows who is holding the Mac awake.
public final class SystemActivity: @unchecked Sendable {
    public let reason: String
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    private var timer: DispatchSourceTimer?
    private var assertionID: IOPMAssertionID = 0
    private var failure: String?

    /// While inputs are recording. Holds everything: no App Nap, no idle sleep of the system or display, and
    /// the user kept active.
    public static func recording(reason: String = "ISO Recorder is recording") -> SystemActivity {
        SystemActivity(reason: reason, options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], declaresUserActivity: true)
    }

    /// While files are finalized after recording stops. No App Nap and no idle system sleep, so finishing is
    /// not slowed or paused, but the display may sleep and maintenance may run.
    public static func finishing(reason: String = "ISO Recorder is finishing recordings") -> SystemActivity {
        SystemActivity(reason: reason, options: [.userInitiated], declaresUserActivity: false)
    }

    public init(reason: String, options: ProcessInfo.ActivityOptions, declaresUserActivity: Bool, refreshSeconds: Double = 30) {
        self.reason = reason
        token = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        guard declaresUserActivity else { return }
        declareUserActivity()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + refreshSeconds, repeating: refreshSeconds, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.declareUserActivity() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        end()
    }

    /// Why the user could not be declared active, if the last attempt failed. The `ProcessInfo` activity
    /// cannot fail.
    public var userActivityFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// Releases everything. Safe to call more than once.
    public func end() {
        lock.lock()
        let (token, timer, assertion) = (self.token, self.timer, assertionID)
        self.token = nil
        self.timer = nil
        assertionID = 0
        lock.unlock()
        timer?.cancel()
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }

    private func declareUserActivity() {
        lock.lock()
        defer { lock.unlock() }
        // Ended while this was queued.
        guard token != nil else { return }
        // Passing the previous ID renews that assertion rather than adding another.
        var id = assertionID
        let result = IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &id)
        if result == kIOReturnSuccess {
            assertionID = id
            failure = nil
        } else {
            failure = String(format: "declaring the user active failed (IOReturn 0x%08x)", UInt32(bitPattern: result))
        }
    }
}
