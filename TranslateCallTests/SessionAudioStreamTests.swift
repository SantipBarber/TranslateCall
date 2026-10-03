import AVFoundation
import Testing
@testable import TranslateCall

@Suite("SessionAudioStream")
struct SessionAudioStreamTests {

    @Test("finish ends iteration after delivering pending buffers")
    func finishEndsIteration() async {
        let session = SessionAudioStream(label: "test")
        session.yield(makePCMBuffer())
        session.finish()
        var count = 0
        for await _ in session.stream { count += 1 }
        #expect(count == 1)
    }

    @Test("overflow keeps the newest 64 buffers and counts the dropped ones")
    func overflowDropsOldest() async {
        let session = SessionAudioStream(label: "test")
        for i in 1...70 { session.yield(makePCMBuffer(frames: AVAudioFrameCount(i))) }
        session.finish()
        var lengths: [AVAudioFrameCount] = []
        for await buffer in session.stream { lengths.append(buffer.frameLength) }
        #expect(lengths.count == 64)
        #expect(lengths.first == 7)
        #expect(lengths.last == 70)
        #expect(session.droppedCount == 6)
    }

    @Test("finish twice and yield after finish are safe and not counted as drops")
    func finishIsIdempotent() async {
        let session = SessionAudioStream(label: "test")
        session.finish()
        session.finish()
        session.yield(makePCMBuffer())
        var count = 0
        for await _ in session.stream { count += 1 }
        #expect(count == 0)
        #expect(session.droppedCount == 0)
    }
}
