import AppKit
import ISOCore
import ISOEngine
import SwiftUI

/// Warns before quitting while segments are open. Recovery would finish them on the next launch, but
/// the operator should choose that knowingly, particularly if the drive is about to be unplugged.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var hasOpenSegments: () -> Bool = { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard hasOpenSegments() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Recordings are still being saved"
        alert.informativeText = "If you quit now, they will be finished the next time ISO Recorder opens. Keep the drive connected until then."
        alert.addButton(withTitle: "Keep Saving")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}

@main
struct ISORecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()

    init() {
        // After a crash or kill, restoration brought the app back with no window at all, which is
        // the worst moment to lose the multiview. This app always opens its one window fresh.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    var body: some Scene {
        Window("ISO Recorder", id: "multiview") {
            MultiviewScreen(model: model)
                .frame(minWidth: 960, minHeight: 600)
                .preferredColorScheme(.dark)
                .onAppear {
                    let model = model
                    delegate.hasOpenSegments = { model.isRecording || model.isFinalizing }
                    updater.hasOpenSegments = { model.isRecording || model.isFinalizing }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        Settings {
            SettingsScreen(model: model, updater: updater)
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandMenu("Record") {
                Button(model.isRecording ? "Stop All" : "Record All") { model.toggleRecordAll() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Add Marker") { model.addMarker() }
                    .keyboardShortcut("m", modifiers: [.command])
                    .disabled(!model.isRecording)
                Divider()
                Button("Export Diagnostics") { model.exportDiagnostics() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Inputs") {
                // ⌘1–⌘9 arm or disarm by position, so punching in needs no mouse. Stopping one mid-session still asks.
                ForEach(Array(model.tiles.prefix(9).enumerated()), id: \.element.id) { index, tile in
                    Button(armCommandTitle(tile)) { model.requestToggleArmed(tile) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                }
                if !model.tiles.isEmpty { Divider() }
                Button("Add Synthetic Input") { model.addSyntheticInput() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Remove Synthetic Input") { model.removeLastSyntheticInput() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }

    private func armCommandTitle(_ tile: InputTile) -> String {
        if model.isRecording {
            return tile.isArmed ? "Stop Recording \(tile.name)…" : "Record \(tile.name)"
        }
        return tile.isArmed ? "Disarm \(tile.name)" : "Arm \(tile.name)"
    }
}

private enum Palette {
    static let background = Color(white: 0.06)
    static let chrome = Color(white: 0.09)
    static let control = Color(white: 0.14)
    /// Idle and disabled text. 4.5:1 against both `background` and `chrome`.
    static let dim = Color(white: 0.50)
    static let tile = Color(white: 0.10)
    static let line = Color(white: 0.20)
    static let secondary = Color(white: 0.62)
    static let primaryText = Color(white: 0.9)
    static let locked = Color(red: 0.25, green: 0.80, blue: 0.40)
    static let warning = Color(red: 0.95, green: 0.70, blue: 0.20)
    static let tally = Color(red: 0.90, green: 0.12, blue: 0.14)
}

struct MultiviewScreen: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general
    /// Encoder warnings the operator has acknowledged. They return if the plan changes and the text changes.
    @State private var dismissedWarnings: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(notices) { NoticeBanner(notice: $0) }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: notices.map(\.id))
            Group {
                if model.tiles.isEmpty {
                    EmptyInputsView(driverStatus: model.driverStatus, isDriverProblem: model.isDriverProblem)
                } else {
                    GeometryReader { geometry in
                        let columns = MultiviewLayout.columns(for: model.tiles.count, in: geometry.size, spacing: Self.spacing)
                        Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
                            ForEach(rows(columns: columns).indices, id: \.self) { row in
                                GridRow {
                                    ForEach(rows(columns: columns)[row]) { tile in
                                        InputTileView(
                                            tile: tile,
                                            sessionActive: model.isRecording,
                                            rename: { model.rename(tile, to: $0) },
                                            toggleArmed: { model.requestToggleArmed(tile) },
                                            setTimecodeSource: { model.setTimecodeSource(tile, $0) }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(Self.spacing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusBar(model: model)
        }
        .background(Palette.background)
        .toolbar { TransportToolbar(model: model) }
        .toolbarBackground(Palette.chrome, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .confirmationDialog(
            "Stop recording \(model.pendingPunchOut?.name ?? "this input")?",
            isPresented: Binding(get: { model.pendingPunchOut != nil }, set: { if !$0 { model.pendingPunchOut = nil } }),
            presenting: model.pendingPunchOut
        ) { tile in
            Button("Stop Recording \(tile.name)", role: .destructive) { model.setArmed(tile, false) }
            Button("Keep Recording", role: .cancel) {}
        } message: { _ in
            Text("The other inputs keep recording. Arm it again to record it into this session in a new file.")
        }
        .task {
            // `-openSettings YES` opens the output settings on launch, for checking their layout.
            if UserDefaults.standard.bool(forKey: "openSettings") { openSettings() }
        }
    }

    private static let spacing: CGFloat = 6

    /// Problems that stop or threaten a recording, most serious first.
    private var notices: [Notice] {
        var notices: [Notice] = []
        if let failure = model.recordingFailure {
            notices.append(Notice(
                id: "failure",
                severity: .failure,
                text: failure.text,
                action: failure.settingsTab.map { tab in (title: "Open Settings", perform: { open(tab) }) },
                dismiss: { model.dismissRecordingFailure() }
            ))
        }
        if let problem = model.recordingRootProblem, !model.isRecording, model.recordingFailure?.settingsTab != .general {
            notices.append(Notice(
                id: "folder",
                severity: .warning,
                text: "Recording won't start. \(problem)",
                action: (title: "Choose Folder…", perform: { open(.general) })
            ))
        }
        for warning in model.capacityWarnings where !dismissedWarnings.contains(warning) {
            notices.append(Notice(
                id: "capacity-\(warning)",
                severity: .warning,
                text: warning,
                action: (title: "Output Settings", perform: { open(.output) }),
                dismiss: { dismissedWarnings.insert(warning) }
            ))
        }
        return notices
    }

    private func open(_ tab: SettingsTab) {
        settingsTab = tab
        openSettings()
    }

    private func rows(columns: Int) -> [[InputTile]] {
        stride(from: 0, to: model.tiles.count, by: columns).map {
            Array(model.tiles[$0..<min($0 + columns, model.tiles.count)])
        }
    }
}

enum MultiviewLayout {
    /// The column count that shows 16:9 pictures largest in `size`, so three inputs in a wide window
    /// sit side by side instead of leaving a quarter of a 2×2 grid empty.
    static func columns(for count: Int, in size: CGSize, spacing: CGFloat) -> Int {
        guard count > 1, size.width > 0, size.height > 0 else { return 1 }
        var best = (columns: 1, width: CGFloat(0))
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let cellWidth = (size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let pictureWidth = min(cellWidth, cellHeight * 16 / 9)
            if pictureWidth > best.width + 0.5 { best = (columns, pictureWidth) }
        }
        return best.columns
    }
}

/// Record, the session clock and markers sit in the window's toolbar, where the operator looks first.
struct TransportToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            // Without the flexible spacer the summary packs against the controls instead of the trailing edge.
            Group {
                transport
                ToolbarSpacer(.flexible)
                summary
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            transport
            summary
        }
    }

    private var transport: some ToolbarContent {
        ToolbarItem(placement: .navigation) { TransportControls(model: model) }
    }

    private var summary: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { SessionSummary(model: model) }
    }
}

struct TransportControls: View {
    @ObservedObject var model: AppModel
    @State private var shownMarker: MarkerNote?

    var body: some View {
        HStack(spacing: 14) {
            RecordButton(isRecording: model.isRecording, isFinalizing: model.isFinalizing, failedStarts: model.failedStartCount) {
                model.toggleRecordAll()
            }
            SessionClock(startedAt: model.sessionStartedAt)
            Button {
                model.addMarker()
            } label: {
                Label("Marker", systemImage: "bookmark.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(ChromeButtonStyle())
            .disabled(!model.isRecording)
            .help("Add a marker to the session (⌘M)")
            if let shownMarker {
                Text("Marker \(shownMarker.number) at \(SessionClock.format(shownMarker.elapsed))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 6)
        .task(id: model.lastMarker?.id) {
            withAnimation(.easeOut(duration: 0.15)) { shownMarker = model.lastMarker }
            guard model.lastMarker != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.4)) { shownMarker = nil }
        }
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let isFinalizing: Bool
    /// Each change shakes the button once, so a refused start is felt where the operator pressed.
    let failedStarts: Int
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isRecording {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
                } else {
                    Circle().fill(isFinalizing ? Palette.secondary : Palette.tally).frame(width: 12, height: 12)
                }
                Text(isRecording ? "Stop" : isFinalizing ? "Saving…" : "Record")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isRecording ? .white : Palette.primaryText)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(isRecording ? Palette.tally : Palette.control))
            .overlay(Capsule().stroke(isRecording ? .clear : Palette.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isFinalizing)
        .keyframeAnimator(initialValue: CGFloat(0), trigger: failedStarts) { content, offset in
            content.offset(x: reduceMotion ? 0 : offset)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-7, duration: 0.05)
                LinearKeyframe(6, duration: 0.07)
                LinearKeyframe(-4, duration: 0.07)
                LinearKeyframe(2, duration: 0.06)
                SpringKeyframe(0, duration: 0.15)
            }
        }
        .help(isRecording ? "Stop every input (⌘R)" : "Record every armed input (⌘R)")
    }
}

/// Elapsed time in the session, ticking once a second. Idle, it shows zeros at reduced strength.
struct SessionClock: View {
    let startedAt: Date?

    var body: some View {
        Group {
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Self.format(context.date.timeIntervalSince(startedAt)))
                        .foregroundStyle(Palette.primaryText)
                }
            } else {
                Text(Self.format(0)).foregroundStyle(Palette.dim)
            }
        }
        .font(.system(size: 20, weight: .medium, design: .monospaced))
        .accessibilityLabel(startedAt == nil ? "Not recording" : "Session time")
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}

/// How many inputs are in the session and how long the drive lasts at this rate.
struct SessionSummary: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            if !model.tiles.isEmpty {
                Text(model.isRecording
                    ? "\(model.recordingCount) of \(model.tiles.count) recording"
                    : "\(model.armedCount) of \(model.tiles.count) armed")
            }
            // A missing drive has no free space to measure, so there is no time to show.
            if let remaining = model.remainingSeconds, model.isRecording || model.recordingRootProblem == nil {
                let isEstimate = model.writeBytesPerSecond == 0
                Text("\(isEstimate ? "≈ " : "")\(remaining.durationDescription) left")
                    .foregroundStyle(remaining < 600 ? Palette.tally : remaining < 1800 ? Palette.warning : Palette.secondary)
                    .fontWeight(remaining < 1800 ? .semibold : .regular)
                    .help(isEstimate
                        ? "Estimated for the armed inputs from each codec's data rate. Under 30 minutes turns amber, under 10 red."
                        : "At the average write rate over the last 30 seconds, until recording stops to keep 2 GB free. Under 30 minutes turns amber, under 10 red.")
            }
        }
        .font(.system(size: 13).monospacedDigit())
        .foregroundStyle(Palette.secondary)
        .padding(.trailing, 6)
    }
}

struct Notice: Identifiable {
    enum Severity { case failure, warning }

    let id: String
    let severity: Severity
    let text: String
    var action: (title: String, perform: () -> Void)?
    var dismiss: (() -> Void)?
}

/// A full-width problem row under the toolbar. It stays until the problem is fixed or dismissed.
struct NoticeBanner: View {
    let notice: Notice

    private var tint: Color { notice.severity == .failure ? Palette.tally : Palette.warning }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.severity == .failure ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(notice.text)
                .foregroundStyle(Palette.primaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(notice.text)
            if let action = notice.action {
                Button(action.title, action: action.perform).buttonStyle(ChromeButtonStyle())
            }
            if let dismiss = notice.dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.opacity(0.16))
        .overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
}

/// A quiet bordered capsule for secondary toolbar actions.
struct ChromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? Palette.primaryText : Palette.dim)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(configuration.isPressed ? Palette.line : Palette.control))
            .overlay(Capsule().stroke(Palette.line))
            .contentShape(Capsule())
    }
}

struct EmptyInputsView: View {
    let driverStatus: String
    let isDriverProblem: Bool

    var body: some View {
        VStack(spacing: 8) {
            if isDriverProblem {
                // Without the driver no device can appear, so plugging one in is not the next step.
                Text("Capture devices can't be found")
                    .font(.title3.weight(.semibold))
                Text("\(driverStatus). Install or update Blackmagic Desktop Video, then reopen ISO Recorder.")
                    .foregroundStyle(Palette.secondary)
            } else {
                Text("No capture inputs")
                    .font(.title3.weight(.semibold))
                Text("Connect a DeckLink or UltraStudio device. Its inputs appear here.")
                    .foregroundStyle(Palette.secondary)
            }
            Text("To test without hardware, press ⇧⌘N to add a synthetic input.")
                .font(.callout)
                .foregroundStyle(Palette.dim)
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
    }
}

struct InputTileView: View {
    @ObservedObject var tile: InputTile
    /// Whether a session is recording, which turns a disarmed input from "won't record" into "missing".
    let sessionActive: Bool
    let rename: (String) -> Void
    let toggleArmed: () -> Void
    let setTimecodeSource: (TimecodeSource) -> Void
    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        ZStack {
            Palette.tile
            MetalPreviewView(store: tile.source.store)
            if !tile.isArmed {
                // Dimmed so an input left out of the recording stands apart from the live ones at a glance.
                Color.black.opacity(0.55)
            }
            if let message = overlayMessage {
                Text(message)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.warning)
                    .padding(10)
                    .background(.black.opacity(0.7))
            }
        }
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) { footer }
        .overlay(Rectangle().stroke(borderColor, lineWidth: borderColor == Palette.line ? 1 : 3))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Clicks on the picture do nothing: arming has its own button, so a stray click can't drop an angle.
        .contextMenu {
            Button(armButtonLabel, action: toggleArmed)
            Button("Rename…", action: beginRename)
            Picker("Timecode", selection: timecodeSelection) {
                ForEach(TimecodeSource.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(tile.isRecording)
        }
        .alert("Rename \(tile.source.input.displayName)", isPresented: $isRenaming) {
            TextField(tile.source.input.displayName, text: $draftName)
            Button("Rename") { rename(draftName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(tile.isRecording
                ? "Files already recording keep their current name. Leave empty to use the device name."
                : "Recordings are named after the input. Leave empty to use the device name.")
        }
    }

    private var timecodeSelection: Binding<TimecodeSource> {
        Binding(get: { tile.timecodeSource }, set: setTimecodeSource)
    }

    private func beginRename() {
        draftName = tile.name == tile.source.input.displayName ? "" : tile.name
        isRenaming = true
    }

    private var armButtonLabel: String {
        if tile.isRecording { return "Stop Recording \(tile.name)…" }
        if sessionActive { return tile.isArmed ? "Disarm \(tile.name)" : "Record \(tile.name)" }
        return tile.isArmed ? "Disarm \(tile.name)" : "Arm \(tile.name)"
    }

    private var stateDescription: String {
        if tile.isRecording { return "recording" }
        if !tile.isArmed { return sessionActive ? "not recording" : "not armed" }
        return "armed"
    }

    /// Red while recording, amber while a session runs without this input, otherwise a hairline.
    private var borderColor: Color {
        if tile.isRecording { return Palette.tally }
        if sessionActive, !tile.isArmed { return Palette.warning }
        return Palette.line
    }

    private var overlayMessage: String? {
        if let error = tile.errorMessage { return error }
        switch tile.status.signal {
        case .noSignal: return "NO SIGNAL"
        case .unknown: return "WAITING FOR INPUT"
        case .locked: return nil
        }
    }

    private var header: some View {
        // The format is dropped before the name is cut short, and the state chip always stays.
        ViewThatFits(in: .horizontal) {
            headerRow(showsFormat: true)
            headerRow(showsFormat: false)
        }
        .modifier(TileStrip())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tile.name), \(stateDescription), \(tile.status.signal.format?.displayName ?? "no signal")")
    }

    private func headerRow(showsFormat: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tile.status.signal.format == nil ? Palette.warning : Palette.locked)
                .frame(width: 8, height: 8)
            Text(tile.name)
                .fontWeight(.semibold)
                .lineLimit(1)
                .onTapGesture(count: 2, perform: beginRename)
                .help(tile.name == tile.source.input.displayName ? "Double-click to rename" : "\(tile.source.input.displayName). Double-click to rename.")
            // Armed is the normal state, so only the exceptions are labelled.
            if tile.isRecording {
                StateChip(text: "REC", foreground: .white, fill: Palette.tally)
            } else if !tile.isArmed {
                if sessionActive {
                    StateChip(text: "NOT RECORDING", foreground: .black, fill: Palette.warning)
                } else {
                    StateChip(text: "NOT ARMED", foreground: Palette.primaryText, fill: Palette.control, stroke: Palette.secondary)
                }
            }
            Spacer(minLength: 4)
            if showsFormat {
                Text(tile.status.signal.format?.displayName ?? "--")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize()
            }
            TimecodeMenu(tile: tile, selection: timecodeSelection)
            ArmButton(isArmed: tile.isArmed, isRecording: tile.isRecording, label: armButtonLabel, action: toggleArmed)
        }
    }

    private var footer: some View {
        HStack {
            Text(tile.displayTimecode?.string ?? "--:--:--:--")
                .font(.system(size: 12, design: .monospaced))
                .fixedSize()
            Spacer(minLength: 8)
            if let recorder = tile.recorderStatus, tile.isRecording {
                LoadBar(fill: recorder.ringFill)
                Text(recorderSummary(recorder))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(String(format: "%.2f fps", tile.measuredFPS))
                    .fixedSize()
            }
        }
        .modifier(TileStrip())
    }
}

