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

/// Fixed-memory ring between one capture thread and two writer threads, one each for video and audio.
///
/// Readers advance independently, so a slow audio socket does not hold up video until the ring fills.
/// The newest frame a reader has passed stays intact, which is what the video writer repeats to fill a drop.
/// The ring outlives a recorder crash: a new segment resumes from the first frame not yet written.
public final class FrameRing: @unchecked Sendable {
    public enum Reader: Int {
        case video = 0
        case audio = 1
    }

    public struct Metadata {
        public var hostTimeNanos: UInt64
        public var streamTime: Int64
        public var timecode: Timecode?
        public var noSignal = false

        public init(hostTimeNanos: UInt64, streamTime: Int64, timecode: Timecode?) {
            self.hostTimeNanos = hostTimeNanos
            self.streamTime = streamTime
            self.timecode = timecode
        }
    }

    public struct Entry {
        public var video: UnsafeRawPointer
        public var audio: UnsafeRawPointer
        public var audioBytes: Int
        /// Frames lost immediately before this one.
        public var missingBefore: Int
        public var metadata: Metadata
    }

    public enum ReadResult {
        case entry(Entry)
        case timedOut
        case closed
    }

    /// Whether the ring is wired into RAM. Under memory pressure macOS compresses or swaps unwired pages, and
    /// then every frame copied in or out waits on the pager: on an 8 GB Mac that stalled capture and ffmpeg.
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

    public let format: VideoFormat
    public let slotCount: Int
    public let audioSlotBytes: Int

    public let memoryLock: MemoryLock
    public let storageBytes: Int
    private let storage: UnsafeMutableRawPointer
    private let slotBytes: Int
    private let budget: MemoryLockBudget
    private var metadata: [Metadata]
    private var audioByteCounts: [Int]
    private var missingCounts: [Int]

    private let lock = UnfairLock()
    private var head: UInt64 = 0
    private var tails: [UInt64] = [0, 0]
    private var closed = false
    private var pendingMissing = 0
    private let wakeups = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]

    public init(format: VideoFormat, slotCount: Int, audioSlotBytes: Int, budget: MemoryLockBudget = .shared) {
        precondition(slotCount >= 3, "A ring needs room for a held frame and two in flight")
        self.format = format
        self.slotCount = slotCount
        self.audioSlotBytes = audioSlotBytes
        slotBytes = format.frameBytes + audioSlotBytes
        let placeholder = Metadata(hostTimeNanos: 0, streamTime: 0, timecode: nil)
        metadata = Array(repeating: placeholder, count: slotCount)
        audioByteCounts = Array(repeating: 0, count: slotCount)
        missingCounts = Array(repeating: 0, count: slotCount)
        self.budget = budget
        storageBytes = slotBytes * slotCount
        // Its own mapping, so locking and unlocking it touches no page another allocation shares.
        let mapped = mmap(nil, storageBytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        precondition(mapped != MAP_FAILED, "Could not map \(storageBytes) bytes for a frame ring")
        storage = mapped!

        if !budget.reserve(storageBytes) {
            memoryLock = .overBudget
        } else if mlock(storage, storageBytes) == 0 {
            // Wiring faults every page in, so nothing is left to fault on the capture thread.
            memoryLock = .locked
        } else {
            memoryLock = .failed(errno: errno)
            budget.release(storageBytes)
        }
        if memoryLock != .locked {
            // Touch every page now, so the capture thread never takes a page fault on its first pass.
            memset(storage, 0, storageBytes)
        }
    }

    deinit {
        if memoryLock == .locked {
            munlock(storage, storageBytes)
            budget.release(storageBytes)
        }
        munmap(storage, storageBytes)
    }

    private func slotPointer(_ position: UInt64) -> UnsafeMutableRawPointer {
        storage.advanced(by: Int(position % UInt64(slotCount)) * slotBytes)
    }

    /// Capture thread. Returns false when the ring is full, and the frame is then counted as missing.
    @discardableResult
    public func push(video: UnsafeRawPointer, audio: UnsafeRawPointer?, audioBytes: Int, metadata entry: Metadata) -> Bool {
        let reservation: UInt64? = lock.withLock {
            guard !closed else { return nil }
            let oldest = min(tails[0], tails[1])
            // One slot stays back so the previous frame survives for repeating.
            guard head - oldest < UInt64(slotCount - 1) else {
                pendingMissing += 1
                return nil
            }
            return head
        }
        guard let position = reservation else { return false }

        let slot = slotPointer(position)
        slot.copyMemory(from: video, byteCount: format.frameBytes)
        let audioCount = min(audioBytes, audioSlotBytes)
        let audioSlot = slot.advanced(by: format.frameBytes)
        if let audio {
            audioSlot.copyMemory(from: audio, byteCount: audioCount)
        } else {
            memset(audioSlot, 0, audioCount)
        }

        let index = Int(position % UInt64(slotCount))
        lock.withLock {
            metadata[index] = entry
            audioByteCounts[index] = audioCount
            missingCounts[index] = pendingMissing
            pendingMissing = 0
            head = position + 1
        }
        wakeups[0].signal()
        wakeups[1].signal()
        return true
    }

    /// Capture thread. Records frames the source never delivered, so the next frame carries the gap.
    public func markMissing(_ count: Int) {
        lock.withLock { pendingMissing += count }
    }

    /// Writer thread. Returns the next unread frame without consuming it.
    public func next(_ reader: Reader, timeout: TimeInterval) -> ReadResult {
        let deadline = DispatchTime.now() + timeout
        while true {
            let result: ReadResult? = lock.withLock {
                let tail = tails[reader.rawValue]
                if tail < head {
                    let index = Int(tail % UInt64(slotCount))
                    let slot = slotPointer(tail)
                    return .entry(Entry(
                        video: UnsafeRawPointer(slot),
                        audio: UnsafeRawPointer(slot.advanced(by: format.frameBytes)),
                        audioBytes: audioByteCounts[index],
                        missingBefore: missingCounts[index],
                        metadata: metadata[index]
                    ))
                }
                return closed ? .closed : nil
            }
            if let result { return result }
            if wakeups[reader.rawValue].wait(timeout: deadline) == .timedOut { return .timedOut }
        }
    }

    public func advance(_ reader: Reader) {
        lock.withLock { tails[reader.rawValue] += 1 }
    }

    /// The frame most recently passed by the video reader, for repeating into a gap.
    public var previousVideoFrame: UnsafeRawPointer? {
        lock.withLock {
            tails[0] == 0 ? nil : UnsafeRawPointer(slotPointer(tails[0] - 1))
        }
    }

    /// Lines audio up with video after a crash, when the readers will have stopped at different frames.
    public func alignAudioToVideo() {
        lock.withLock { tails[1] = tails[0] }
    }

    public func close() {
        lock.withLock { closed = true }
        wakeups[0].signal()
        wakeups[1].signal()
    }

    public var isClosed: Bool { lock.withLock { closed } }

    /// How much of the ring is occupied, from 0 to 1. Rising fill is the first sign of an encoder falling behind.
    public var fillLevel: Double {
        lock.withLock { Double(head - min(tails[0], tails[1])) / Double(slotCount - 1) }
    }

    public var queuedFrames: Int {
        lock.withLock { Int(head - tails[0]) }
    }
}
