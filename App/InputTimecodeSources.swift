import Foundation
import ISOCore

/// Each input's timecode setting by input ID, saved between launches, including for inputs that are not
/// connected. Inputs without one record their source timecode, which was the only behaviour before.
struct InputTimecodeSources {
    private static let key = "inputTimecodeSources"
    private var sources: [String: String]

    init() {
        sources = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func source(for inputID: String) -> TimecodeSource {
        sources[inputID].flatMap(TimecodeSource.init(rawValue:)) ?? .source
    }

    mutating func set(_ source: TimecodeSource, for inputID: String) {
        sources[inputID] = source == .source ? nil : source.rawValue
        UserDefaults.standard.set(sources, forKey: Self.key)
    }
}
