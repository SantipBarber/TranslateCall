import AVFoundation
import Foundation
@testable import TranslateCall

/// Test double for `SynthesisService`.
actor MockSynthesisService: SynthesisService {
    nonisolated let isSpeakingStream: AsyncStream<Bool>
    private var speakingContinuation: AsyncStream<Bool>.Continuation?

    // Call tracking
    var speakCalls: [(text: String, locale: String)] = []
    var stopSpeakingCalled = false
    var deactivateCalled = false
    private(set) var isSpeaking = false

    init() {
        var cont: AsyncStream<Bool>.Continuation?
        isSpeakingStream = AsyncStream { cont = $0 }
        speakingContinuation = cont
    }

    func speak(text: String, locale: Locale) async {
        speakCalls.append((text: text, locale: locale.identifier))
        isSpeaking = true
        speakingContinuation?.yield(true)
    }

    func stopSpeaking() async {
        stopSpeakingCalled = true
        isSpeaking = false
        speakingContinuation?.yield(false)
    }

    func deactivate() async {
        deactivateCalled = true
        isSpeaking = false
        speakingContinuation?.finish()
    }
}
