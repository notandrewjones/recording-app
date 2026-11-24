import Foundation
import ISOCore
import os

public final class UnfairLock: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    public init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    public func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return body()
    }
}

/// Caps how much memory the rings may wire, so that several large inputs cannot pin most of the machine.
/// A quarter of RAM covers five 1080p v210 inputs, or one 2160p v210 input.
public final class MemoryLockBudget: @unchecked Sendable {
    public static let shared = MemoryLockBudget(limitBytes: Int(ProcessInfo.processInfo.physicalMemory / 4))

    public let limitBytes: Int
    private let lock = UnfairLock()
    private var used = 0

    public init(limitBytes: Int) {
        self.limitBytes = limitBytes
    }

    public var usedBytes: Int { lock.withLock { used } }

    func reserve(_ bytes: Int) -> Bool {
        lock.withLock {
            guard used + bytes <= limitBytes else { return false }
            used += bytes
            return true
        }
    }

    func release(_ bytes: Int) {
        lock.withLock { used -= bytes }
    }
}

/// Memory that capture writes into in real time, mapped on its own and wired into RAM when the budget allows.
/// Under memory pressure macOS compresses or swaps unwired pages, and then every copy in or out waits on the
/// pager: on an 8 GB Mac that stalled capture and ffmpeg.
public final class WiredBuffer: @unchecked Sendable {
    public enum MemoryLock: Hashable, Sendable, CustomStringConvertible {
        case locked
        case overBudget
        case failed(errno: Int32)

        public var description: String {
            switch self {
            case .locked: "locked"
            case .overBudget: "not locked: over the memory lock budget"
            case .failed(let code): "not locked: \(String(cString: strerror(code)))"
            }
        }
    }

    public let pointer: UnsafeMutableRawPointer
    public let bytes: Int
    public let memoryLock: MemoryLock
    private let budget: MemoryLockBudget

    public init(bytes: Int, budget: MemoryLockBudget) {
        self.bytes = bytes
        self.budget = budget
        // Its own mapping, so locking and unlocking it touches no page another allocation shares.
        let mapped = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        precondition(mapped != MAP_FAILED, "Could not map \(bytes) bytes")
        pointer = mapped!

        if !budget.reserve(bytes) {
            memoryLock = .overBudget
        } else if mlock(pointer, bytes) == 0 {
            // Wiring faults every page in, so nothing is left to fault on the capture thread.
            memoryLock = .locked
        } else {
            memoryLock = .failed(errno: errno)
            budget.release(bytes)
        }
        if memoryLock != .locked {
            // Touch every page now, so the capture thread never takes a page fault on its first pass.
            memset(pointer, 0, bytes)
        }
    }

    deinit {
        if memoryLock == .locked {
            munlock(pointer, bytes)
            budget.release(bytes)
        }
        munmap(pointer, bytes)
    }
}

/// Fixed-memory video ring between the capture thread and one writer thread.
///
/// It holds pictures only. Audio has its own buffer, `AudioTimeline`, because ffmpeg will not read video
/// more than a moment ahead of audio: if audio could only arrive once the ring had room, a full ring would
/// starve ffmpeg of the audio it waits for, and nothing would move again (2026-11-22).
///
/// Every frame offered gets a number on the input's frame timeline, `Metadata.timelineFrame`, whether the ring
/// keeps it or drops it, and frames the card never delivered take numbers too. Audio is placed on the same
/// timeline, which is what keeps it in step with a file that repeats frames to fill gaps.
///
/// The newest frame the reader has passed stays intact, which is what the writer repeats to fill a drop.
/// The ring outlives a recorder crash: a new segment resumes from the first frame not yet written.
public final class FrameRing: @unchecked Sendable {
    public typealias MemoryLock = WiredBuffer.MemoryLock

    public struct Metadata {
        public var hostTimeNanos: UInt64
        public var streamTime: Int64
        public var timecode: Timecode?
        public var noSignal = false
        /// This frame's place on the input's frame timeline. Set by `push`.
        public var timelineFrame: UInt64 = 0

        public init(hostTimeNanos: UInt64, streamTime: Int64, timecode: Timecode?) {
            self.hostTimeNanos = hostTimeNanos
            self.streamTime = streamTime
            self.timecode = timecode
        }
    }

    public struct Entry {
        public var video: UnsafeRawPointer
        /// Frames lost immediately before this one.
        public var missingBefore: Int
        public var metadata: Metadata
    }

