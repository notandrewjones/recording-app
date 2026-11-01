import Foundation
import ISOCore

public enum SessionExport {
    /// Writes NLE files into `<session>/export` and returns their paths. Safe to run again.
    @discardableResult
    public static func write(directory: String) throws -> [String] {
        guard let manifest = SessionRecovery.load(directory: directory) else { throw CocoaError(.fileReadCorruptFile) }
        guard let plan = MulticamPlan(manifest: manifest, sessionDirectory: directory) else { return [] }
        let output = (directory as NSString).appendingPathComponent("export")
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        return try MulticamExporter.files(for: plan).map { file in
            let path = (output as NSString).appendingPathComponent(file.name)
            try file.contents.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }
    }
}
