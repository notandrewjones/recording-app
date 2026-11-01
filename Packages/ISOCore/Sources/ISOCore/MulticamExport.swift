import Foundation

/// Where each recorded segment sits on a shared timeline, derived from `session.json`.
/// Host time decides position, because free-running sources can carry unrelated timecode.
public struct MulticamPlan: Sendable {
    public struct Clip: Sendable {
        public var inputLabel: String
        public var fileName: String
        public var path: String
        public var format: VideoFormat
        public var audioChannels: Int
        public var frames: Int
        public var startTimecode: Timecode
        /// Position on the timeline, in sequence frames from its start.
        public var offsetFrames: Int
        /// Length on the timeline, in sequence frames.
        public var timelineFrames: Int
    }

    public var name: String
    public var format: VideoFormat
    public var startTimecode: Timecode
    public var totalFrames: Int
    public var angles: [(label: String, clips: [Clip])]

    /// Returns nil when no segment has any frames.
    public init?(manifest: SessionManifest, sessionDirectory: String) {
        let segments = manifest.inputs.flatMap { input in input.segments.filter { $0.frames > 0 } }
        guard let earliest = segments.min(by: { $0.startHostNanos < $1.startHostNanos }) else { return nil }

        // The format covering the most frames sets the sequence, so a brief odd segment does not.
        var framesByFormat: [VideoFormat: Int] = [:]
        for segment in segments { framesByFormat[segment.format, default: 0] += segment.frames }
        let sequenceFormat = framesByFormat.max {
            ($0.value, $0.key.displayName) < ($1.value, $1.key.displayName)
        }!.key
        let rate = sequenceFormat.frameRate.doubleValue

        name = manifest.name
        format = sequenceFormat
        let earliestTimecode = Timecode(string: earliest.startTimecode, frameRate: earliest.format.frameRate)
            ?? Timecode(frameCount: 0, frameRate: earliest.format.frameRate)
        startTimecode = Timecode(frameCount: Int(Double(earliestTimecode.frameCount) * rate / earliest.format.frameRate.doubleValue), frameRate: sequenceFormat.frameRate)

        angles = manifest.inputs.compactMap { input in
            let clips: [Clip] = input.segments.filter { $0.frames > 0 }.map { segment in
                // A segment that could not be finalized is still complete and playable.
                let relative = segment.state == .finalized ? segment.finalFile : segment.workingFile
                let seconds = Double(segment.startHostNanos - earliest.startHostNanos) / 1_000_000_000
                let scale = rate / segment.format.frameRate.doubleValue
                return Clip(
                    inputLabel: input.label,
                    fileName: (relative as NSString).lastPathComponent,
                    path: (sessionDirectory as NSString).appendingPathComponent(relative),
                    format: segment.format,
                    audioChannels: segment.audioChannels,
                    frames: segment.frames,
                    startTimecode: Timecode(string: segment.startTimecode, frameRate: segment.format.frameRate)
                        ?? Timecode(frameCount: 0, frameRate: segment.format.frameRate),
                    offsetFrames: Int((seconds * rate).rounded()),
                    timelineFrames: Int((Double(segment.frames) * scale).rounded())
                )
            }
            return clips.isEmpty ? nil : (input.label, clips)
        }
        totalFrames = angles.flatMap(\.clips).map { $0.offsetFrames + $0.timelineFrames }.max() ?? 0
    }
}

public extension Timecode {
    /// Parses `HH:MM:SS:FF`, or `HH:MM:SS;FF` for drop-frame.
    init?(string: String, frameRate: Rational) {
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == ";" }).compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        self.init(
            hours: parts[0], minutes: parts[1], seconds: parts[2], frames: parts[3],
            nominalFPS: Int(frameRate.doubleValue.rounded()),
            isDropFrame: string.contains(";")
        )
    }
}

public struct ExportFile: Hashable, Sendable {
    public var name: String
    public var contents: String
}

/// Turns a plan into files NLEs can open. Each tool gets the structure it imports best:
/// a true multicam in FCPXML, stacked and aligned tracks in FCP7 XML, and one EDL per input.
public enum MulticamExporter {
    public static func files(for plan: MulticamPlan) -> [ExportFile] {
        var files = [
            ExportFile(name: "\(safeName(plan.name)).fcpxml", contents: fcpxml(plan)),
            ExportFile(name: "\(safeName(plan.name)).xml", contents: fcp7XML(plan)),
        ]
        for angle in plan.angles {
            files.append(ExportFile(name: "\(safeName(plan.name))_\(safeName(angle.label)).edl", contents: edl(plan, angle: angle)))
        }
        return files
    }

    // MARK: FCPXML

