import AppKit
import ISOEngine
import SwiftUI

enum SettingsTab: String {
    case general, output

    /// Also settable on launch, for example `-settingsTab output` with `-openSettings YES`.
    static let storageKey = "settingsTab"
}

struct SettingsScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(model: model, updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            OutputSettingsView(model: model, store: model.outputSettings)
                .tabItem { Label("Output", systemImage: "film") }
                .tag(SettingsTab.output)
        }
    }
}

/// Where recordings go and what each input is called.
struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some View {
        Form {
            Section {
                LabeledContent("Save recordings to") {
                    Text((model.recordingRoot as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.recordingRoot)
                }
                if let problem = model.recordingRootProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                HStack {
                    Button("Choose…", action: chooseFolder)
                    Button("Show in Finder", action: showInFinder)
                        .disabled(model.recordingRootProblem != nil)
                    Spacer()
                    if !model.isUsingDefaultRecordingRoot {
                        Button("Use Default") { model.setRecordingRoot(nil) }
                    }
                }
                .disabled(model.isRecording)
            } header: {
                Text("Recording folder")
            } footer: {
                Text(model.isRecording
                    ? "The folder can be changed after recording stops."
                    : "Each recording is saved in its own dated folder inside this one.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.tiles.isEmpty {
                    Text("Connect an input to name it.").foregroundStyle(.secondary)
                }
                ForEach(model.tiles) { tile in
                    TextField(
                        tile.source.input.displayName,
                        text: Binding(
                            get: { model.customName(for: tile) },
                            set: { model.rename(tile, to: $0) }
                        ),
                        prompt: Text(tile.source.input.displayName)
                    )
                }
            } header: {
                Text("Input names")
            } footer: {
                Text("Recordings are named after their input. Leave a name empty to use the device name. Names are kept for inputs that are disconnected.")
                    .foregroundStyle(.secondary)
            }

            RemoteControlSection(model: model)

            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                .disabled(!updater.canCheckForUpdates)
                HStack {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("An update accepted during a recording installs after recording stops.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 640)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where new recordings are saved."
        if model.recordingRootProblem == nil {
            panel.directoryURL = URL(fileURLWithPath: model.recordingRoot)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setRecordingRoot(url.path == AppModel.defaultRecordingRoot ? nil : url.path)
    }

    private func showInFinder() {
        try? FileManager.default.createDirectory(atPath: model.recordingRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.recordingRoot)
    }
}

/// The control API, for Bitfocus Companion, Stream Deck or curl.
private struct RemoteControlSection: View {
    @ObservedObject var model: AppModel
    @State private var draftPort = ""
    @State private var addresses: [String] = []

    var body: some View {
        Section {
            LabeledContent("Port") {
                TextField("Port", text: $draftPort, prompt: Text(String(ControlSettings.defaultPort)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onSubmit(applyPort)
            }
            Toggle("Allow control from other computers", isOn: Binding(
                get: { model.control.allowsLAN },
                set: { allowed in model.updateControl { $0.allowsLAN = allowed } }
            ))
            .disabled(!model.control.isEnabled)

            if model.control.isEnabled, model.control.allowsLAN {
                LabeledContent("Address") {
                    Text(addresses.isEmpty ? "No network connection" : addresses.map { "\($0):\(model.control.port)" }.joined(separator: "\n"))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                LabeledContent("Access token") {
                    HStack {
                        Text(model.control.token)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.control.token, forType: .string)
                        }
                        Button("New Token") { model.regenerateControlToken() }
                            .help("Companions using the current token stop working until they are given the new one.")
                    }
                }
            }
            if let problem = model.controlProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
        } header: {
            Text("Remote control")
        } footer: {
            Text(footer).foregroundStyle(.secondary)
        }
        .onAppear {
            draftPort = String(model.control.port)
            addresses = NetworkAddresses.ipv4()
        }
        .onChange(of: model.control.allowsLAN) { addresses = NetworkAddresses.ipv4() }
    }

    private var footer: String {
        if !model.control.isEnabled { return "The control API is off. Enter a port to turn it on." }
        if model.control.allowsLAN {
            return "In Companion, add an ISO Recorder connection with this address and token. The token is sent unencrypted, so only allow this on a network you trust."
        }
        return "Companion, Stream Deck or scripts on this Mac can start and stop recording and arm inputs. Port 0 turns this off."
    }

    private func applyPort() {
        let trimmed = draftPort.trimmingCharacters(in: .whitespaces)
        guard let port = Int(trimmed.isEmpty ? String(ControlSettings.defaultPort) : trimmed), (0...Int(UInt16.max)).contains(port) else {
            draftPort = String(model.control.port)
            return
        }
        draftPort = String(port)
        model.updateControl { $0.port = port }
    }
}
