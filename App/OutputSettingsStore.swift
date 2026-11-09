import Foundation
import ISOCore

/// Output settings for each input, saved between launches. Changes apply to the next recording.
@MainActor
final class OutputSettingsStore: ObservableObject {
    private struct Saved: Codable {
        var defaults: OutputSettings
        var overrides: [String: OutputSettings]
    }

    private static let key = "outputSettings"

    @Published var defaults: OutputSettings { didSet { save() } }
    @Published private(set) var overrides: [String: OutputSettings] { didSet { save() } }
    /// Called after any change, once the new value is in place.
    var onChange: (() -> Void)?

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        defaults = saved?.defaults ?? OutputSettings()
        overrides = saved?.overrides ?? [:]
    }

    func settings(for inputID: String) -> OutputSettings {
        overrides[inputID] ?? defaults
    }

    func hasOverride(_ inputID: String) -> Bool {
        overrides[inputID] != nil
    }

    func setOverride(_ settings: OutputSettings?, for inputID: String) {
        overrides[inputID] = settings
    }

    private func save() {
        onChange?()
        guard let data = try? JSONEncoder().encode(Saved(defaults: defaults, overrides: overrides)) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
