import Foundation
import ISOCore
import Testing
@testable import ISOEngine

@Suite struct FrameRingTests {
    let format = VideoFormat(width: 48, height: 2, frameRate: Rational(50, 1))

    func ring(slots: Int = 4) -> FrameRing {
        FrameRing(format: format, slotCount: slots, audioSlotBytes: 16)
    }

    func frame(_ value: UInt8) -> [UInt8] {
        Array(repeating: value, count: format.frameBytes)
    }

    func metadata() -> FrameRing.Metadata {
        FrameRing.Metadata(hostTimeNanos: 1, streamTime: 2, timecode: nil)
    }

    @discardableResult
    func push(_ ring: FrameRing, _ value: UInt8) -> Bool {
        ring.push(video: frame(value), audio: nil, audioBytes: 16, metadata: metadata())
    }

    func entry(_ ring: FrameRing, _ reader: FrameRing.Reader) -> FrameRing.Entry? {
        if case .entry(let entry) = ring.next(reader, timeout: 0) { return entry }
        return nil
    }

    func firstByte(_ entry: FrameRing.Entry?) -> UInt8? {
        entry?.video.load(as: UInt8.self)
    }

    @Test func deliversInOrderToBothReaders() {
        let ring = ring()
        push(ring, 1)
        push(ring, 2)
        #expect(firstByte(entry(ring, .video)) == 1)
        ring.advance(.video)
        #expect(firstByte(entry(ring, .video)) == 2)
        #expect(firstByte(entry(ring, .audio)) == 1)
    }

    @Test func overflowIsCarriedOnTheNextFrame() {
        let ring = ring(slots: 4)
        #expect(push(ring, 1))
        #expect(push(ring, 2))
        #expect(push(ring, 3))
        #expect(!push(ring, 4))
        #expect(!push(ring, 5))
        ring.advance(.video)
        ring.advance(.audio)
        #expect(push(ring, 6))
        ring.advance(.video)
        ring.advance(.audio)
        ring.advance(.video)
        ring.advance(.audio)
        #expect(entry(ring, .video)?.missingBefore == 2)
    }

    @Test func slowestReaderHoldsTheRing() {
        let ring = ring(slots: 4)
        push(ring, 1)
        push(ring, 2)
        push(ring, 3)
        ring.advance(.video)
        ring.advance(.video)
        ring.advance(.video)
        #expect(!push(ring, 4))
    }

    @Test func previousFrameSurvivesWhileTheRingRefills() {
        let ring = ring(slots: 4)
        push(ring, 1)
        ring.advance(.video)
        ring.advance(.audio)
        #expect(push(ring, 2))
        #expect(push(ring, 3))
        #expect(push(ring, 4))
        #expect(!push(ring, 5))
        #expect(ring.previousVideoFrame?.load(as: UInt8.self) == 1)
    }

    @Test func missingFramesAttachToTheNextFrame() {
        let ring = ring()
        ring.markMissing(3)
        push(ring, 1)
        #expect(entry(ring, .video)?.missingBefore == 3)
    }

    @Test func closeDrainsBeforeReportingClosed() {
        let ring = ring()
        push(ring, 1)
        ring.close()
        #expect(firstByte(entry(ring, .video)) == 1)
        ring.advance(.video)
        if case .closed = ring.next(.video, timeout: 0) {} else { Issue.record("expected closed") }
    }

    @Test func alignsAudioToVideoAfterACrash() {
        let ring = ring()
        push(ring, 1)
        push(ring, 2)
        ring.advance(.video)
        ring.alignAudioToVideo()
        #expect(firstByte(entry(ring, .audio)) == 2)
    }

    @Test func emptyRingTimesOut() {
        if case .timedOut = ring().next(.video, timeout: 0.01) {} else { Issue.record("expected timeout") }
    }

    @Test func ringIsWiredIntoMemory() {
        let budget = MemoryLockBudget(limitBytes: 1 << 30)
        var ring: FrameRing? = FrameRing(format: format, slotCount: 4, audioSlotBytes: 16, budget: budget)
        #expect(ring?.memoryLock == .locked)
        #expect(budget.usedBytes == ring?.storageBytes)
        ring = nil
        #expect(budget.usedBytes == 0)
    }

    @Test func ringOverBudgetStillWorksUnlocked() {
        let budget = MemoryLockBudget(limitBytes: 16)
        let ring = FrameRing(format: format, slotCount: 4, audioSlotBytes: 16, budget: budget)
        #expect(ring.memoryLock == .overBudget)
        #expect(budget.usedBytes == 0)
        push(ring, 7)
        #expect(firstByte(entry(ring, .video)) == 7)
    }
}
