import Foundation
import ISOCore

/// Operator names for inputs by input ID, so "DeckLink Duo (1)" can read "Wide". Saved between launches,
/// including for inputs that are not connected. Names are stored as typed and trimmed when used,
/// so a text field bound to them keeps its trailing space while the operator is typing.
struct InputNames {
    private static let key = "inputNames"
    private var names: [String: String]

    init() {
        names = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// The custom name if there is one, otherwise the hardware name.
    func name(for input: CaptureInput) -> String {
        let custom = customName(for: input.id).trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? input.displayName : custom
    }

    func customName(for inputID: String) -> String {
        names[inputID] ?? ""
    }

    /// An empty name returns the input to its hardware name.
    mutating func set(_ name: String, for inputID: String) {
        names[inputID] = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        UserDefaults.standard.set(names, forKey: Self.key)
    }
}
