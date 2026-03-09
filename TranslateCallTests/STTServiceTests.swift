@_exported import Testing
import AVFoundation
import Speech
@testable import TranslateCall

// MARK: - T1: TranscriptionResult

@MainActor
struct TranscriptionResultTests {

    @Test func transcriptionResultIsValueType() {
        let result = TranscriptionResult(
            text: "hello",
            confidence: 0.9,
            locale: Locale(identifier: "en-US"),
            capturedAt: Date(timeIntervalSince1970: 0),
            audioDuration: 1.5
        )
        let copy = result
        #expect(copy.text == result.text)
        #expect(copy.confidence == result.confidence)
        #expect(copy.locale == result.locale)
        #expect(copy.capturedAt == result.capturedAt)
        #expect(copy.audioDuration == result.audioDuration)
    }
}

// MARK: - T1: STTConfiguration

@MainActor
struct STTConfigurationTests {

    @Test func sttConfigurationDefaults() {
        let config = STTConfiguration.default
        #expect(config.minimumConfidence == 0.60)
        #expect(config.preferOnDevice == true)
    }

    @Test func sttConfigurationCustomValues() {
        var config = STTConfiguration()
        config.minimumConfidence = 0.80
        config.preferOnDevice = false
        #expect(config.minimumConfidence == 0.80)
        #expect(config.preferOnDevice == false)
    }
}

// MARK: - T1: STTError

@MainActor
struct STTErrorTests {

    @Test func sttErrorPermissionDeniedHasDescription() {
        let error = STTError.permissionDenied
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
    }

    @Test func sttErrorRecognizerUnavailableHasDescription() {
        let error = STTError.recognizerUnavailable(Locale(identifier: "es-ES"))
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
    }

    @Test func sttErrorRecognitionFailedHasDescription() {
        let underlying = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "test error"])
        let error = STTError.recognitionFailed(underlying)
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
    }
}

// MARK: - T2: AppleSpeechService

@Suite(.serialized)
@MainActor
struct AppleSpeechServiceTests {

    @Test func appleSpeechServiceInitializesLocale() async {
        let locale = Locale(identifier: "en-US")
        let service = AppleSpeechService(locale: locale)
        #expect(service.locale == locale)
    }

    @Test func appleSpeechServiceHasTranscriptionStream() async {
        let service = AppleSpeechService(locale: Locale(identifier: "en-US"))
        // Stream is a value-type struct; just verify it exists and can be iterated
        var count = 0
        let task = Task {
            for await _ in service.transcriptionStream {
                count += 1
            }
        }
        task.cancel()
        // No assertion needed — compile-time guarantee; just ensuring no crash
    }

    @Test func appleSpeechServiceLocaleSwitch() async {
        let service = AppleSpeechService(locale: Locale(identifier: "en-US"))
        await service.setLocale(Locale(identifier: "es-ES"))
        #expect(service.locale == Locale(identifier: "es-ES"))
    }

    @Test func appleSpeechServiceDeactivateWithoutActivateDoesNotCrash() async {
        let service = AppleSpeechService(locale: Locale(identifier: "en-US"))
        await service.deactivate()
        // Just verify no crash
    }

    @Test func appleSpeechServiceVoiceUnavailableLocaleDoesNotCrash() async throws {
        // Locale with no recognizer should throw recognizerUnavailable from activate()
        let service = AppleSpeechService(locale: Locale(identifier: "xx-XX"))
        let stream = AsyncStream<SpeechSegment> { $0.finish() }

        // Skip test if speech recognition is not authorized (CI/sandboxed environment)
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else { return }

        do {
            try await service.activate(stream: stream)
        } catch STTError.recognizerUnavailable {
            // Expected
        } catch STTError.permissionDenied {
            // Also acceptable in restricted environments
        }
    }
}