/// Chooses where the input's timecode comes from. Locked while it records, because a file keeps the
/// timecode it started with; the choice applies to its next recording.
private struct TimecodeMenu: View {
    @ObservedObject var tile: InputTile
    @Binding var selection: TimecodeSource

    private var help: String {
        let current = "Timecode: \(tile.timecodeSource.displayName)."
        return tile.isRecording ? "\(current) Change it when this input is not recording." : current
    }

    var body: some View {
        Menu {
            Picker("Timecode", selection: $selection) {
                ForEach(TimecodeSource.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(tile.timecodeSource.shortLabel)
                .fontWeight(.bold)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 5)
        .frame(minHeight: 20)
        .background(RoundedRectangle(cornerRadius: 4).fill(Palette.control))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line))
        .disabled(tile.isRecording)
        .help(help)
        .accessibilityLabel("Timecode for \(tile.name)")
        .accessibilityValue(tile.timecodeSource.displayName)
    }
}

/// The record-arm button: a filled red ring when the input will record, an empty one when it won't.
private struct ArmButton: View {
    let isArmed: Bool
    let isRecording: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isArmed ? "record.circle.fill" : "record.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isArmed ? Palette.tally : Palette.secondary)
                if !isArmed {
                    Text("ARM").fontWeight(.bold).fixedSize()
                }
            }
            .padding(.horizontal, isArmed ? 3 : 6)
            .frame(minWidth: 24, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.control.opacity(isArmed ? 0 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isArmed ? .clear : Palette.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A short state label in a tile header, such as REC.
private struct StateChip: View {
    let text: String
    let foreground: Color
    let fill: Color
    var stroke: Color = .clear

    var body: some View {
        Text(text)
            .fontWeight(.bold)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .background(fill)
            .overlay(Rectangle().stroke(stroke))
    }
}

/// How much of the input's ring is in use. It stays near empty until the encoder falls behind.
private struct LoadBar: View {
    let fill: Double

    private var color: Color {
        switch InputLoad(ringFill: fill) {
        case .healthy: Palette.locked
        case .strained: Palette.warning
        case .overloaded: Palette.tally
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Palette.line
                color.frame(width: geometry.size.width * max(0.02, min(fill, 1)))
            }
        }
        .frame(width: 44, height: 6)
    }
}

private func recorderSummary(_ status: InputRecorderStatus) -> String {
    var parts = ["seg \(status.segment ?? 0)", "\(status.totalFrames) f"]
    if status.repeatedFrames > 0 { parts.append("\(status.repeatedFrames) rpt") }
    if status.gapFrames > 0 { parts.append("\(status.gapFrames) gap") }
    if status.restarts > 0 { parts.append("\(status.restarts) restart\(status.restarts == 1 ? "" : "s")") }
    return parts.joined(separator: " · ")
}

private struct TileStrip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12).monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.65))
    }
}

