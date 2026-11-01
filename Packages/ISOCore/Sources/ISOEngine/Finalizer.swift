import Darwin
import Foundation
import ISOCore

/// Remuxes closed segments to standard MOVs, one at a time and at low priority so that disk and CPU
/// stay with recording. The working file is only deleted once the result has been verified.
public final class Finalizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "finalizer", qos: .utility)
    private let group = DispatchGroup()
    private let environment: FFmpegEnvironment

    public init(environment: FFmpegEnvironment) {
        self.environment = environment
    }

    func enqueue(store: SessionStore, inputID: String, number: Int) {
        group.enter()
        queue.async { [self] in
            defer { group.leave() }
            finalize(store: store, inputID: inputID, number: number)
        }
    }

    public func notify(queue: DispatchQueue, execute: @escaping @Sendable () -> Void) {
        group.notify(queue: queue, execute: execute)
    }

    public func wait() {
        group.wait()
    }

    private func finalize(store: SessionStore, inputID: String, number: Int) {
        let manifest = store.snapshot
        guard let segment = manifest.inputs.first(where: { $0.id == inputID })?.segments.first(where: { $0.number == number }) else { return }
        let working = store.layout.absolutePath(segment.workingFile)
        let final = store.layout.absolutePath(segment.finalFile)

        var state = SessionManifest.SegmentState.finalizeFailed
        var frames = segment.frames
        defer { store.updateSegment(inputID: inputID, number: number) { $0.state = state; $0.frames = frames } }

        guard let expected = try? MediaProbe.videoFrameCount(working, environment: environment), expected > 0 else { return }
        frames = expected
        guard hasRoom(forCopyOf: working, near: final) else { return }

        let arguments = FFmpegCommand.finalizeArguments(input: working, output: final, startTimecode: segment.startTimecode)
        guard let result = try? ProcessRunner.run(environment.ffmpegPath, arguments), result.status == 0,
              let actual = try? MediaProbe.videoFrameCount(final, environment: environment), actual == expected
        else {
            unlink(final)
            return
        }
        unlink(working)
        state = .finalized
    }

    private func hasRoom(forCopyOf path: String, near destination: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        let directory = (destination as NSString).deletingLastPathComponent
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory)
        let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return free > info.st_size + 1_073_741_824
    }
}

/// Completes segments left unfinished by a crash. A session folder is enough on its own.
public enum SessionRecovery {
    public struct Report: Hashable, Sendable {
        public var recovered: Int
        public var failed: Int
    }

    /// Session folders under `root` with segments that were never finalized.
    public static func incompleteSessions(root: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.compactMap { name in
            let directory = (root as NSString).appendingPathComponent(name)
            guard let manifest = load(directory: directory) else { return nil }
            let unfinished = manifest.inputs.flatMap(\.segments).contains { $0.state != .finalized }
            return unfinished ? directory : nil
        }
    }

    public static func load(directory: String) -> SessionManifest? {
        let path = (directory as NSString).appendingPathComponent("session.json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? SessionManifest.decoder().decode(SessionManifest.self, from: data)
    }

    public static func recover(directory: String, environment: FFmpegEnvironment) throws -> Report {
        guard let manifest = load(directory: directory) else { throw CocoaError(.fileReadCorruptFile) }
        let layout = SessionLayout(
            rootPath: (directory as NSString).deletingLastPathComponent,
            sessionName: (directory as NSString).lastPathComponent
        )
        let store = try SessionStore(layout: layout, manifest: manifest)
        let finalizer = Finalizer(environment: environment)

        for input in manifest.inputs {
            for segment in input.segments where segment.state != .finalized {
                store.updateSegment(inputID: input.id, number: segment.number) { record in
                    if record.endReason == nil { record.endReason = .appInterrupted }
                    let indexPath = layout.absolutePath(record.indexFile)
                    if let data = FileManager.default.contents(atPath: indexPath) {
                        record.repeatedFrames = FrameIndexFile.decodeRecords(data).filter { $0.flags.contains(.repeated) }.count
                    }
                }
                finalizer.enqueue(store: store, inputID: input.id, number: segment.number)
            }
        }
        finalizer.wait()

        let segments = store.snapshot.inputs.flatMap(\.segments)
        return Report(
            recovered: segments.filter { $0.state == .finalized }.count,
            failed: segments.filter { $0.state != .finalized }.count
        )
    }
}
