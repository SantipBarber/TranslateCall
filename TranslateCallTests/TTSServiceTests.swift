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

    @Test func outputUnavailableHasDescription() {
        #expect(STSError.outputUnavailable.errorDescription?.isEmpty == false)
        #expect(STSError.outputUnavailable == .outputUnavailable)
        #expect(STSError.outputUnavailable != .deviceRoutingFailed)
    }
}
