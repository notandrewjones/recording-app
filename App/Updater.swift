import Combine
import Foundation
import Sparkle

/// Sparkle in-app updates. The feed is set by `SUFeedURL` in App/Info.plist and every update must be signed
/// with the key whose public half is `SUPublicEDKey`. See docs/release.md.
///
/// An update never interrupts a recording: if the operator accepts one while segments are open, the
/// relaunch waits until recording stops and every segment is finalized.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false

    /// Set by the app once the model exists.
    var hasOpenSegments: () -> Bool = { false }

    private var controller: SPUStandardUpdaterController!
    private var pendingRelaunch: (() -> Void)?
    private var pollTimer: Timer?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        // A build without a public key (a local Debug build before keys are set up) cannot verify updates.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty else { return }
        controller.startUpdater()
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard hasOpenSegments() else { return false }
            pendingRelaunch = installHandler
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.relaunchIfIdle() }
            }
            return true
        }
    }

    private func relaunchIfIdle() {
        guard !hasOpenSegments(), let relaunch = pendingRelaunch else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        pendingRelaunch = nil
        relaunch()
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Scheduled checks surface quietly instead of putting a window over the multiview mid-show.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
