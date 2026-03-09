import AVFoundation
import Foundation
@testable import TranslateCall

/// Test double for `SpeechRecognizerService`.
actor MockSpeechRecognizerService: SpeechRecognizerService {
    nonisolated let transcriptionStream: AsyncStream<TranscriptionResult>
    // nonisolated(unsafe): written on actor via setLocale(), read without await — safe in tests
    nonisolated(unsafe) private(set) var locale: Locale

    private var transcriptionContinuation: AsyncStream<TranscriptionResult>.Continuation?

    // Call tracking
    var activateCalled = false
    var deactivateCalled = false
    var setLocaleCalls: [Locale] = []
    var throwOnActivate: Error?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
        var cont: AsyncStream<TranscriptionResult>.Continuation?
        transcriptionStream = AsyncStream { cont = $0 }
        transcriptionContinuation = cont
    }

    func activate(stream: AsyncStream<SpeechSegment>) async throws {
        if let error = throwOnActivate { throw error }
        activateCalled = true
    }

    func deactivate() async {
        deactivateCalled = true
        transcriptionContinuation?.finish()
    }

    func setLocale(_ newLocale: Locale) async {
        locale = newLocale
        setLocaleCalls.append(newLocale)
    }

    /// Inject a transcription result into the stream.
    func injectTranscription(_ result: TranscriptionResult) {
        transcriptionContinuation?.yield(result)
    }
}
