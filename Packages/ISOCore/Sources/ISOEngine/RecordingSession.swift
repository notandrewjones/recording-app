import Darwin
import Foundation
import ISOCore

/// A set of inputs recording into one session folder, sharing a timeline and a manifest.
public final class RecordingSession: @unchecked Sendable {
    public let layout: SessionLayout
    public let store: SessionStore
    private let finalizer: Finalizer
    private let environment: FFmpegEnvironment
    private let socketDirectory: String
    private var recorders: [InputRecorder] = []

    public init(rootPath: String, name: String? = nil, environment: FFmpegEnvironment) throws {
        let now = Date()
        layout = SessionLayout(rootPath: rootPath, sessionName: name ?? SessionLayout.defaultSessionName(date: now))
        store = try SessionStore(layout: layout, manifest: SessionManifest(
            name: layout.sessionName,
            createdAt: now,
            createdAtHostNanos: DispatchTime.now().uptimeNanoseconds
        ))
        self.environment = environment
        finalizer = Finalizer(environment: environment)

        // Sockets live under /tmp because a path inside the session could exceed the 104-byte limit.
        var template = Array("/tmp/isorec.XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw CocoaError(.fileWriteUnknown) }
        socketDirectory = String(cString: template)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: socketDirectory)
    }

    public func addInput(id: String, label: String, settings: InputRecorderSettings = InputRecorderSettings()) -> InputRecorder {
        let recorder = InputRecorder(
            id: id,
            label: label,
            settings: settings,
            store: store,
            finalizer: finalizer,
            environment: environment,
            socketDirectory: socketDirectory,
            socketPrefix: "i\(recorders.count)"
        )
        recorders.append(recorder)
        return recorder
    }

    public func startAll() {
        recorders.forEach { $0.startRecording() }
    }

    public func stopAll() {
        recorders.forEach { $0.stopRecording() }
    }

    public func addMarker(label: String) {
        let marker = SessionManifest.Marker(hostNanos: DispatchTime.now().uptimeNanoseconds, label: label)
        store.update { $0.markers.append(marker) }
    }

    /// Blocks until every segment is closed and finalized.
    public func waitUntilFinished() {
        recorders.forEach { $0.waitForSegments() }
        finalizer.wait()
    }
}
