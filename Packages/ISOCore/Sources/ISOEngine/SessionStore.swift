import Foundation
import ISOCore

/// Owns `session.json`. Every update is written atomically, so the file on disk is always complete
/// and a crash leaves an accurate record of which segments need recovery.
public final class SessionStore: @unchecked Sendable {
    public let layout: SessionLayout
    private let lock = NSLock()
    private var manifest: SessionManifest

    public init(layout: SessionLayout, manifest: SessionManifest) throws {
        self.layout = layout
        self.manifest = manifest
        try FileManager.default.createDirectory(atPath: layout.sessionDirectory, withIntermediateDirectories: true)
        update { _ in }
    }

    public var snapshot: SessionManifest {
        lock.lock()
        defer { lock.unlock() }
        return manifest
    }

    public func update(_ change: (inout SessionManifest) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&manifest)
        guard let data = try? SessionManifest.encoder().encode(manifest) else { return }
        try? data.write(to: URL(fileURLWithPath: layout.sessionFilePath), options: .atomic)
    }

    func updateSegment(inputID: String, number: Int, _ change: (inout SessionManifest.SegmentRecord) -> Void) {
        update { manifest in
            guard let input = manifest.inputs.firstIndex(where: { $0.id == inputID }),
                  let segment = manifest.inputs[input].segments.firstIndex(where: { $0.number == number })
            else { return }
            change(&manifest.inputs[input].segments[segment])
        }
    }
}
