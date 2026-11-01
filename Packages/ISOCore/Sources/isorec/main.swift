import Foundation
import ISOCore
import ISOEngine

// Headless recorder for testing the engine with synthetic sources.
//
//   isorec record --root DIR [--name NAME] [--inputs N] [--seconds S] [--codec hq|lt|422|proxy|4444]
//                 [--no-audio] [--grain] [--min-free-mb MB]
//   isorec recover DIR

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func flag(_ name: String) -> Bool {
    CommandLine.arguments.contains(name)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func codec(_ name: String) -> Codec {
    switch name {
    case "proxy": .proResProxy
    case "lt": .proResLT
    case "422": .proRes422
    case "4444": .proRes4444
    default: .proResHQ
    }
}

let command = CommandLine.arguments.dropFirst().first ?? ""
let environment: FFmpegEnvironment
do {
    environment = try FFmpegEnvironment.locate(preferredPath: option("--ffmpeg"))
} catch {
    fail("\(error)")
}

switch command {
case "record":
    guard let root = option("--root") else { fail("--root is required") }
    let inputCount = Int(option("--inputs") ?? "") ?? 1
    let seconds = Double(option("--seconds") ?? "") ?? 10
    let audioChannels = flag("--no-audio") ? 0 : 16
    let settings = InputRecorderSettings(codec: codec(option("--codec") ?? "hq"), audio: audioChannels > 0 ? AudioFormat(channels: audioChannels) : nil)

    let session: RecordingSession
    do {
        var policy = StoragePolicy()
        if let megabytes = Int64(option("--min-free-mb") ?? "") { policy.criticalFreeBytes = megabytes * 1_048_576 }
        session = try RecordingSession(rootPath: root, name: option("--name"), environment: environment, storagePolicy: policy)
    } catch {
        fail("Could not create session: \(error)")
    }

    let pool = flag("--grain") ? SyntheticFramePool(format: .hd1080p5994) : nil
    var sources: [SyntheticSource] = []
    var recorders: [InputRecorder] = []
    for index in 1...inputCount {
        let recorder = session.addInput(id: "synthetic-\(index)", label: "Cam \(index)", settings: settings)
        let source = SyntheticSource(audioChannels: audioChannels, pool: pool)
        source.onFrame = { recorder.ingest($0) }
        source.start()
        sources.append(source)
        recorders.append(recorder)
    }
    print("session \(session.layout.sessionDirectory)")
    Thread.sleep(forTimeInterval: 0.2)
    session.startAll()
    let stoppedEarly = DispatchSemaphore(value: 0)
    session.onStoppedForDiskSpace = {
        print("stopped: drive nearly full")
        stoppedEarly.signal()
    }
    let metrics = SystemMetrics()
    _ = metrics.sample()
    var peakCPU = 0.0
    var worstPressure = MemoryPressure.normal
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if stoppedEarly.wait(timeout: .now() + 1) == .success { break }
        let sample = metrics.sample()
        peakCPU = max(peakCPU, sample.cpuUsage)
        if sample.memoryPressure.rawValue > worstPressure.rawValue { worstPressure = sample.memoryPressure }
    }
    let liveRate = session.health.writeBytesPerSecond
    session.stopAll()
    sources.forEach { $0.cancel() }
    session.waitUntilFinished()
    for recorder in recorders {
        let status = recorder.status()
        print("\(recorder.label): frames=\(status.totalFrames) repeated=\(status.repeatedFrames) restarts=\(status.restarts) gap=\(status.gapFrames) peakRing=\(Int(status.peakRingFill * 100))%")
    }
    print(String(format: "machine: peakCPU=%.0f%% memoryPressure=%@ write=%.0f MB/s", peakCPU * 100, String(describing: worstPressure), liveRate / 1_000_000))

case "recover":
    guard CommandLine.arguments.count > 2 else { fail("recover needs a session directory") }
    do {
        let report = try SessionRecovery.recover(directory: CommandLine.arguments[2], environment: environment)
        print("recovered=\(report.recovered) failed=\(report.failed)")
    } catch {
        fail("Could not recover: \(error)")
    }

default:
    fail("usage: isorec record --root DIR [--inputs N] [--seconds S] | isorec recover DIR")
}