    public struct PushResult {
        /// False when the ring was full or closed. The frame is then counted as missing.
        public var accepted: Bool
        /// The frame's number on the timeline, assigned whether or not it was kept.
        public var timelineFrame: UInt64
    }

    public enum ReadResult {
        case entry(Entry)
        case timedOut
        case closed
    }

    public let format: VideoFormat
    public let slotCount: Int

    public var memoryLock: MemoryLock { buffer.memoryLock }
    public var storageBytes: Int { buffer.bytes }
    private let buffer: WiredBuffer
    private let slotBytes: Int
    private var metadata: [Metadata]
    private var missingCounts: [Int]

    private let lock = UnfairLock()
    private var head: UInt64 = 0
    private var tail: UInt64 = 0
    private var closed = false
    private var pendingMissing = 0
    private var nextTimelineFrame: UInt64 = 0
    private let wakeup = DispatchSemaphore(value: 0)

    public init(format: VideoFormat, slotCount: Int, budget: MemoryLockBudget = .shared) {
        precondition(slotCount >= 3, "A ring needs room for a held frame and two in flight")
        self.format = format
        self.slotCount = slotCount
        slotBytes = format.frameBytes
        let placeholder = Metadata(hostTimeNanos: 0, streamTime: 0, timecode: nil)
        metadata = Array(repeating: placeholder, count: slotCount)
        missingCounts = Array(repeating: 0, count: slotCount)
        buffer = WiredBuffer(bytes: slotBytes * slotCount, budget: budget)
    }

    private func slotPointer(_ position: UInt64) -> UnsafeMutableRawPointer {
        buffer.pointer.advanced(by: Int(position % UInt64(slotCount)) * slotBytes)
    }

    /// Capture thread. A frame the ring has no room for is counted as missing, and the writer repeats the
    /// previous frame in its place.
    @discardableResult
    public func push(video: UnsafeRawPointer, metadata entry: Metadata) -> PushResult {
        let (reservation, timelineFrame): (UInt64?, UInt64) = lock.withLock {
            let frame = nextTimelineFrame
            nextTimelineFrame += 1
            guard !closed else { return (nil, frame) }
            // One slot stays back so the previous frame survives for repeating.
            guard head - tail < UInt64(slotCount - 1) else {
                pendingMissing += 1
                return (nil, frame)
            }
            return (head, frame)
        }
        guard let position = reservation else { return PushResult(accepted: false, timelineFrame: timelineFrame) }

        slotPointer(position).copyMemory(from: video, byteCount: format.frameBytes)

        let index = Int(position % UInt64(slotCount))
        var stamped = entry
        stamped.timelineFrame = timelineFrame
        lock.withLock {
            metadata[index] = stamped
            missingCounts[index] = pendingMissing
            pendingMissing = 0
            head = position + 1
        }
        wakeup.signal()
        return PushResult(accepted: true, timelineFrame: timelineFrame)
    }

    /// Capture thread. Records frames the source never delivered, so the next frame carries the gap and the
    /// timeline keeps a place for each of them.
    public func markMissing(_ count: Int) {
        guard count > 0 else { return }
        lock.withLock {
            pendingMissing += count
            nextTimelineFrame += UInt64(count)
        }
    }

    /// Writer thread. Returns the next unread frame without consuming it.
    public func next(timeout: TimeInterval) -> ReadResult {
        let deadline = DispatchTime.now() + timeout
        while true {
            let result: ReadResult? = lock.withLock {
                if tail < head {
                    let index = Int(tail % UInt64(slotCount))
                    return .entry(Entry(video: UnsafeRawPointer(slotPointer(tail)), missingBefore: missingCounts[index], metadata: metadata[index]))
                }
                return closed ? .closed : nil
            }
            if let result { return result }
            if wakeup.wait(timeout: deadline) == .timedOut { return .timedOut }
        }
    }

    public func advance() {
        lock.withLock { tail += 1 }
    }

    /// The frame most recently passed by the reader, for repeating into a gap.
    public var previousVideoFrame: UnsafeRawPointer? {
        lock.withLock {
            tail == 0 ? nil : UnsafeRawPointer(slotPointer(tail - 1))
        }
    }

    public func close() {
        lock.withLock { closed = true }
        wakeup.signal()
    }

    public var isClosed: Bool { lock.withLock { closed } }

    /// How much of the ring is occupied, from 0 to 1. Rising fill is the first sign of an encoder falling behind.
    public var fillLevel: Double {
        lock.withLock { Double(head - tail) / Double(slotCount - 1) }
    }

    public var queuedFrames: Int {
        lock.withLock { Int(head - tail) }
    }
}
