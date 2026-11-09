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
        var lost = segment.lostFrames
        var failure: String?
        var salvage: String?
        defer {
            if let salvage { unlink(salvage) }
            store.updateSegment(inputID: inputID, number: number) {
                $0.state = state
                $0.frames = frames
                $0.lostFrames = lost
                $0.finalizeError = failure
            }
        }

        var source = working
        let expected: Int
        do {
            expected = try MediaProbe.videoFrameCount(working, environment: environment)
        } catch {
            // A cut inside a fragment header hides the whole file from ffprobe. A copy cut back to the last
            // complete fragment reads, and loses only that unfinished fragment.
            guard let copy = salvageCopy(of: working) else {
                failure = "could not read the recording (\(error))"
                return
            }
            salvage = copy
            guard let count = try? MediaProbe.videoFrameCount(copy, environment: environment) else {
                failure = "could not read the recording, even cut back to its last complete fragment (\(error))"
                return
            }
            source = copy
            expected = count
        }
        guard expected > 0 else {
            failure = "the recording has no video frames"
            return
        }
        frames = expected
        lost = trimIndex(store.layout.absolutePath(segment.indexFile), toFrames: expected)
        guard hasRoom(forCopyOf: source, near: final) else {
            failure = "not enough free space to finalize"
            return
        }

        let arguments = FFmpegCommand.finalizeArguments(input: source, output: final, startTimecode: segment.startTimecode)
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(environment.ffmpegPath, arguments)
        } catch {
            failure = "could not run ffmpeg (\(error))"
            return
        }
        guard result.status == 0 else {
            unlink(final)
            let message = result.errorOutput.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            failure = "remux failed with exit \(result.status): \(message)"
            return
        }
        let actual = (try? MediaProbe.videoFrameCount(final, environment: environment)) ?? 0
        guard actual == expected else {
            unlink(final)
            failure = "remux kept \(actual) of \(expected) frames"
            return
        }
        unlink(working)
        state = .finalized
    }

    /// A hidden copy of `path` cut back to its last complete fragment, or nil if cutting would not help.
    /// APFS clones it for free; other volumes get a real copy, since the original is never modified.
    private func salvageCopy(of path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0,
              let length = FragmentedMovie.readableLength(path: path), length > 0, length < Int64(info.st_size)
        else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        let copy = (directory as NSString).appendingPathComponent(".\((path as NSString).lastPathComponent).salvage.mov")
        unlink(copy)
        if clonefile(path, copy, 0) != 0 {
            guard (try? FileManager.default.copyItem(atPath: path, toPath: copy)) != nil else { return nil }
        }
        guard truncate(copy, off_t(length)) == 0 else {
            unlink(copy)
            return nil
        }
        return copy
    }

    /// After a crash the index runs ahead of the media by whatever ffmpeg never flushed. Trimming it
    /// keeps file frame N equal to record N. Returns how many records were removed.
    private func trimIndex(_ path: String, toFrames frames: Int) -> Int {
        var info = stat()
        guard stat(path, &info) == 0 else { return 0 }
        let records = (Int(info.st_size) - FrameIndexFile.headerSize) / FrameIndexFile.recordSize
        guard records > frames else { return 0 }
        truncate(path, off_t(FrameIndexFile.headerSize + frames * FrameIndexFile.recordSize))
        return records - frames
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
        _ = try? SessionExport.write(directory: directory)

        let segments = store.snapshot.inputs.flatMap(\.segments)
        return Report(
            recovered: segments.filter { $0.state == .finalized }.count,
            failed: segments.filter { $0.state != .finalized }.count
        )
    }
}
