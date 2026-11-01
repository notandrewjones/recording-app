import ISOCore
import SwiftUI

@main
struct ISORecorderApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("ISO Recorder") {
            MultiviewScreen(model: model)
                .frame(minWidth: 960, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
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

            StatusBar(inputCount: model.tiles.count, driverStatus: model.driverStatus)
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
        .overlay(Rectangle().stroke(Palette.line, lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Spacer()
            Text(tile.status.signal.format?.displayName ?? "--")
        }
        .modifier(TileStrip())
    }

    private var footer: some View {
        HStack {
            Text(tile.status.timecode?.string ?? "--:--:--:--")
            Spacer()
            Text(String(format: "%.2f fps", tile.measuredFPS))
        }
        .modifier(TileStrip())
    }
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
    let inputCount: Int
    let driverStatus: String

    var body: some View {
        HStack(spacing: 16) {
            Text("\(inputCount) input\(inputCount == 1 ? "" : "s")")
            Spacer()
            Text(driverStatus)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }
}
