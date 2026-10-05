import Foundation
import Testing
@testable import TranslateCall

@Suite("VADConfiguration validation (T3)")
struct VADConfigurationValidationTests {

    @Test("a valid configuration is returned unchanged")
    func validUnchanged() {
        #expect(VADConfiguration().validated() == VADConfiguration())
        var config = VADConfiguration()
        config.minSilenceDuration = 1.2
        config.sileroThreshold = 0.5
        #expect(config.validated() == config)
    }

    @Test("the default pause is 0.6 s (D-6)")
    func defaultPause() {
        #expect(VADConfiguration.default.minSilenceDuration == 0.6)
    }

    @Test("negative durations become 0, and maxSpeechDuration stays positive")
    func negativesClamped() {
        var config = VADConfiguration()
        config.minSpeechDuration = -1
        config.minSilenceDuration = -0.5
        config.speechPadding = -0.1
        config.maxSpeechDuration = 0
        let fixed = config.validated()
        #expect(fixed.minSpeechDuration == 0)
        #expect(fixed.minSilenceDuration == 0)
        #expect(fixed.speechPadding == 0)
        #expect(fixed.maxSpeechDuration == VADConfiguration.minimumMaxSpeechDuration)
    }

    @Test("minSpeech and minSilence never exceed maxSpeech; padding never exceeds minSpeech")
    func orderingClamped() {
        var config = VADConfiguration()
        config.maxSpeechDuration = 0.5
        config.minSpeechDuration = 0.8
        config.minSilenceDuration = 0.9
        config.speechPadding = 0.7
        let fixed = config.validated()
        #expect(fixed.minSpeechDuration == 0.5)
        #expect(fixed.minSilenceDuration == 0.5)
        #expect(fixed.speechPadding == 0.5)

        var padded = VADConfiguration()
        padded.speechPadding = 0.3   // > minSpeechDuration 0.15
        #expect(padded.validated().speechPadding == 0.15)
    }

    @Test("thresholds are clamped and non-finite values fall back to the defaults")
    func thresholdsAndNonFinite() {
        var config = VADConfiguration()
        config.sileroThreshold = 1.5
        config.energyThresholdDBFS = 6
        #expect(config.validated().sileroThreshold == 1)
        #expect(config.validated().energyThresholdDBFS == 0)
        config.sileroThreshold = -0.2
        #expect(config.validated().sileroThreshold == 0)
        config.sileroThreshold = .nan
        config.minSilenceDuration = .infinity
        #expect(config.validated().sileroThreshold == VADConfiguration().sileroThreshold)
        #expect(config.validated().minSilenceDuration == VADConfiguration().minSilenceDuration)
    }

    @Test("Silero is asked for one 256 ms chunk less silence than the configured pause (P2)")
    func sileroSilenceCompensation() {
        var config = VADConfiguration()
        config.minSilenceDuration = 0.6
        #expect(abs(config.sileroMinSilenceDuration - (0.6 - 0.256)) < 1e-9)
        config.minSilenceDuration = 0.2
        #expect(config.sileroMinSilenceDuration == 0)
    }
}
