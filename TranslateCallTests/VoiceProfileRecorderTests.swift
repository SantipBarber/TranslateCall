import Foundation
import Testing
@testable import TranslateCall

@Suite @MainActor
struct VoiceProfileRecorderTests {

    // Quality computation tests — no real audio hardware needed.

    @Test func qualityGoodForStrongSignal() {
        // Simulate: loud, clean, 25 s of voiced content at 24 kHz
        let sampleCount = 25 * 24000
        // Amplitude ~0.5 → RMS ≈ -6 dBFS (well above -20)
        let samples = (0 ..< sampleCount).map { _ in Float.random(in: -0.5 ... 0.5) }
        let metrics = VoiceProfileRecorder.computeQualityStatic(
            samples: samples, sampleRate: 24000
        )
        #expect(metrics.grade == .good)
        #expect(!metrics.hasClipping)
        #expect(metrics.peakRmsDbfs > -20)
        #expect(metrics.voicedDurationSeconds >= 20)
    }

    @Test func qualityFairForLowLevel() {
        // Simulate: quiet signal (amplitude ~0.056 → RMS ≈ -25 dBFS)
        let sampleCount = 25 * 24000
        let samples = (0 ..< sampleCount).map { _ in Float.random(in: -0.056 ... 0.056) }
        let metrics = VoiceProfileRecorder.computeQualityStatic(
            samples: samples, sampleRate: 24000
        )
        #expect(metrics.peakRmsDbfs < -20)
        #expect(metrics.peakRmsDbfs >= -30)
        #expect(metrics.grade == .fair)
    }

    @Test func qualityPoorForClipping() {
        // 1000 out of 24000 samples are clipped (>4% >> 0.1% threshold)
        var samples = (0 ..< 24000).map { _ in Float.random(in: -0.3 ... 0.3) }
        for idx in 0 ..< 1000 {
            samples[idx] = 0.99
        }
        let metrics = VoiceProfileRecorder.computeQualityStatic(
            samples: samples, sampleRate: 24000
        )
        #expect(metrics.hasClipping)
        #expect(metrics.grade == .poor)
    }

    @Test func qualityPoorForShortVoiced() {
        // 3 seconds of speech + 27 seconds of near-silence
        let speechSamples = (0 ..< (3 * 24000)).map { _ in Float.random(in: -0.4 ... 0.4) }
        let silenceSamples = [Float](repeating: 0.0001, count: 27 * 24000)
        let samples = speechSamples + silenceSamples
        let metrics = VoiceProfileRecorder.computeQualityStatic(
            samples: samples, sampleRate: 24000
        )
        #expect(metrics.voicedDurationSeconds < 8)
        #expect(metrics.grade == .poor)
    }

    @Test func sessionConflictBlocks() async throws {
        let recorder = VoiceProfileRecorder(isSessionActive: { true })
        do {
            try await recorder.startRecording()
            Issue.record("Expected sessionConflict error")
        } catch is VoiceProfileRecorderError {
            // Expected: .sessionConflict
        }
    }

    @Test func emptySamplesReturnPoorGrade() {
        let metrics = VoiceProfileRecorder.computeQualityStatic(
            samples: [], sampleRate: 24000
        )
        #expect(metrics.grade == .poor)
        #expect(metrics.peakRmsDbfs <= -60)
        #expect(metrics.voicedDurationSeconds == 0)
        #expect(!metrics.hasClipping)
    }

    @Test func qualityPoorForVeryLowRms() {
        // All samples near zero → RMS < -30 dBFS
        let sampleCount = 25 * 24000
        let samples = [Float](repeating: 0.001, count: sampleCount)
        let metrics = VoiceProfileRecorder.computeQualityStatic(
            samples: samples, sampleRate: 24000
        )
        #expect(metrics.peakRmsDbfs < -30)
        #expect(metrics.grade == .poor)
    }
}
