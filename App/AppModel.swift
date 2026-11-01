import Foundation
import ISOCore
import ISOEngine

/// One tile in the multiview.
final class InputTile: ObservableObject, Identifiable {
    let source: CaptureSource
    var id: String { source.input.id }
    @Published var status = PreviewFrameStore.Status()
    @Published var measuredFPS = 0.0
    @Published var errorMessage: String?
    @Published var isArmed = true
    @Published var recorderStatus: InputRecorderStatus?

    var recorder: InputRecorder?

    private var lastFrames: UInt64 = 0
    private var lastSample = Date()

    init(source: CaptureSource) {
        self.source = source
    }

    func refresh() {
        let snapshot = source.store.snapshot()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSample)
        if elapsed >= 1 {
            measuredFPS = Double(snapshot.framesReceived &- lastFrames) / elapsed
            lastFrames = snapshot.framesReceived
            lastSample = now
        }
        status = snapshot
        recorderStatus = recorder?.status()
    }

    var isRecording: Bool {
        switch recorderStatus?.state {
        case .recording, .starting, .waitingForSignal, .backingOff: true
        default: false
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tiles: [InputTile] = []
    @Published private(set) var driverStatus = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var message: String?

    private var session: RecordingSession?
    /// Recorders in this session by input ID, kept so that a device that returns finds its recorder again.
    private var recorders: [String: InputRecorder] = [:]
    private let environment: FFmpegEnvironment?
    private let discovery = DLDiscovery()
    private var refreshTimer: Timer?
    private var syntheticCount = 0

    init() {
        do {
            environment = try FFmpegEnvironment.locate(preferredPath: UserDefaults.standard.string(forKey: "ffmpegPath"))
        } catch {
            environment = nil
            message = "\(error)"
        }
        startDiscovery()
        let launchCount = UserDefaults.standard.integer(forKey: "synthetic")
        for _ in 0..<launchCount { addSyntheticInput() }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tiles.forEach { $0.refresh() }
            }
        }
        recoverInterruptedSessions()
        scheduleAutoRecord()
    }

    /// `-autoRecordSeconds N` records for N seconds after launch, for unattended smoke tests.
    private func scheduleAutoRecord() {
        let seconds = UserDefaults.standard.double(forKey: "autoRecordSeconds")
        guard seconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.recordAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.stopAll()
            }
        }
    }

    /// Folder for recordings. The default can be overridden with the `recordingRoot` default.
    var recordingRoot: String {
        UserDefaults.standard.string(forKey: "recordingRoot")
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Movies/ISO Recorder")
    }

    func toggleRecordAll() {
        isRecording ? stopAll() : recordAll()
    }

    func recordAll() {
        guard !isRecording, let environment else { return }
        let armed = tiles.filter(\.isArmed)
        guard !armed.isEmpty else {
            message = "No armed inputs."
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: recordingRoot, withIntermediateDirectories: true)
            let session = try RecordingSession(rootPath: recordingRoot, environment: environment)
            armed.forEach { attach($0, to: session) }
            session.startAll()
            self.session = session
            isRecording = true
            message = nil
        } catch {
            message = "Could not start the session: \(error.localizedDescription)"
        }
    }

    func stopAll() {
        guard let session else { return }
        session.stopAll()
        self.session = nil
        recorders = [:]
        isRecording = false
        isFinalizing = true
        let tiles = tiles
        DispatchQueue.global(qos: .utility).async {
            session.waitUntilFinished()
            Task { @MainActor [weak self] in
                tiles.forEach {
                    $0.source.sink.attach(nil)
                    $0.recorder = nil
                }
                self?.isFinalizing = false
                self?.message = "Saved to \(session.layout.sessionDirectory)"
            }
        }
    }

    func addMarker() {
        session?.addMarker(label: "Marker")
    }

    private func attach(_ tile: InputTile, to session: RecordingSession) {
        let audio = AudioFormat(channels: tile.source.audioChannels)
        let recorder = session.addInput(
            id: tile.id,
            label: tile.source.input.displayName,
            settings: InputRecorderSettings(audio: audio)
        )
        recorders[tile.id] = recorder
        tile.recorder = recorder
        tile.source.sink.attach(recorder)
    }

    /// An input that arrives mid-session joins it: a returning device resumes, and a new one starts.
    private func joinSession(_ tile: InputTile) {
        guard let session, tile.isArmed else { return }
        if let recorder = recorders[tile.id] {
            tile.recorder = recorder
            tile.source.sink.attach(recorder)
        } else {
            attach(tile, to: session)
            tile.recorder?.startRecording()
        }
    }

    /// Finishes segments left open by a crash, so nothing waits on the operator to rescue footage.
    private func recoverInterruptedSessions() {
        guard let environment else { return }
        let root = recordingRoot
        DispatchQueue.global(qos: .utility).async {
            let incomplete = SessionRecovery.incompleteSessions(root: root)
            guard !incomplete.isEmpty else { return }
            let reports = incomplete.compactMap { try? SessionRecovery.recover(directory: $0, environment: environment) }
            let recovered = reports.map(\.recovered).reduce(0, +)
            Task { @MainActor [weak self] in
                self?.message = "Recovered \(recovered) segments from an interrupted session."
            }
        }
    }

    func addSyntheticInput() {
        syntheticCount += 1
        add(SyntheticCaptureSource(index: syntheticCount))
    }

    func removeLastSyntheticInput() {
        guard let tile = tiles.last(where: { $0.source.input.isSynthetic }) else { return }
        remove(id: tile.id)
    }

    private func startDiscovery() {
        guard let driver = DLDiscovery.driverVersion else {
            driverStatus = "Desktop Video not found (SDK \(DLDiscovery.sdkVersion))"
            return
        }
        driverStatus = "Desktop Video \(driver), SDK \(DLDiscovery.sdkVersion)"

        let started = discovery.start(
            arrived: { [weak self] device in
                Task { @MainActor in self?.add(DeckLinkCaptureSource(device: device)) }
            },
            removed: { [weak self] device in
                let id = device.identifier
                Task { @MainActor in self?.remove(id: id) }
            }
        )
        if !started {
            driverStatus = "Could not start device discovery. Desktop Video \(driver) may be older than SDK \(DLDiscovery.sdkVersion)."
        }
    }

    private func add(_ source: CaptureSource) {
        guard !tiles.contains(where: { $0.id == source.input.id }) else { return }
        let tile = InputTile(source: source)
        tiles.append(tile)
        joinSession(tile)
        do {
            try source.start()
        } catch {
            tile.errorMessage = error.localizedDescription
        }
    }

    private func remove(id: String) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        let tile = tiles[index]
        if tile.isRecording {
            // The file stays open for a return. Recording resumes in a new segment if the input comes back.
            tile.recorder?.inputLost()
        }
        tile.source.sink.attach(nil)
        tile.source.stop()
        tiles.remove(at: index)
    }
}
