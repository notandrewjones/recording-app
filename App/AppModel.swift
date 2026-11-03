import Foundation
import ISOCore
import ISOEngine

/// A marker as the operator sees it confirmed: its number in the session and when it was added.
struct MarkerNote: Equatable, Identifiable {
    let id = UUID()
    let number: Int
    let label: String
    let elapsed: TimeInterval
}

/// A reason recording isn't running, and the settings tab that fixes it, if any.
struct RecordingFailure: Equatable {
    let text: String
    var settingsTab: SettingsTab?
}

/// One tile in the multiview.
final class InputTile: ObservableObject, Identifiable {
    let source: CaptureSource
    var id: String { source.input.id }
    /// The operator's name for the input, or the hardware name. Recordings are named after it.
    @Published var name: String
    @Published var status = PreviewFrameStore.Status()
    @Published var measuredFPS = 0.0
    @Published var errorMessage: String?
    @Published var isArmed = true
    @Published var recorderStatus: InputRecorderStatus?
    /// Where this input's recorded timecode comes from. Applies from its next segment.
    @Published var timecodeSource: TimecodeSource
    /// What the footer shows: the clock that will be stamped for time of day, otherwise the signal's own.
    @Published var displayTimecode: Timecode?

    var recorder: InputRecorder?

    private var lastFrames: UInt64 = 0
    private var lastSample = Date()

