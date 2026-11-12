import AVFoundation
import Foundation
@testable import TranslateCall

/// Test double for `SynthesisService`.
actor MockSynthesisService: SynthesisService {
    nonisolated let isSpeakingStream: AsyncStream<Bool>
    nonisolated let ttsEvents: AsyncStream<TTSEvent>?
    private let speakingContinuation: AsyncStream<Bool>.Continuation
    private let eventsContinuation: AsyncStream<TTSEvent>.Continuation

    // Call tracking
    var speakCalls: [(text: String, locale: String)] = []
    var stopSpeakingCalled = false
    var deactivateCalled = false
    private(set) var isSpeaking = false

    init() {
        (isSpeakingStream, speakingContinuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(8))
        let (events, eventsContinuation) = AsyncStream.makeStream(of: TTSEvent.self, bufferingPolicy: .bufferingNewest(16))
        ttsEvents = events
        self.eventsContinuation = eventsContinuation
    }

    /// When set, the next `speak` waits here before queuing until `releaseHeldSpeak()`: the call
    /// reached the actor late, after a `stopSpeaking()` sent after it (actor jobs are not FIFO).
    var holdNextSpeak = false
    private var heldSpeak: CheckedContinuation<Void, Never>?
    var isHoldingSpeak: Bool { heldSpeak != nil }
    func setHoldNextSpeak() { holdNextSpeak = true }
    func releaseHeldSpeak() { heldSpeak?.resume(); heldSpeak = nil }

    func speak(text: String, locale: Locale) async {
        if holdNextSpeak {
            holdNextSpeak = false
            await withCheckedContinuation { heldSpeak = $0 }
        }
        speakCalls.append((text: text, locale: locale.identifier))
        isSpeaking = true
        speakingContinuation.yield(true)
    }

    func stopSpeaking() async {
        stopSpeakingCalled = true
        isSpeaking = false
        speakingContinuation.yield(false)
    }

    func deactivate() async {
        deactivateCalled = true
        isSpeaking = false
        speakingContinuation.finish()
        eventsContinuation.finish()
    }

    /// Reports a speaking change at once, from the caller's executor (no actor hop), so a test can
    /// queue it on an observer before running something else in the same main-actor turn.
    nonisolated func yieldSpeaking(_ speaking: Bool) {
        speakingContinuation.yield(speaking)
    }

    /// Emits a TTS event, as `TTSPlaybackService` does on a skip, fallback or drop.
    func emit(_ event: TTSEvent) {
        eventsContinuation.yield(event)
    }
}
