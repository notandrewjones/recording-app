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
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Record") {
                Button(model.isRecording ? "Stop All" : "Record All") { model.toggleRecordAll() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Add Marker") { model.addMarker() }
                    .keyboardShortcut("m", modifiers: [.command])
                    .disabled(!model.isRecording)
            }
            CommandMenu("Inputs") {
                Button("Add Synthetic Input") { model.addSyntheticInput() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Remove Synthetic Input") { model.removeLastSyntheticInput() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

private enum Palette {
    static let background = Color(white: 0.06)
    static let tile = Color(white: 0.10)
    static let line = Color(white: 0.20)
    static let secondary = Color(white: 0.62)
    static let locked = Color(red: 0.25, green: 0.80, blue: 0.40)
    static let warning = Color(red: 0.95, green: 0.70, blue: 0.20)
    static let tally = Color(red: 0.90, green: 0.12, blue: 0.14)
}

struct MultiviewScreen: View {
    @ObservedObject var model: AppModel

    private var columns: Int {
        max(1, Int(Double(model.tiles.count).squareRoot().rounded(.up)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.tiles.isEmpty {
                    EmptyInputsView(driverStatus: model.driverStatus)
                } else {
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(rows.indices, id: \.self) { row in
                            GridRow {
                                ForEach(rows[row]) { tile in
                                    InputTileView(tile: tile)
                                }
                            }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusBar(model: model)
        }
        .background(Palette.background)
    }

    private var rows: [[InputTile]] {
        stride(from: 0, to: model.tiles.count, by: columns).map {
            Array(model.tiles[$0..<min($0 + columns, model.tiles.count)])
        }
    }
}

struct EmptyInputsView: View {
    let driverStatus: String

    var body: some View {
        VStack(spacing: 8) {
            Text("No capture inputs")
                .font(.title3.weight(.semibold))
            Text("Connect a DeckLink or UltraStudio device, or press ⇧⌘N to add a synthetic input.")
                .foregroundStyle(Palette.secondary)
        }
    }
}

struct InputTileView: View {
    @ObservedObject var tile: InputTile

    var body: some View {
        ZStack {
            Palette.tile
            MetalPreviewView(store: tile.source.store)
            if let message = overlayMessage {
                Text(message)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Palette.warning)
                    .padding(10)
                    .background(.black.opacity(0.7))
            }
        }
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) { footer }
        .overlay(Rectangle().stroke(tile.isRecording ? Palette.tally : Palette.line, lineWidth: tile.isRecording ? 3 : 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { if !tile.isRecording { tile.isArmed.toggle() } }
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
        HStack(spacing: 8) {
            Circle()
                .fill(tile.status.signal.format == nil ? Palette.warning : Palette.locked)
                .frame(width: 8, height: 8)
            Text(tile.source.input.displayName).fontWeight(.semibold)
            if tile.isRecording {
                Text("REC")
                    .fontWeight(.bold)
                    .padding(.horizontal, 5)
                    .background(Palette.tally)
            } else if tile.isArmed {
                Text("ARMED").foregroundStyle(Palette.tally)
            }
            Spacer()
            Text(tile.status.signal.format?.displayName ?? "--")
        }
        .modifier(TileStrip())
    }

    private var footer: some View {
        HStack {
            Text(tile.status.timecode?.string ?? "--:--:--:--")
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
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.65))
    }
}

struct StatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Text("\(model.tiles.count) input\(model.tiles.count == 1 ? "" : "s")")
            if model.isRecording {
                Text("RECORDING").foregroundStyle(Palette.tally).fontWeight(.bold)
            } else if model.isFinalizing {
                Text("FINALIZING").foregroundStyle(Palette.warning)
            }
            if let message = model.message {
                Text(message).lineLimit(1)
            }
            Spacer()
            if let sample = model.systemSample {
                Text(String(format: "CPU %.0f%%", sample.cpuUsage * 100))
                    .foregroundStyle(sample.cpuUsage > 0.85 ? Palette.warning : Palette.secondary)
                Text(memoryText(sample))
                    .foregroundStyle(sample.memoryPressure == .critical ? Palette.tally : Palette.secondary)
            }
            if model.writeBytesPerSecond > 0 {
                Text(String(format: "%.0f MB/s", model.writeBytesPerSecond / 1_000_000))
            }
            Text(diskText).foregroundStyle(diskColor)
            Text(model.driverStatus).lineLimit(1)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }

    private func memoryText(_ sample: SystemMetrics.Sample) -> String {
        let used = Double(sample.memoryUsedBytes) / 1_073_741_824
        let total = Double(sample.memoryTotalBytes) / 1_073_741_824
        return String(format: "MEM %.0f/%.0f GB", used, total)
    }

    private var diskText: String {
        let free = String(format: "%.0f GB free", Double(model.freeBytes) / 1_000_000_000)
        guard let remaining = model.remainingSeconds else { return free }
        return "\(free) · \(remaining.durationDescription) left"
    }

    private var diskColor: Color {
        if case .low = model.storageLevel { return Palette.warning }
        return Palette.secondary
    }
}