    public static func fcpxml(_ plan: MulticamPlan) -> String {
        let sequenceRate = plan.format.frameRate
        var resources: [String] = []
        var nextID = 1
        func identifier() -> String {
            defer { nextID += 1 }
            return "r\(nextID)"
        }

        var formatIDs: [VideoFormat: String] = [:]
        func formatID(_ format: VideoFormat) -> String {
            if let existing = formatIDs[format] { return existing }
            let id = identifier()
            formatIDs[format] = id
            let scan = format.scan.isInterlaced ? format.scan == .interlacedTopFieldFirst ? " fieldOrder=\"upper first\"" : " fieldOrder=\"lower first\"" : ""
            resources.append("<format id=\"\(id)\" name=\"\(escape(format.displayName))\" frameDuration=\"\(frameDuration(format.frameRate))\" width=\"\(format.width)\" height=\"\(format.height)\" colorSpace=\"1-1-1 (Rec. 709)\"\(scan)/>")
            return id
        }

        let sequenceFormatID = formatID(plan.format)
        var angleXML: [String] = []

        for angle in plan.angles {
            var items: [String] = []
            for clip in angle.clips {
                let assetID = identifier()
                let clipFormatID = formatID(clip.format)
                let start = time(clip.startTimecode.frameCount, clip.format.frameRate)
                let duration = time(clip.frames, clip.format.frameRate)
                let audio = clip.audioChannels > 0
                    ? " hasAudio=\"1\" audioSources=\"1\" audioChannels=\"\(clip.audioChannels)\" audioRate=\"48000\""
                    : ""
                resources.append("<asset id=\"\(assetID)\" name=\"\(escape(clip.fileName))\" start=\"\(start)\" duration=\"\(duration)\" hasVideo=\"1\" format=\"\(clipFormatID)\"\(audio)><media-rep kind=\"original-media\" src=\"\(escape(fileURL(clip.path)))\"/></asset>")
                let offset = time(plan.startTimecode.frameCount + clip.offsetFrames, sequenceRate)
                items.append("<asset-clip name=\"\(escape(clip.fileName))\" ref=\"\(assetID)\" offset=\"\(offset)\" start=\"\(start)\" duration=\"\(time(clip.timelineFrames, sequenceRate))\"/>")
            }
            angleXML.append("<mc-angle name=\"\(escape(angle.label))\" angleID=\"\(escape(safeName(angle.label)))\">\(items.joined())</mc-angle>")
        }

        let tcFormat = plan.startTimecode.isDropFrame ? "DF" : "NDF"
        let tcStart = time(plan.startTimecode.frameCount, sequenceRate)
        let duration = time(plan.totalFrames, sequenceRate)
        let mediaID = identifier()
        resources.append("<media id=\"\(mediaID)\" name=\"\(escape(plan.name)) Multicam\"><multicam format=\"\(sequenceFormatID)\" tcStart=\"\(tcStart)\" tcFormat=\"\(tcFormat)\">\(angleXML.joined())</multicam></media>")

        let firstAngle = escape(safeName(plan.angles.first?.label ?? ""))
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
        <resources>\(resources.joined())</resources>
        <library><event name="\(escape(plan.name))"><project name="\(escape(plan.name))"><sequence format="\(sequenceFormatID)" tcStart="\(tcStart)" tcFormat="\(tcFormat)" duration="\(duration)"><spine><mc-clip name="\(escape(plan.name)) Multicam" ref="\(mediaID)" offset="\(tcStart)" start="\(tcStart)" duration="\(duration)"><mc-source angleID="\(firstAngle)" srcEnable="all"/></mc-clip></spine></sequence></project></event></library>
        </fcpxml>

        """
    }

    private static func frameDuration(_ rate: Rational) -> String {
        "\(rate.denominator)/\(rate.numerator)s"
    }

    private static func time(_ frames: Int, _ rate: Rational) -> String {
        frames == 0 ? "0s" : "\(Int64(frames) * rate.denominator)/\(rate.numerator)s"
    }

    // MARK: FCP7 XML

    public static func fcp7XML(_ plan: MulticamPlan) -> String {
        let rate = rateXML(plan.format.frameRate)
        var fileIndex = 0
        var videoTracks: [String] = []
        var audioTracks: [String] = []

        for angle in plan.angles {
            var videoItems: [String] = []
            var audioItems: [String] = []
            for clip in angle.clips {
                fileIndex += 1
                let fileID = "file-\(fileIndex)"
                let channels = clip.audioChannels
                let clipRate = rateXML(clip.format.frameRate)
                let audioMedia = channels > 0 ? "<audio><samplecharacteristics><depth>24</depth><samplerate>48000</samplerate></samplecharacteristics><channelcount>\(channels)</channelcount></audio>" : ""
                let file = "<file id=\"\(fileID)\"><name>\(escape(clip.fileName))</name><pathurl>\(escape(localhostURL(clip.path)))</pathurl>\(clipRate)<duration>\(clip.frames)</duration><timecode>\(clipRate)<string>\(clip.startTimecode.string)</string><frame>\(clip.startTimecode.frameCount)</frame><displayformat>\(clip.startTimecode.isDropFrame ? "DF" : "NDF")</displayformat></timecode><media><video><samplecharacteristics><width>\(clip.format.width)</width><height>\(clip.format.height)</height></samplecharacteristics></video>\(audioMedia)</media></file>"
                let start = clip.offsetFrames
                let end = clip.offsetFrames + clip.timelineFrames
                let common = "<name>\(escape(clip.fileName))</name><enabled>TRUE</enabled><duration>\(clip.frames)</duration>\(clipRate)<start>\(start)</start><end>\(end)</end><in>0</in><out>\(clip.frames)</out>"
                videoItems.append("<clipitem id=\"video-\(fileID)\">\(common)\(file)</clipitem>")
                if channels > 0 {
                    audioItems.append("<clipitem id=\"audio-\(fileID)\">\(common)<file id=\"\(fileID)\"/><sourcetrack><mediatype>audio</mediatype><trackindex>1</trackindex></sourcetrack></clipitem>")
                }
            }
            videoTracks.append("<track>\(videoItems.joined())<enabled>TRUE</enabled><locked>FALSE</locked></track>")
            if !audioItems.isEmpty {
                audioTracks.append("<track>\(audioItems.joined())<enabled>TRUE</enabled><locked>FALSE</locked></track>")
            }
        }

        let format = plan.format
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="4"><sequence><name>\(escape(plan.name))</name><duration>\(plan.totalFrames)</duration>\(rate)<timecode>\(rate)<string>\(plan.startTimecode.string)</string><frame>\(plan.startTimecode.frameCount)</frame><displayformat>\(plan.startTimecode.isDropFrame ? "DF" : "NDF")</displayformat></timecode><media><video><format><samplecharacteristics>\(rate)<width>\(format.width)</width><height>\(format.height)</height><pixelaspectratio>square</pixelaspectratio><fielddominance>\(fieldDominance(format))</fielddominance></samplecharacteristics></format>\(videoTracks.joined())</video><audio>\(audioTracks.joined())</audio></media></sequence></xmeml>

        """
    }

