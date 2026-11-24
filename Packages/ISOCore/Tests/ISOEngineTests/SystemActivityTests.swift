import Foundation
import ISOCore
import Testing
@testable import ISOEngine

/// Checks the assertions macOS actually holds, as `pmset` reports them.
@Suite(.serialized) struct SystemActivityTests {
    /// This process's assertions named `reason`, by type, such as "UserIsActive".
    func assertions(named reason: String) throws -> Set<String> {
        let result = try ProcessRunner.run("/usr/bin/pmset", ["-g", "assertions"])
        let pid = "pid \(ProcessInfo.processInfo.processIdentifier)("
        return Set(result.output.split(separator: "\n").compactMap { line -> String? in
            guard line.contains(pid), line.contains("named: \"\(reason)\"") else { return nil }
            let words = line.split(separator: " ")
            return words.firstIndex(of: "named:").map { String(words[$0 - 1]) }
        })
    }

    @Test func recordingKeepsTheMacAwakeAndTheUserActive() throws {
        let reason = "isorec test recording \(UUID().uuidString.prefix(8))"
        let activity = SystemActivity.recording(reason: reason)
        #expect(activity.userActivityFailure == nil)
        #expect(try assertions(named: reason) == ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "UserIsActive"])
        activity.end()
        #expect(try assertions(named: reason).isEmpty)
        activity.end()
    }

    /// Finishing only needs the process kept awake, not the display or the user.
    @Test func finishingOnlyStopsIdleSleep() throws {
        let reason = "isorec test finishing \(UUID().uuidString.prefix(8))"
        let activity = SystemActivity.finishing(reason: reason)
        #expect(try assertions(named: reason) == ["PreventUserIdleSystemSleep"])
        activity.end()
        #expect(try assertions(named: reason).isEmpty)
    }

    @Test func userActivityIsRenewedNotPiledUp() throws {
        let reason = "isorec test renewal \(UUID().uuidString.prefix(8))"
        let activity = SystemActivity(reason: reason, options: [.userInitiated], declaresUserActivity: true, refreshSeconds: 0.2)
        Thread.sleep(forTimeInterval: 0.7)
        let result = try ProcessRunner.run("/usr/bin/pmset", ["-g", "assertions"])
        let held = result.output.split(separator: "\n").filter { $0.contains("UserIsActive named: \"\(reason)\"") }
        #expect(held.count == 1, "\(held)")
        activity.end()
        #expect(try assertions(named: reason).isEmpty)
    }

    @Test func droppingItReleasesEverything() throws {
        let reason = "isorec test dropped \(UUID().uuidString.prefix(8))"
        var activity: SystemActivity? = SystemActivity.recording(reason: reason)
        #expect(try !assertions(named: reason).isEmpty)
        activity = nil
        #expect(try assertions(named: reason).isEmpty)
        _ = activity
    }
}
