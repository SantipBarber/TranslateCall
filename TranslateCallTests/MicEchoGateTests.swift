import AVFoundation
import Testing
@testable import TranslateCall

private func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
    guard let data = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

@Suite("MicEchoGate")
struct MicEchoGateTests {

    @Test("headphones: every buffer passes through untouched, even while incoming speaks (REQ-H-02)")
    func headphonesPassThrough() {
        let gate = MicEchoGate(mode: .headphones, clock: TestClock())
        gate.setIncomingSpeaking(true)
        let buffer = makePCMBuffer(frames: 1_024, fill: 0.5)
        #expect(gate.process(buffer) === buffer)
        #expect(!gate.isMicPaused)
    }

    @Test("speakers: while incoming speaks a buffer becomes zeros of the same format and length (REQ-H-03/04)")
    func speakersMutesWhileIncoming() {
        let gate = MicEchoGate(mode: .speakers, clock: TestClock())
        gate.setIncomingSpeaking(true)
        let buffer = makePCMBuffer(frames: 1_024, fill: 0.5)

        let out = gate.process(buffer)

        #expect(out !== buffer)
        #expect(out.format == buffer.format)
        #expect(out.frameLength == buffer.frameLength)
        #expect(samples(of: out).allSatisfy { $0 == 0 })
        #expect(samples(of: buffer).allSatisfy { $0 == 0.5 }, "the captured buffer must not be modified")
        #expect(gate.isMicPaused)
    }

    @Test("speakers: muted for the 300 ms tail after incoming stops, open from then on (REQ-H-03/07)")
    func tailKeepsMutedThenReopens() {
        let clock = TestClock()
        let gate = MicEchoGate(mode: .speakers, clock: clock)
        let buffer = makePCMBuffer(frames: 160, fill: 0.5)
        gate.setIncomingSpeaking(true)
        gate.setIncomingSpeaking(false)

        clock.advance(by: .milliseconds(299))
        #expect(gate.process(buffer) !== buffer)
        clock.advance(by: .milliseconds(1))
        #expect(gate.process(buffer) === buffer)
        #expect(!gate.isMicPaused)
    }

    @Test("Review focus: a 'not speaking' report without a preceding 'speaking' never mutes the mic")
    func falseWithoutTrueDoesNotMute() {
        let gate = MicEchoGate(mode: .speakers, clock: TestClock())
        gate.setIncomingSpeaking(false)
        let buffer = makePCMBuffer(frames: 160, fill: 0.5)
        #expect(gate.process(buffer) === buffer)
    }

    @Test("Review focus: switching to headphones while muted reopens at once and reports it (REQ-H-05)")
    func switchToHeadphonesReopens() {
        let reports = LockedArray<Bool>()
        let gate = MicEchoGate(mode: .speakers, clock: TestClock()) { reports.append($0) }
        gate.setIncomingSpeaking(true)
        let buffer = makePCMBuffer(frames: 160, fill: 0.5)
        _ = gate.process(buffer)

        gate.setMode(.headphones)

        #expect(!gate.isMicPaused)
        #expect(reports.values == [true, false])
        #expect(gate.process(buffer) === buffer)
        gate.setMode(.speakers)
        #expect(gate.process(buffer) !== buffer, "incoming is still speaking")
    }

    @Test("Review focus: reset (incoming torn down) reopens at once, without the tail (REQ-H-06)")
    func resetReopens() {
        let reports = LockedArray<Bool>()
        let gate = MicEchoGate(mode: .speakers, clock: TestClock()) { reports.append($0) }
        gate.setIncomingSpeaking(true)
        let buffer = makePCMBuffer(frames: 160, fill: 0.5)
        _ = gate.process(buffer)

        gate.reset()

        #expect(reports.values == [true, false])
        #expect(gate.process(buffer) === buffer)
    }

    @Test("paused changes are reported once per transition")
    func pausedChangeReportedOnTransitions() {
        let clock = TestClock()
        let reports = LockedArray<Bool>()
        let gate = MicEchoGate(mode: .speakers, clock: clock) { reports.append($0) }
        let buffer = makePCMBuffer(frames: 160, fill: 0.5)
        _ = gate.process(buffer)
        gate.setIncomingSpeaking(true)
        _ = gate.process(buffer)
        _ = gate.process(buffer)
        gate.setIncomingSpeaking(false)
        clock.advance(by: .milliseconds(300))
        _ = gate.process(buffer)
        _ = gate.process(buffer)
        #expect(reports.values == [true, false])
    }

    @Test("the gated stream keeps every buffer, in order, and finishes with its input (REQ-H-04)")
    func neverDropsOrReorders() async {
        for mode in ListeningMode.allCases {
            let gate = MicEchoGate(mode: mode, clock: TestClock())
            gate.setIncomingSpeaking(true)
            let (input, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self,
                                                               bufferingPolicy: .bufferingNewest(64))
            let sent = (1...10).map { makePCMBuffer(frames: AVAudioFrameCount(100 + $0), fill: 0.5) }
            sent.forEach { continuation.yield($0) }
            continuation.finish()

            var received: [AVAudioPCMBuffer] = []
            for await buffer in gate.gate(input) { received.append(buffer) }

            #expect(received.map(\.frameLength) == sent.map(\.frameLength))
            let silenced = received.allSatisfy { samples(of: $0).allSatisfy { $0 == 0 } }
            #expect(silenced == (mode == .speakers))
        }
    }
}

@Suite("ConversationState")
struct ConversationStateTests {
    @Test("mic paused wins, then any translation playing, else listening (REQ-H-13)")
    func derivation() {
        for paused in [false, true] {
            for outgoing in [false, true] {
                for incoming in [false, true] {
                    let state = ConversationState.derive(micPaused: paused, outgoingSpeaking: outgoing,
                                                         incomingSpeaking: incoming)
                    let expected: ConversationState = paused ? .micPaused
                        : (outgoing || incoming ? .speaking : .listening)
                    #expect(state == expected, "paused \(paused) outgoing \(outgoing) incoming \(incoming)")
                }
            }
        }
    }
}
