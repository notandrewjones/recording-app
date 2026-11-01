import Foundation
import ISOCore
import os

/// Latest-frame mailbox between one capture thread and one renderer.
/// Status and pixels have separate locks. The status lock is only held for a few field writes, so
/// counts stay exact, while the pixel copy uses try-lock so preview load can never delay capture.
final class PreviewFrameStore: @unchecked Sendable {
    struct Status {
        var signal: SignalState = .unknown
        var timecode: Timecode?
        var framesReceived: UInt64 = 0
    }

    private var statusLock = os_unfair_lock()
    private var status = Status()

    private var frameLock = os_unfair_lock()
    private var buffer: UnsafeMutableRawPointer?
    private var capacity = 0
    private var format: VideoFormat?
    private var hasUnreadFrame = false

    deinit { buffer?.deallocate() }

    /// Capture thread. Skips the pixel copy if the renderer holds the frame or has not caught up.
    func offer(format: VideoFormat, bytes: UnsafeRawPointer, timecode: Timecode?, hasSignal: Bool) {
        os_unfair_lock_lock(&statusLock)
        status.framesReceived += 1
        status.timecode = timecode
        status.signal = hasSignal ? .locked(format) : .noSignal
        os_unfair_lock_unlock(&statusLock)

        guard os_unfair_lock_trylock(&frameLock) else { return }
        defer { os_unfair_lock_unlock(&frameLock) }
        guard !hasUnreadFrame else { return }
        if capacity < format.frameBytes {
            buffer?.deallocate()
            buffer = UnsafeMutableRawPointer.allocate(byteCount: format.frameBytes, alignment: 64)
            capacity = format.frameBytes
        }
        buffer!.copyMemory(from: bytes, byteCount: format.frameBytes)
        self.format = format
        hasUnreadFrame = true
    }

    /// Renderer thread. Calls `body` with the newest unread frame, if there is one.
    func consume(_ body: (VideoFormat, UnsafeRawPointer) -> Void) {
        os_unfair_lock_lock(&frameLock)
        defer { os_unfair_lock_unlock(&frameLock) }
        guard hasUnreadFrame, let buffer, let format else { return }
        body(format, buffer)
        hasUnreadFrame = false
    }

    func snapshot() -> Status {
        os_unfair_lock_lock(&statusLock)
        defer { os_unfair_lock_unlock(&statusLock) }
        return status
    }
}