    init(source: CaptureSource, name: String, timecodeSource: TimecodeSource) {
        self.source = source
        self.name = name
        self.timecodeSource = timecodeSource
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
        if timecodeSource == .timeOfDay, let format = snapshot.signal.format {
            displayTimecode = Timecode.timeOfDay(date: now, frameRate: format.frameRate)
        } else {
            displayTimecode = snapshot.timecode
        }
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
    /// Whether `driverStatus` describes a problem rather than the installed version.
    @Published private(set) var isDriverProblem = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var message: String?
    @Published private(set) var systemSample: SystemMetrics.Sample?
    @Published private(set) var freeBytes: Int64 = 0
    @Published private(set) var writeBytesPerSecond = 0.0
    @Published private(set) var storageLevel = StoragePolicy.Level.ok
    @Published private(set) var estimatedBytesPerHour = 0.0
    @Published private(set) var capacityWarnings: [String] = []
    /// Folder for recordings. Set in Settings, or with the `recordingRoot` default.
    @Published private(set) var recordingRoot = AppModel.savedRecordingRoot ?? AppModel.defaultRecordingRoot
    /// Why recording to `recordingRoot` would fail, such as its drive being disconnected.
    @Published private(set) var recordingRootProblem: String?
    /// Port, network access and token for the control API. Changed in Settings.
    @Published private(set) var control = ControlSettings.load()
    /// Why the control API is not listening, such as its port being in use.
    @Published private(set) var controlProblem: String?
    /// When the current session started, for the session clock.
    @Published private(set) var sessionStartedAt: Date?
    /// The marker added most recently, so the operator can see it land.
    @Published private(set) var lastMarker: MarkerNote?
    /// Inputs recording now, and inputs that will record or are recording. Tiles change on their own
    /// timer, so these are copied here for views that observe only the model.
    @Published private(set) var recordingCount = 0
    @Published private(set) var armedCount = 0
    /// Why recording did not start or stopped by itself. Shown until the next start or until dismissed.
    @Published private(set) var recordingFailure: RecordingFailure?
    /// Goes up with every failed start, so the Record button can react to each one.
    @Published private(set) var failedStartCount = 0
    /// An input waiting for the operator to confirm stopping it mid-session.
    @Published var pendingPunchOut: InputTile?

    let outputSettings: OutputSettingsStore
    private var inputNames = InputNames()
    private var inputTimecodeSources = InputTimecodeSources()

    private var session: RecordingSession?
    /// Recorders in this session by input ID, kept so that a device that returns finds its recorder again.
    private var recorders: [String: InputRecorder] = [:]
    /// Inputs disarmed during this session, so one that disconnects and returns does not rejoin by itself.
    private var punchedOut: Set<String> = []
    private let environment: FFmpegEnvironment?
    private let discovery = DLDiscovery()
    private var refreshTimer: Timer?
    private var syntheticCount = 0
    private var controlServer: ControlServer?
    private var markerCount = 0
    /// Why FFmpeg could not be found at launch.
    private var environmentProblem: String?
    private var inputRebuildPending = false
    private let metrics = SystemMetrics()
    private var lastMetricsUptime: UInt64 = 0

    init() {
        outputSettings = OutputSettingsStore()
        do {
            environment = try FFmpegEnvironment.locate(preferredPath: UserDefaults.standard.string(forKey: "ffmpegPath"))
        } catch {
            environment = nil
            environmentProblem = "\(error)"
        }
        startDiscovery()
        let launchCount = UserDefaults.standard.integer(forKey: "synthetic")
        for _ in 0..<launchCount { addSyntheticInput() }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tiles.forEach { $0.refresh() }
                self?.refreshCounts()
                self?.refreshMetrics()
            }
        }
        recoverInterruptedSessions()
        scheduleAutoRecord()
        startControlServer()
    }

    /// Serves `/api/v1` on port 9455 unless `controlPort` says otherwise, and 0 turns it off. Only this Mac
    /// can connect, unless other computers are allowed, and then they need the access token.
    private func startControlServer() {
        controlServer?.stop()
        controlServer = nil
        controlProblem = nil
        let settings = control
        guard settings.isEnabled else { return }
        let server = ControlServer { [weak self] command in
            guard let self else { return ControlResponse(status: 503, error: "Shutting down.") }
            return await self.handle(command)
        }
        do {
            try server.start(port: UInt16(settings.port), lanToken: settings.allowsLAN ? settings.token : nil) { [weak self] result in
                if case .failure(let error) = result {
                    Task { @MainActor in self?.controlFailed("Port \(settings.port): \(error.localizedDescription)") }
                }
            }
            controlServer = server
        } catch {
            controlFailed(error.localizedDescription)
        }
    }

    private func controlFailed(_ reason: String) {
        controlProblem = "The control API isn't running. \(reason)"
        message = "Control API unavailable. \(reason)"
    }

    /// Applies a change from Settings and restarts the server if anything changed.
    func updateControl(_ change: (inout ControlSettings) -> Void) {
        var settings = control
        change(&settings)
        if settings.allowsLAN, settings.token.isEmpty { settings.token = ControlSettings.newToken() }
        guard settings != control else { return }
        control = settings
        settings.save()
        startControlServer()
    }

    /// Any Companion using the old token stops working until it is given the new one.
    func regenerateControlToken() {
        updateControl { $0.token = ControlSettings.newToken() }
    }

    private func handle(_ command: ControlCommand) -> ControlResponse {
        switch command {
        case .status:
            break
        case .startRecording:
            if !isRecording { recordAll() }
            if !isRecording { return ControlResponse(status: 409, error: recordingFailure?.text ?? "Could not start recording.") }
        case .stopRecording:
            stopAll()
        case .toggleRecording:
            if isRecording {
                stopAll()
            } else {
                recordAll()
                if !isRecording { return ControlResponse(status: 409, error: recordingFailure?.text ?? "Could not start recording.") }
            }
        case .addMarker(let label):
            guard session != nil else { return ControlResponse(status: 409, error: "Not recording.") }
            addMarker(label: label)
        case .setArmed(let inputID, let armed):
            guard let tile = tiles.first(where: { $0.id == inputID }) else {
                return ControlResponse(status: 404, error: "Unknown input.")
            }
            setArmed(tile, armed)
        case .toggleArmed(let inputID):
            guard let tile = tiles.first(where: { $0.id == inputID }) else {
                return ControlResponse(status: 404, error: "Unknown input.")
            }
            setArmed(tile, !tile.isArmed)
        }
        // Tiles otherwise refresh on a timer, and the reply should already show what the command changed.
        tiles.forEach { $0.refresh() }
        return ControlResponse(status: 200, body: statusJSON())
    }

    private func statusJSON() -> Data {
        let inputs: [[String: Any]] = tiles.enumerated().map { position, tile in
            var input: [String: Any] = [
                "id": tile.id,
                "index": position + 1,
                "label": tile.name,
                "device": tile.source.input.displayName,
                "armed": tile.isArmed,
                "recording": tile.isRecording,
                "signal": tile.status.signal.format != nil,
            ]
            if let format = tile.status.signal.format { input["format"] = format.displayName }
            if let recorder = tile.recorderStatus {
                input["frames"] = recorder.totalFrames
                input["repeatedFrames"] = recorder.repeatedFrames
                input["restarts"] = recorder.restarts
            }
            return input
        }
        var object: [String: Any] = [
            "apiVersion": 2,
            "recording": isRecording,
            "finalizing": isFinalizing,
            "freeBytes": freeBytes,
            "inputs": inputs,
        ]
        if let sessionStartedAt { object["recordingSeconds"] = Int(Date().timeIntervalSince(sessionStartedAt)) }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
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

    private func refreshMetrics() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastMetricsUptime >= 1_000_000_000 else { return }
        lastMetricsUptime = now
        systemSample = metrics.sample()

        let armed = tiles.filter(\.isArmed)
        estimatedBytesPerHour = armed.compactMap { tile -> Double? in
            let settings = outputSettings.settings(for: tile.id)
            let format = tile.status.signal.format ?? referenceFormat
            return StorageEstimate.bytesPerHour(format: format, codec: settings.codec, audio: AudioFormat(channels: audioChannels(tile, settings)))
        }.reduce(0, +)
        capacityWarnings = EncoderCapacity.warnings(for: armed.map {
            (outputSettings.settings(for: $0.id).codec, $0.status.signal.format ?? referenceFormat)
        })

        if let session {
            let health = session.health
            freeBytes = health.freeBytes
            writeBytesPerSecond = health.writeBytesPerSecond
            storageLevel = health.level
        } else {
            recordingRootProblem = Self.problem(with: recordingRoot, isCustom: Self.savedRecordingRoot != nil)
            // A missing drive's folder would otherwise report the free space of the disk above it.
            freeBytes = recordingRootProblem == nil ? SystemMetrics.freeBytes(at: Self.nearestExistingDirectory(recordingRoot)) : 0
            writeBytesPerSecond = 0
            storageLevel = .ok
        }
    }

    /// The format used for estimates when an input has no signal yet.
    var referenceFormat: VideoFormat {
        tiles.compactMap(\.status.signal.format).first ?? .hd1080p5994
    }

    /// The configured channel count, limited to what the input can provide.
    private func audioChannels(_ tile: InputTile, _ settings: OutputSettings) -> Int {
        min(settings.audioChannels, tile.source.audioChannels)
    }

    /// Time until recording stops for disk space, at the measured write rate, or the estimate for armed
    /// inputs until enough has been written to measure.
    var remainingSeconds: Double? {
        let rate = writeBytesPerSecond > 0 ? writeBytesPerSecond : estimatedBytesPerHour / 3600
        let usable = max(0, freeBytes - StoragePolicy().criticalFreeBytes)
        return rate > 0 ? Double(usable) / rate : nil
    }

    static let defaultRecordingRoot = (NSHomeDirectory() as NSString).appendingPathComponent("Movies/ISO Recorder")

    private static var savedRecordingRoot: String? {
        UserDefaults.standard.string(forKey: "recordingRoot")
    }

    var isUsingDefaultRecordingRoot: Bool {
        Self.savedRecordingRoot == nil
    }

    /// Changes where the next session is saved. `nil` returns to the default folder.
    func setRecordingRoot(_ path: String?) {
        guard !isRecording else { return }
        if let path {
            UserDefaults.standard.set(path, forKey: "recordingRoot")
        } else {
            UserDefaults.standard.removeObject(forKey: "recordingRoot")
        }
        recordingRoot = Self.savedRecordingRoot ?? Self.defaultRecordingRoot
        lastMetricsUptime = 0
        refreshMetrics()
        // A crash may have left sessions open in a folder used before.
        recoverInterruptedSessions()
    }

    /// The default folder is created when needed. A chosen one must exist, because a missing one usually
    /// means its drive is disconnected, and recreating the path would put the recording somewhere else.
    private static func problem(with root: String, isCustom: Bool) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else {
            return isCustom ? "The recording folder is missing. Connect its drive or choose another folder." : nil
        }
        guard isDirectory.boolValue else { return "The recording folder is a file, not a folder." }
        guard FileManager.default.isWritableFile(atPath: root) else { return "The recording folder can't be written to." }
        return nil
    }

    private static func nearestExistingDirectory(_ path: String) -> String {
        var current = path
        while !FileManager.default.fileExists(atPath: current), current != "/" {
            current = (current as NSString).deletingLastPathComponent
        }
        return current
    }

    func rename(_ tile: InputTile, to name: String) {
        objectWillChange.send()
        inputNames.set(name, for: tile.id)
        tile.name = inputNames.name(for: tile.source.input)
    }

    /// Locked while the input records, since a segment keeps the timecode it started with. A recorder kept
    /// from earlier in the session is updated too, so the change reaches the input's next punch-in.
    func setTimecodeSource(_ tile: InputTile, _ source: TimecodeSource) {
        guard !tile.isRecording, tile.timecodeSource != source else { return }
        inputTimecodeSources.set(source, for: tile.id)
        tile.timecodeSource = source
        recorders[tile.id]?.setTimecodeSource(source)
        tile.refresh()
    }

    func customName(for tile: InputTile) -> String {
        inputNames.customName(for: tile.id)
    }

    func toggleRecordAll() {
        isRecording ? stopAll() : recordAll()
    }

    func recordAll() {
        guard !isRecording else { return }
        guard let environment else {
            failStart("Can't record because FFmpeg wasn't found. \(environmentProblem ?? "")")
            return
        }
        let armed = tiles.filter(\.isArmed)
        guard !armed.isEmpty else {
            failStart(tiles.isEmpty ? "Can't record: no inputs are connected." : "Can't record: no inputs are armed. Arm at least one input, then press Record.")
            return
        }
        if let problem = Self.problem(with: recordingRoot, isCustom: !isUsingDefaultRecordingRoot) {
            recordingRootProblem = problem
            failStart("Can't record. \(problem) (\((recordingRoot as NSString).abbreviatingWithTildeInPath))", fixIn: .general)
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: recordingRoot, withIntermediateDirectories: true)
            let session = try RecordingSession(rootPath: recordingRoot, environment: environment)
            session.onStoppedForDiskSpace = { [weak self] in
                Task { @MainActor in
                    self?.stopAll()
                    self?.recordingFailure = RecordingFailure(
                        text: "Recording stopped because the drive is nearly full. Free some space or choose another folder.",
                        settingsTab: .general
                    )
                }
            }
            armed.forEach { attach($0, to: session) }
            session.startAll()
            self.session = session
            sessionStartedAt = Date()
            markerCount = 0
            lastMarker = nil
            isRecording = true
            message = nil
            recordingFailure = nil
        } catch {
            failStart("Couldn't start the session: \(error.localizedDescription)", fixIn: .general)
        }
    }

    private func failStart(_ text: String, fixIn tab: SettingsTab? = nil) {
        recordingFailure = RecordingFailure(text: text, settingsTab: tab)
        failedStartCount += 1
    }

    func dismissRecordingFailure() {
        recordingFailure = nil
    }

    /// Arms or disarms from a click or shortcut. Stopping an input mid-session waits for confirmation,
    /// because a stray click must not cut an angle.
    func requestToggleArmed(_ tile: InputTile) {
        if tile.isRecording { pendingPunchOut = tile } else { setArmed(tile, !tile.isArmed) }
    }

    func stopAll() {
        guard let session else { return }
        session.stopAll()
        self.session = nil
        recorders = [:]
        punchedOut = []
        sessionStartedAt = nil
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
                if self?.message == nil { self?.message = "Saved to \(session.layout.sessionDirectory)" }
            }
        }
    }

    /// Zips logs for the newest session and shows the result. Never includes media.
    func exportDiagnostics() {
        guard let latest = latestSessionDirectory() else {
            message = "No session to export."
            return
        }
        let environment = environment
        let settings = (try? JSONEncoder().encode(outputSettings.defaults)).map { String(decoding: $0, as: UTF8.self) }
        let destination = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        message = "Exporting diagnostics…"
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                try DiagnosticsBundle.write(sessionDirectory: latest, environment: environment, settings: settings, destinationDirectory: destination)
            }
            Task { @MainActor [weak self] in
                switch result {
                case .success(let path): self?.message = "Diagnostics saved to \(path)"
                case .failure(let error): self?.message = "Could not export diagnostics: \(error.localizedDescription)"
                }
            }
        }
    }

    private func latestSessionDirectory() -> String? {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: recordingRoot)) ?? []
        return names
            .map { (recordingRoot as NSString).appendingPathComponent($0) }
            .filter { SessionRecovery.load(directory: $0) != nil }
            .max { modificationDate($0) < modificationDate($1) }
    }

    private func modificationDate(_ path: String) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    func addMarker(label: String = "Marker") {
        guard let session, let sessionStartedAt else { return }
        session.addMarker(label: label)
        markerCount += 1
        lastMarker = MarkerNote(number: markerCount, label: label, elapsed: Date().timeIntervalSince(sessionStartedAt))
    }

    private func refreshCounts() {
        let recording = tiles.filter(\.isRecording).count
        let armed = tiles.filter(\.isArmed).count
        if recording != recordingCount { recordingCount = recording }
        if armed != armedCount { armedCount = armed }
    }

    private func attach(_ tile: InputTile, to session: RecordingSession) {
        let output = outputSettings.settings(for: tile.id)
        let recorder = session.addInput(
            id: tile.id,
            label: tile.name,
            settings: InputRecorderSettings(codec: output.codec, audio: AudioFormat(channels: audioChannels(tile, output)), timecodeSource: tile.timecodeSource)
        )
        recorders[tile.id] = recorder
        tile.recorder = recorder
        tile.source.sink.attach(recorder)
    }

    /// Arms or disarms an input. During a session this punches it in or out straight away: arming starts it
    /// recording into the session in a new segment, and disarming closes its current segment.
    func setArmed(_ tile: InputTile, _ armed: Bool) {
        tile.isArmed = armed
        guard session != nil else { return }
        if armed {
            punchedOut.remove(tile.id)
            joinSession(tile)
        } else {
            punchedOut.insert(tile.id)
            // Detached first, so a stopped recorder does not log the signal coming and going while it is out.
            tile.source.sink.attach(nil)
            tile.recorder?.stopRecording()
        }
        tile.refresh()
        refreshCounts()
    }

    /// An input that arrives mid-session joins it: a returning device resumes, and a new one starts.
    private func joinSession(_ tile: InputTile) {
        guard let session else { return }
        // A reconnected tile starts out armed, but an input punched out of this session stays out.
        if punchedOut.contains(tile.id) { tile.isArmed = false }
        guard tile.isArmed else { return }
        if let recorder = recorders[tile.id] {
            tile.recorder = recorder
            tile.source.sink.attach(recorder)
            // Punches a stopped recorder back in. One still waiting for its device carries on by itself.
            recorder.startRecording()
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
            isDriverProblem = true
            return
        }
        driverStatus = "Desktop Video \(driver), SDK \(DLDiscovery.sdkVersion)"

        let started = startDeviceNotifications()
        if !started {
            driverStatus = "Could not start device discovery. Desktop Video \(driver) may be older than SDK \(DLDiscovery.sdkVersion)."
            isDriverProblem = true
        }
    }

    private func startDeviceNotifications() -> Bool {
        discovery.start(
            arrived: { [weak self] device in
                Task { @MainActor in self?.add(DeckLinkCaptureSource(device: device)) }
            },
            removed: { [weak self] device in
                let id = device.identifier
                Task { @MainActor in self?.remove(id: id) }
            },
            profileChanged: { [weak self] in
                Task { @MainActor in self?.scheduleInputRebuild() }
            }
        )
    }

    /// One profile change notifies every sub-device, so the notifications are coalesced into one rebuild.
    private func scheduleInputRebuild() {
        guard !inputRebuildPending else { return }
        inputRebuildPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.inputRebuildPending = false
            self?.rebuildDeckLinkInputs()
        }
    }

    /// A profile change alters which connectors are inputs, for example on a Duo 2,
    /// so the inputs are rediscovered. Recording inputs that survive rejoin the session.
    private func rebuildDeckLinkInputs() {
        tiles.filter { !$0.source.input.isSynthetic }.forEach { remove(id: $0.id) }
        discovery.stop()
        if !startDeviceNotifications() {
            driverStatus = "Could not restart device discovery after a profile change."
            isDriverProblem = true
        }
    }

    private func add(_ source: CaptureSource) {
        guard !tiles.contains(where: { $0.id == source.input.id }) else { return }
        let tile = InputTile(source: source, name: inputNames.name(for: source.input), timecodeSource: inputTimecodeSources.source(for: source.input.id))
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
