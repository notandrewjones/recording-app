import Foundation
import Security

/// How the control API is reached, for Companion, Stream Deck or curl. Kept in UserDefaults, so it can also
/// be set with `defaults write`. The token is not a Keychain secret: anything already on this Mac can use the
/// API without one, and it only guards against other computers.
struct ControlSettings: Equatable {
    static let defaultPort = 9455

    /// 0 turns the API off.
    var port: Int
    /// Also listen on the network, for a Companion on another computer, which must then send `token`.
    var allowsLAN: Bool
    var token: String

    var isEnabled: Bool { port > 0 && port <= Int(UInt16.max) }

    static func load() -> ControlSettings {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["controlPort": defaultPort])
        var settings = ControlSettings(
            port: defaults.integer(forKey: "controlPort"),
            allowsLAN: defaults.bool(forKey: "controlAllowLAN"),
            token: defaults.string(forKey: "controlToken") ?? ""
        )
        if settings.allowsLAN, settings.token.isEmpty {
            settings.token = newToken()
            settings.save()
        }
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(port, forKey: "controlPort")
        defaults.set(allowsLAN, forKey: "controlAllowLAN")
        defaults.set(token, forKey: "controlToken")
    }

    /// 24 random bytes as base64url: 32 characters that survive copying into any text field.
    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<bytes.count).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}
