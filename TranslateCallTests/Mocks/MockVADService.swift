import AVFoundation
@testable import TranslateCall

/// Test double for `VADService`. Records calls and lets tests inject speech segments.
actor MockVADService: VADService {
    nonisolated let engine: VADEngine = .energy

    // Streams
    nonisolated let speechSegments: AsyncStream<SpeechSegment>
    nonisolated let vadStateEvents: AsyncStream<Bool>

    private var speechContinuation: AsyncStream<SpeechSegment>.Continuation?
    private var stateContinuation: AsyncStream<Bool>.Continuation?

    // Call tracking
    var activateCalled = false
    var deactivateCalled = false
    var throwOnActivate: Error?

    init() {
        var speechCont: AsyncStream<SpeechSegment>.Continuation?
        var stateCont: AsyncStream<Bool>.Continuation?
        speechSegments = AsyncStream { speechCont = $0 }
        vadStateEvents = AsyncStream { stateCont = $0 }
        speechContinuation = speechCont
        stateContinuation = stateCont
    }

    func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws {
        if let error = throwOnActivate { throw error }
        activateCalled = true
    }

    func deactivate() async {
        deactivateCalled = true
        speechContinuation?.finish()
        stateContinuation?.finish()
    }

    /// Inject a speech segment into the stream (for driving downstream STT in tests).
    func injectSpeechSegment(_ segment: SpeechSegment) {
        speechContinuation?.yield(segment)
    }
}
