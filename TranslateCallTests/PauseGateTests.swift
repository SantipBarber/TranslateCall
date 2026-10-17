import AVFoundation
import Testing
@testable import TranslateCall

private func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
    guard let data = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

@Suite("PauseGate (M9 UI core D-5)")
struct PauseGateTests {

    @Test("running: buffers pass through untouched")
    func passThrough() {
        let gate = PauseGate()
        let buffer = makePCMBuffer(frames: 480, fill: 0.5)
        #expect(gate.process(buffer) === buffer)
        #expect(!gate.isPaused)
    }

    @Test("paused: zeros of the same format and length; the captured buffer is not modified (REQ-UI-50)")
    func pausedSilences() {
        let gate = PauseGate()
        gate.setPaused(true)
        let buffer = makePCMBuffer(frames: 480, sampleRate: 48_000, fill: 0.5)
        let out = gate.process(buffer)
        #expect(out !== buffer)
        #expect(out.format == buffer.format)
        #expect(out.frameLength == buffer.frameLength)
        #expect(samples(of: out).allSatisfy { $0 == 0 })
        #expect(samples(of: buffer).allSatisfy { $0 == 0.5 })
    }

    @Test("resume takes effect from the next buffer (REQ-UI-51)")
    func resumeNextBuffer() {
        let gate = PauseGate()
        gate.setPaused(true)
        #expect(samples(of: gate.process(makePCMBuffer(fill: 0.5))).allSatisfy { $0 == 0 })
        gate.setPaused(false)
        let next = makePCMBuffer(fill: 0.5)
        #expect(gate.process(next) === next)
    }

    @Test("the gated stream keeps every buffer, each gated by the state when it arrives, and finishes with its input")
    func streamKeepsEveryBuffer() async {
        let gate = PauseGate()
        let (input, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        var output = gate.gate(input, label: "test").makeAsyncIterator()

        continuation.yield(makePCMBuffer(fill: 0.5))
        let first = await output.next()
        gate.setPaused(true)
        continuation.yield(makePCMBuffer(fill: 0.5))
        let second = await output.next()
        continuation.finish()
        let end = await output.next()

        #expect(first.map { samples(of: $0).allSatisfy { $0 == 0.5 } } == true, "running: passed through")
        #expect(second.map { samples(of: $0).allSatisfy { $0 == 0 } } == true, "paused: silenced")
        #expect(end == nil)
    }
}