    private static func fieldDominance(_ format: VideoFormat) -> String {
        switch format.scan {
        case .interlacedTopFieldFirst: "upper"
        case .interlacedBottomFieldFirst: "lower"
        default: "none"
        }
    }

    private static func rateXML(_ rate: Rational) -> String {
        "<rate><timebase>\(Int(rate.doubleValue.rounded()))</timebase><ntsc>\(rate.denominator == 1001 ? "TRUE" : "FALSE")</ntsc></rate>"
    }

    // MARK: EDL

    public static func edl(_ plan: MulticamPlan, angle: (label: String, clips: [MulticamPlan.Clip])) -> String {
        let drop = plan.startTimecode.isDropFrame
        var lines = ["TITLE: \(plan.name) \(angle.label)", "FCM: \(drop ? "DROP FRAME" : "NON-DROP FRAME")", ""]
        let reel = reelName(angle.label)
        for (index, clip) in angle.clips.enumerated() {
            let sourceIn = clip.startTimecode
            let sourceOut = sourceIn.advanced(by: clip.frames)
            let recordIn = plan.startTimecode.advanced(by: clip.offsetFrames)
            let recordOut = recordIn.advanced(by: clip.timelineFrames)
            lines.append(String(format: "%03d  %@ AV    C        %@ %@ %@ %@", index + 1, reel.padding(toLength: 8, withPad: " ", startingAt: 0), sourceIn.string, sourceOut.string, recordIn.string, recordOut.string))
            lines.append("* FROM CLIP NAME: \(clip.fileName)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// CMX reels are limited to eight characters.
    private static func reelName(_ label: String) -> String {
        let cleaned = label.uppercased().filter { $0.isLetter || $0.isNumber }
        return String(cleaned.suffix(8))
    }

    // MARK: Text

    private static func safeName(_ name: String) -> String {
        SessionLayout.sanitize(name)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func encodedPath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    private static func fileURL(_ path: String) -> String {
        "file://\(encodedPath(path))"
    }

    private static func localhostURL(_ path: String) -> String {
        "file://localhost\(encodedPath(path))"
    }
}
