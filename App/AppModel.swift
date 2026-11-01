import Foundation
import ISOCore

/// One tile in the multiview.
final class InputTile: ObservableObject, Identifiable {
    let source: CaptureSource
    var id: String { source.input.id }
    @Published var status = PreviewFrameStore.Status()
    @Published var measuredFPS = 0.0
    @Published var errorMessage: String?

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
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tiles: [InputTile] = []
    @Published private(set) var driverStatus = ""

    private let discovery = DLDiscovery()
    private var refreshTimer: Timer?
    private var syntheticCount = 0

    init() {
        startDiscovery()
        let launchCount = UserDefaults.standard.integer(forKey: "synthetic")
        for _ in 0..<launchCount { addSyntheticInput() }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tiles.forEach { $0.refresh() }
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
        do {
            try source.start()
        } catch {
            tile.errorMessage = error.localizedDescription
        }
    }

    private func remove(id: String) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        tiles[index].source.stop()
        tiles.remove(at: index)
    }
}
