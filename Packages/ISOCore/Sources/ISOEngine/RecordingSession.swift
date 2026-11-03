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
    private let storagePolicy: StoragePolicy
    private var storageTimer: DispatchSourceTimer?
    private let healthLock = UnfairLock()
    private var storageLevel = StoragePolicy.Level.ok
    private var writeBytesPerSecond = 0.0
    private var writeRate = WriteRateMeter()
    private var healthLog: HealthLog?
    private var healthTicks = 0
    private let healthIntervalTicks: Int

    /// Called once if recording stops itself because the drive is nearly full.
    public var onStoppedForDiskSpace: (() -> Void)?

    public init(rootPath: String, name: String? = nil, environment: FFmpegEnvironment, storagePolicy: StoragePolicy = StoragePolicy(), healthIntervalSeconds: Double = 5) throws {
        let now = Date()
        layout = SessionLayout(rootPath: rootPath, sessionName: name ?? SessionLayout.defaultSessionName(date: now))
        store = try SessionStore(layout: layout, manifest: SessionManifest(
            name: layout.sessionName,
            createdAt: now,
            createdAtHostNanos: DispatchTime.now().uptimeNanoseconds
        ))
        self.environment = environment
        self.storagePolicy = storagePolicy
        healthIntervalTicks = max(1, Int(healthIntervalSeconds * 2))
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
            label: SessionLayout.uniqueLabel(label, taken: recorders.map(\.label)),
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
        healthLog = HealthLog(sessionDirectory: layout.sessionDirectory)
        startStorageGuard()
    }

    public func stopAll() {
        storageTimer?.cancel()
        storageTimer = nil
        recorders.forEach { $0.stopRecording() }
    }

    public var health: (level: StoragePolicy.Level, writeBytesPerSecond: Double, freeBytes: Int64) {
        let free = SystemMetrics.freeBytes(at: layout.sessionDirectory)
        return healthLock.withLock { (storageLevel, writeBytesPerSecond, free) }
    }

    private func startStorageGuard() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.checkStorage() }
        timer.resume()
        storageTimer = timer
    }

    /// Stops with room to spare. A drive that fills completely fails every input at once, mid-fragment.
    private func checkStorage() {
        let written = recorders.map { $0.status().bytesWritten }.reduce(0, +)
        writeRate.add(seconds: Double(DispatchTime.now().uptimeNanoseconds) / 1e9, bytes: written)
        let rate = writeRate.bytesPerSecond
        let free = SystemMetrics.freeBytes(at: layout.sessionDirectory)
        let level = storagePolicy.evaluate(freeBytes: free, writeBytesPerSecond: rate)
        healthLock.withLock {
            storageLevel = level
            writeBytesPerSecond = rate
        }
        healthTicks += 1
        if healthTicks % healthIntervalTicks == 0 {
            healthLog?.record(recorders: recorders, freeBytes: free, writeBytesPerSecond: rate)
        }
        guard level == .critical else { return }

        storageTimer?.cancel()
        storageTimer = nil
        store.update { manifest in
            let event = SessionManifest.Event(hostNanos: DispatchTime.now().uptimeNanoseconds, kind: "stopped_for_disk_space")
            for index in manifest.inputs.indices { manifest.inputs[index].events.append(event) }
        }
        recorders.forEach { $0.stopRecording(reason: .diskFull) }
        onStoppedForDiskSpace?()
    }

    public func addMarker(label: String) {
        let marker = SessionManifest.Marker(hostNanos: DispatchTime.now().uptimeNanoseconds, label: label)
        store.update { $0.markers.append(marker) }
    }

    /// Blocks until every segment is closed and finalized, then writes the NLE exports.
    public func waitUntilFinished() {
        recorders.forEach { $0.waitForSegments() }
        finalizer.wait()
        _ = try? SessionExport.write(directory: layout.sessionDirectory)
    }
}
