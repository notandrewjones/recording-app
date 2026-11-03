import ISOCore
import SwiftUI

private enum CodecChoice: String, CaseIterable, Identifiable {
    case proRes = "ProRes"
    case hevc = "HEVC"
    case h264 = "H.264"

    var id: String { rawValue }
}

private let proResProfiles: [Codec] = [.proResProxy, .proResLT, .proRes422, .proResHQ, .proRes4444]

/// Output controls laid out like OBS: pick a codec, an encoder and a rate control, then its values.
struct OutputSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: OutputSettingsStore
    @State private var selection = "default"

    private var selectedTile: InputTile? {
        model.tiles.first { $0.id == selection }
    }

    var body: some View {
        Form {
            Section {
                Picker("Applies to", selection: $selection) {
                    Text("All inputs").tag("default")
                    ForEach(model.tiles) { tile in
                        Text(tile.name).tag(tile.id)
                    }
                }
                if let tile = selectedTile {
                    Toggle("Use different settings for this input", isOn: overrideBinding(tile))
                }
            }

            if let tile = selectedTile {
                if store.hasOverride(tile.id) {
                    OutputEditor(settings: settingsBinding(tile.id), maxAudioChannels: tile.source.input.maxAudioChannels)
                } else {
                    Section { Text("This input uses the settings for all inputs.").foregroundStyle(.secondary) }
                }
            } else {
                OutputEditor(settings: $store.defaults, maxAudioChannels: 16)
            }

            Section("Estimate") {
                LabeledContent("Storage per input", value: storageText(for: currentSettings))
                ForEach(model.capacityWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 760)
        .disabled(model.isRecording)
        .overlay(alignment: .bottom) {
            if model.isRecording {
                Text("Settings are locked while recording.")
                    .font(.callout)
                    .padding(8)
            }
        }
    }

    private var currentSettings: OutputSettings {
        store.settings(for: selection)
    }

    private func storageText(for settings: OutputSettings) -> String {
        let audio = AudioFormat(channels: settings.audioChannels)
        guard let bytes = StorageEstimate.bytesPerHour(format: model.referenceFormat, codec: settings.codec, audio: audio) else {
            return "Depends on the picture"
        }
        return String(format: "About %.0f GB/hour at %@", bytes / 1_000_000_000, model.referenceFormat.displayName)
    }

    private func settingsBinding(_ id: String) -> Binding<OutputSettings> {
        Binding(
            get: { store.settings(for: id) },
            set: { store.setOverride($0, for: id) }
        )
    }

    private func overrideBinding(_ tile: InputTile) -> Binding<Bool> {
        Binding(
            get: { store.hasOverride(tile.id) },
            set: { store.setOverride($0 ? store.defaults : nil, for: tile.id) }
        )
    }
}

private struct OutputEditor: View {
    @Binding var settings: OutputSettings
    let maxAudioChannels: Int

    private var choice: Binding<CodecChoice> {
        Binding(
            get: {
                if case .longGOP(let long) = settings.codec {
                    return long.encoder.family == .hevc ? .hevc : .h264
                }
                return .proRes
            },
            set: { newValue in
                switch newValue {
                case .proRes: settings.codec = .proResLT
                case .hevc: settings.codec = .longGOP(.defaultSettings(for: .hevc))
                case .h264: settings.codec = .longGOP(.defaultSettings(for: .h264))
                }
            }
        )
    }

    private var longGOP: Binding<LongGOPSettings>? {
        guard case .longGOP(let current) = settings.codec else { return nil }
        return Binding(
            get: { current },
            set: { settings.codec = .longGOP($0) }
        )
    }

    var body: some View {
        Section("Video") {
            Picker("Codec", selection: choice) {
                ForEach(CodecChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if let longGOP {
                LongGOPEditor(settings: longGOP)
            } else {
                Picker("Profile", selection: $settings.codec) {
                    ForEach(proResProfiles, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }

        Section("Audio") {
            Picker("Embedded channels", selection: $settings.audioChannels) {
                ForEach(FFmpegCommand.supportedAudioChannelCounts.filter { $0 <= maxAudioChannels }, id: \.self) {
                    Text("\($0)").tag($0)
                }
            }
        }
    }
}

private struct LongGOPEditor: View {
    @Binding var settings: LongGOPSettings

    private var encoders: [LongGOPEncoder] {
        LongGOPEncoder.allCases.filter { $0.family == settings.encoder.family }
    }

    private var encoder: Binding<LongGOPEncoder> {
        Binding(get: { settings.encoder }, set: { settings = settings.switched(to: $0) })
    }

    private var mode: Binding<RateControlMode> {
        Binding(
            get: { settings.rateControl.mode },
            set: { settings.rateControl = settings.rateControl.switched(to: $0, encoder: settings.encoder) }
        )
    }

    var body: some View {
        Picker("Encoder", selection: encoder) {
            ForEach(encoders) { Text($0.displayName).tag($0) }
        }
        Picker("Rate control", selection: mode) {
            ForEach(settings.encoder.supportedModes) { Text($0.displayName(for: settings.encoder)).tag($0) }
        }

        switch settings.rateControl {
        case .cbr(let rate):
            MegabitField("Bitrate", kilobits: rate) { settings.rateControl = .cbr(kbps: $0) }
        case .abr(let rate):
            MegabitField("Bitrate", kilobits: rate) { settings.rateControl = .abr(kbps: $0) }
        case .vbr(let rate, let maximum):
            MegabitField("Average bitrate", kilobits: rate) { settings.rateControl = .vbr(kbps: $0, maximumKbps: max($0, maximum)) }
            MegabitField("Maximum bitrate", kilobits: maximum) { settings.rateControl = .vbr(kbps: min(rate, $0), maximumKbps: $0) }
        case .constantQuality(let value, let maximum):
            qualityControls(value: value, maximum: maximum)
        }

        LabeledContent("Keyframe interval") {
            TextField("", value: $settings.keyframeSeconds, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text("seconds").foregroundStyle(.secondary)
        }

        if settings.encoder.usesCRF {
            Picker("Preset", selection: $settings.preset) {
                ForEach(X26xPreset.allCases) { Text($0.rawValue).tag($0) }
            }
        }
        if settings.encoder == .hevcHardware {
            Toggle("4:2:2 10-bit", isOn: $settings.chroma422)
        }
        if !settings.encoder.isHardware {
            Text("Software encoding competes with recording for CPU.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func qualityControls(value: Int, maximum: Int?) -> some View {
        let range = settings.encoder.qualityRange
        LabeledContent(settings.encoder.usesCRF ? "CRF" : "Quality") {
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { settings.rateControl = .constantQuality(value: Int($0), maximumKbps: maximum) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .frame(width: 180)
            TextField(
                "",
                value: Binding(
                    get: { value },
                    set: { settings.rateControl = .constantQuality(value: min(max($0, range.lowerBound), range.upperBound), maximumKbps: maximum) }
                ),
                format: .number.grouping(.never)
            )
            .multilineTextAlignment(.trailing)
            .frame(width: 44)
        }
        Text(settings.encoder.usesCRF ? "Lower is better quality and larger files." : "Higher is better quality and larger files.")
            .font(.callout)
            .foregroundStyle(.secondary)
        Toggle("Limit maximum bitrate", isOn: Binding(
            get: { maximum != nil },
            set: { settings.rateControl = .constantQuality(value: value, maximumKbps: $0 ? 60_000 : nil) }
        ))
        if let maximum {
            MegabitField("Maximum bitrate", kilobits: maximum) { settings.rateControl = .constantQuality(value: value, maximumKbps: $0) }
        } else {
            Text("With no limit, grainy or busy pictures can use several hundred Mb/s per input.")
                .font(.callout)
                .foregroundStyle(.yellow)
        }
    }
}

private struct MegabitField: View {
    let title: String
    let kilobits: Int
    let onChange: (Int) -> Void

    init(_ title: String, kilobits: Int, onChange: @escaping (Int) -> Void) {
        self.title = title
        self.kilobits = kilobits
        self.onChange = onChange
    }

    var body: some View {
        LabeledContent(title) {
            TextField(
                "",
                value: Binding(
                    get: { Double(kilobits) / 1000 },
                    set: { onChange(max(1000, Int($0 * 1000))) }
                ),
                format: .number.precision(.fractionLength(0...1)).grouping(.never)
            )
            .multilineTextAlignment(.trailing)
            .frame(width: 70)
            Text("Mb/s").foregroundStyle(.secondary)
        }
    }
}
