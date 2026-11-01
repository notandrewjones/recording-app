import Foundation

/// The `session.json` sidecar: what was recorded and how the files line up.
public struct SessionManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = SessionManifest.currentSchemaVersion
    public var name: String
    public var createdAt: Date
    /// Host time when the session was created. Host times in this file share this clock.
    public var createdAtHostNanos: UInt64
    public var inputs: [InputRecord] = []
    public var markers: [Marker] = []

    public init(name: String, createdAt: Date, createdAtHostNanos: UInt64) {
        self.name = name
        self.createdAt = createdAt
        self.createdAtHostNanos = createdAtHostNanos
    }

    public struct InputRecord: Codable, Hashable, Sendable {
        public var id: String
        public var label: String
        public var segments: [SegmentRecord] = []
        public var events: [Event] = []

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public enum SegmentState: String, Codable, Sendable {
        case recording
        case closed
        case finalized
        case finalizeFailed
    }

    public enum EndReason: String, Codable, Sendable {
        case stopped
        case signalLost
        case formatChanged
        case discontinuity
        case recorderFailed
        case appInterrupted
        case diskFull
    }

    public struct SegmentRecord: Codable, Hashable, Sendable {
        public var number: Int
        public var workingFile: String
        public var finalFile: String
        public var indexFile: String
        public var logFile: String
        public var format: VideoFormat
        public var codec: Codec
        public var audioChannels: Int
        public var startTimecode: String
        public var timecodeIsEmbedded: Bool
        public var startHostNanos: UInt64
        public var frames: Int = 0
        public var repeatedFrames: Int = 0
        /// Frames handed to ffmpeg that never reached the file, which is only non-zero after a crash.
        public var lostFrames: Int = 0
        public var state: SegmentState = .recording
        public var endReason: EndReason?

        public init(number: Int, workingFile: String, finalFile: String, indexFile: String, logFile: String, format: VideoFormat, codec: Codec, audioChannels: Int, startTimecode: String, timecodeIsEmbedded: Bool, startHostNanos: UInt64) {
            self.number = number
            self.workingFile = workingFile
            self.finalFile = finalFile
            self.indexFile = indexFile
            self.logFile = logFile
            self.format = format
            self.codec = codec
            self.audioChannels = audioChannels
            self.startTimecode = startTimecode
            self.timecodeIsEmbedded = timecodeIsEmbedded
            self.startHostNanos = startHostNanos
        }
    }

    public struct Event: Codable, Hashable, Sendable {
        public var hostNanos: UInt64
        public var kind: String
        public var detail: String?

        public init(hostNanos: UInt64, kind: String, detail: String? = nil) {
            self.hostNanos = hostNanos
            self.kind = kind
            self.detail = detail
        }
    }

    public struct Marker: Codable, Hashable, Sendable {
        public var hostNanos: UInt64
        public var label: String

        public init(hostNanos: UInt64, label: String) {
            self.hostNanos = hostNanos
            self.label = label
        }
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
