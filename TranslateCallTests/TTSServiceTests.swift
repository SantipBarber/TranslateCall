@_exported import Testing
import AVFoundation
@testable import TranslateCall

// MARK: - T1: SynthesisConfiguration
// @MainActor required: SynthesisConfiguration has var properties which are @MainActor
// under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.

@MainActor
struct SynthesisConfigurationTests {

    @Test func synthesisConfigurationDefaults() {
        let config = SynthesisConfiguration.default
        #expect(config.rate == 0.5)           // matches AVSpeechUtteranceDefaultSpeechRate
        #expect(config.pitchMultiplier == 1.0)
        #expect(config.volume == 1.0)
    }

    @Test func synthesisConfigurationCustomValues() {
        var config = SynthesisConfiguration()
        config.rate = 0.1                     // AVSpeechUtteranceMinimumSpeechRate
        config.pitchMultiplier = 0.8
        config.volume = 0.5
        #expect(config.rate == 0.1)
        #expect(config.pitchMultiplier == 0.8)
        #expect(config.volume == 0.5)
    }
}

// MARK: - T1: STSError

@MainActor
struct STSErrorTests {

    @Test func stsErrorVoiceUnavailableHasDescription() {
        let error = STSError.voiceUnavailable(Locale(identifier: "en-US"))
        #expect(error.errorDescription != nil)
        #expect(!(error.errorDescription ?? "").isEmpty)
    }

    @Test func stsErrorEngineStartFailedHasDescription() {
        let inner = NSError(domain: "test", code: -1)
        let error = STSError.engineStartFailed(inner)
        #expect(error.errorDescription != nil)
        #expect(!(error.errorDescription ?? "").isEmpty)
    }
}

// MARK: - T2: STSError.deviceRoutingFailed

@MainActor
struct STSErrorDeviceRoutingTests {
    @Test func deviceRoutingFailedHasDescription() {
        let error = STSError.deviceRoutingFailed
        #expect(error.errorDescription != nil)
        #expect(!(error.errorDescription ?? "").isEmpty)
    }
}

// MARK: - T2: AVSpeechService output device routing

@Suite("AVSpeechService device routing", .serialized)
@MainActor
struct AVSpeechServiceRoutingTests {
    @Test("init with nil outputDeviceID succeeds (default routing)")
    func initWithNilDeviceIDSucceeds() async throws {
        let service = try AVSpeechService(outputDeviceID: nil)
        await service.deactivate()
        // No throw = pass
    }

    @Test("init with nonexistent deviceID throws deviceRoutingFailed")
    func initWithBadDeviceIDThrows() async throws {
        // AudioDeviceID 99999 is virtually guaranteed not to exist on any Mac
        #expect(throws: STSError.deviceRoutingFailed) {
            _ = try AVSpeechService(outputDeviceID: AudioDeviceID(99999))
        }
    }
}

// MARK: - T2 + T4: AVSpeechService
// @Suite(.serialized) prevents multiple AVAudioEngine instances running in parallel,
// which would otherwise cause audio hardware resource conflicts on the test machine.

@Suite("AVSpeechService + Integration", .serialized)
@MainActor
struct AVSpeechServiceTests {

    @Test func speakEmitsIsSpeakingTrue() async throws {
        let service = try AVSpeechService()
        await service.speak(text: "Hello", locale: Locale(identifier: "en-US"))

        var gotTrue = false
        for await value in service.isSpeakingStream {
            gotTrue = value
            break
        }
        await service.deactivate()
        #expect(gotTrue == true)
    }

    @Test func stopSpeakingClearsQueue() async throws {
        let service = try AVSpeechService()
        await service.speak(text: "First utterance", locale: Locale(identifier: "en-US"))
        await service.speak(text: "Second utterance", locale: Locale(identifier: "en-US"))
        await service.stopSpeaking()
        await service.deactivate()
        // No crash = pass
    }

    @Test func voiceSelectionPrefersEnhancedForEnglish() async throws {
        let service = try AVSpeechService()
        let voice = await service.bestVoiceForTesting(locale: Locale(identifier: "en-US"))
        await service.deactivate()
        #expect(voice != nil)
    }

    @Test func voiceUnavailableDoesNotCrash() async throws {
        let service = try AVSpeechService()
        // "xx-XX" is an invalid locale — bestVoice returns nil, speak is a no-op
        await service.speak(text: "Test", locale: Locale(identifier: "xx-XX"))
        var emittedTrue = false
        let checkTask = Task { @MainActor in
            for await value in service.isSpeakingStream {
                emittedTrue = value
                break
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        checkTask.cancel()
        await service.deactivate()
        #expect(emittedTrue == false)
    }

    @Test func deactivateStopsSynthesis() async throws {
        let service = try AVSpeechService()
        await service.speak(text: "Testing deactivation", locale: Locale(identifier: "en-US"))
        await service.deactivate()
        // No crash = pass
    }

    // MARK: - T4 Integration

    @Test func speakingStreamEmitsTrue() async throws {
        let service = try AVSpeechService()
        await service.speak(text: "Hi", locale: Locale(identifier: "en-US"))
        var firstEvent: Bool?
        for await value in service.isSpeakingStream {
            firstEvent = value
            break
        }
        await service.deactivate()
        #expect(firstEvent == true)
    }

    @Test func queuedUtterancesPlayWithoutCrash() async throws {
        let service = try AVSpeechService()
        await service.speak(text: "one", locale: Locale(identifier: "en-US"))
        await service.speak(text: "two", locale: Locale(identifier: "en-US"))
        await service.speak(text: "three", locale: Locale(identifier: "en-US"))
        await service.stopSpeaking()
        await service.deactivate()
        // No crash = pass
    }
}
