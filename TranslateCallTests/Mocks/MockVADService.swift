import AVFoundation
@testable import TranslateCall

/// Test double for `VADService`. Records calls and lets tests inject speech segments.
actor MockVADService: VADService {
    nonisolated let engine: VADEngine

    // Streams
    nonisolated let speechSegments: AsyncStream<SpeechSegment>
    nonisolated let vadStateEvents: AsyncStream<Bool>

    private var speechContinuation: AsyncStream<SpeechSegment>.Continuation?
    private var stateContinuation: AsyncStream<Bool>.Continuation?

    // Call tracking
    private(set) var activateCount = 0
    var activateCalled: Bool { activateCount > 0 }
    var deactivateCalled = false
    var throwOnActivate: Error?
    private(set) var receivedBufferCount = 0
    /// Largest absolute sample of each received buffer, in order (0 = a silenced buffer).
    private(set) var receivedPeaks: [Float] = []
    private var consumeTask: Task<Void, Never>?

    private var holdActivation = false
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var isWaitingAtGate = false

    init(engine: VADEngine = .energy) {
        self.engine = engine
        var speechCont: AsyncStream<SpeechSegment>.Continuation?
        var stateCont: AsyncStream<Bool>.Continuation?
        speechSegments = AsyncStream { speechCont = $0 }
        vadStateEvents = AsyncStream { stateCont = $0 }
        speechContinuation = speechCont
        stateContinuation = stateCont
    }

    /// The next `activate` suspends until `releaseActivation()` (e.g. a slow model load).
    func holdNextActivation() { holdActivation = true }
    func releaseActivation() { gate?.resume(); gate = nil }

    func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws {
        if holdActivation {
            holdActivation = false
            isWaitingAtGate = true
            await withCheckedContinuation { gate = $0 }
            isWaitingAtGate = false
        }
        if let error = throwOnActivate { throw error }
        activateCount += 1
        consumeTask = Task {
            for await buffer in stream {
                receivedBufferCount += 1
                receivedPeaks.append(Self.peak(of: buffer))
            }
        }
    }

    func deactivate() async {
        deactivateCalled = true
        consumeTask?.cancel()
        consumeTask = nil
        speechContinuation?.finish()
        stateContinuation?.finish()
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(data[$1])) }
    }

    /// Inject a speech segment into the stream (for driving downstream STT in tests).
    func injectSpeechSegment(_ segment: SpeechSegment) {
        speechContinuation?.yield(segment)
    }
}
