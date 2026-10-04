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

    func speak(text: String, locale: Locale) async {
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

    /// Emits a TTS event, as `TTSPlaybackService` does on a skip, fallback or drop.
    func emit(_ event: TTSEvent) {
        eventsContinuation.yield(event)
    }
}
