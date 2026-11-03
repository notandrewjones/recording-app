import Foundation

/// On-disk layout of one recording session:
/// `<root>/<session>/<input>/<input>_0001.mov` plus matching `.idx` and `.log` files, and `<root>/<session>/session.json`.
/// While recording, the media is the fragmented `<input>_0001.part.mov`.
public struct SessionLayout: Hashable, Sendable {
    public var rootPath: String
    public var sessionName: String

    public init(rootPath: String, sessionName: String) {
        self.rootPath = rootPath
        self.sessionName = Self.sanitize(sessionName)
    }

    public var sessionDirectory: String { (rootPath as NSString).appendingPathComponent(sessionName) }
    public var sessionFilePath: String { (sessionDirectory as NSString).appendingPathComponent("session.json") }

    public func inputDirectory(inputLabel: String) -> String {
        (sessionDirectory as NSString).appendingPathComponent(Self.sanitize(inputLabel))
    }

    public func segmentPath(inputLabel: String, segment: Int) -> String {
        (inputDirectory(inputLabel: inputLabel) as NSString).appendingPathComponent("\(segmentStem(inputLabel, segment)).mov")
    }

    public func workingSegmentPath(inputLabel: String, segment: Int) -> String {
        (inputDirectory(inputLabel: inputLabel) as NSString).appendingPathComponent("\(segmentStem(inputLabel, segment)).part.mov")
    }

    public func logPath(inputLabel: String, segment: Int) -> String {
        (inputDirectory(inputLabel: inputLabel) as NSString).appendingPathComponent("\(segmentStem(inputLabel, segment)).log")
    }

    /// A path relative to the session directory, so a session folder can be moved between drives.
    public func relativePath(_ path: String) -> String {
        let prefix = sessionDirectory + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    public func absolutePath(_ relative: String) -> String {
        (sessionDirectory as NSString).appendingPathComponent(relative)
    }

    public func frameIndexPath(inputLabel: String, segment: Int) -> String {
        (inputDirectory(inputLabel: inputLabel) as NSString).appendingPathComponent("\(segmentStem(inputLabel, segment)).idx")
    }

    private func segmentStem(_ inputLabel: String, _ segment: Int) -> String {
        "\(Self.sanitize(inputLabel))_\(String(format: "%04d", segment))"
    }

    /// Keeps labels safe for files, NLE media pools and shell-free argument passing.
    public static func sanitize(_ label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = label.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return cleaned.isEmpty ? "untitled" : cleaned
    }

    /// `label`, or `label 2`, `label 3`… if its folder would collide with one in `taken`. Two inputs given the
    /// same name would otherwise write into one folder. Compared without case, as the default APFS volume is.
    public static func uniqueLabel(_ label: String, taken: [String]) -> String {
        let used = Set(taken.map { sanitize($0).lowercased() })
        guard used.contains(sanitize(label).lowercased()) else { return label }
        var number = 2
        while used.contains(sanitize("\(label) \(number)").lowercased()) { number += 1 }
        return "\(label) \(number)"
    }

    public static func defaultSessionName(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }
}