/// Messages on the left, the machine and the drive on the right. Recording state lives in the toolbar
/// and problems in the banner, so neither is repeated here.
struct StatusBar: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    var body: some View {
        HStack(spacing: 16) {
            if let message = model.message {
                Text(message)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(message)
            }
            Spacer(minLength: 16)
            if model.isDriverProblem {
                Text(model.driverStatus).foregroundStyle(Palette.warning).lineLimit(1).help(model.driverStatus)
            }
            StatusLink(text: model.outputSettings.defaults.codec.displayName, help: "Output settings") {
                open(.output)
            }
            if let sample = model.systemSample {
                if sample.memoryPressure == .critical {
                    Text("Memory pressure critical").foregroundStyle(Palette.tally)
                }
                Text(String(format: "CPU %.0f%%", sample.cpuUsage * 100))
                    .foregroundStyle(sample.cpuUsage > 0.85 ? Palette.warning : Palette.secondary)
                    .help("\(memoryText(sample)). \(model.driverStatus).")
            }
            if model.writeBytesPerSecond > 0 {
                Text(String(format: "%.0f MB/s", model.writeBytesPerSecond / 1_000_000))
                    .help("Write rate to the recording drive")
            }
            StatusLink(text: diskText, color: diskColor, help: model.recordingRootProblem ?? "Recording to \(model.recordingRoot)") {
                open(.general)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Palette.secondary)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 26)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }

    private func open(_ tab: SettingsTab) {
        settingsTab = tab
        openSettings()
    }

    private func memoryText(_ sample: SystemMetrics.Sample) -> String {
        let used = Double(sample.memoryUsedBytes) / 1_073_741_824
        let total = Double(sample.memoryTotalBytes) / 1_073_741_824
        return String(format: "Memory %.0f of %.0f GB in use", used, total)
    }

    private var diskText: String {
        if model.recordingRootProblem != nil, !model.isRecording { return "Recording folder unavailable" }
        return String(format: "%.0f GB free", Double(model.freeBytes) / 1_000_000_000)
    }

    private var diskColor: Color {
        if model.recordingRootProblem != nil, !model.isRecording { return Palette.warning }
        if case .low = model.storageLevel { return Palette.warning }
        return Palette.secondary
    }
}

/// Status text that opens settings. A chevron and a hover fill show that it can be clicked.
private struct StatusLink: View {
    let text: String
    var color: Color = Palette.secondary
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).opacity(0.7)
            }
            .foregroundStyle(isHovered ? Palette.primaryText : color)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(isHovered ? Palette.control : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
