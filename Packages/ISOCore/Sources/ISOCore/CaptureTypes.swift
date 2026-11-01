import Foundation

/// Hardware and driver facts for one capture path, independent of the DeckLink SDK.
public struct CaptureInput: Identifiable, Hashable, Sendable {
    /// Stable across reboots and re-plugging where the hardware provides a persistent ID.
    public var id: String
    public var displayName: String
    public var maxAudioChannels: Int
    public var supportsFormatDetection: Bool
    public var isSynthetic: Bool

    public init(id: String, displayName: String, maxAudioChannels: Int, supportsFormatDetection: Bool, isSynthetic: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.maxAudioChannels = maxAudioChannels
        self.supportsFormatDetection = supportsFormatDetection
        self.isSynthetic = isSynthetic
    }
}

public enum SignalState: Hashable, Sendable {
    case unknown
    case noSignal
    case locked(VideoFormat)

    public var format: VideoFormat? {
        if case .locked(let format) = self { return format }
        return nil
    }
}
