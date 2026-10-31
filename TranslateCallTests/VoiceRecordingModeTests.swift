import Foundation
import Testing
@testable import TranslateCall

@Suite
struct VoiceRecordingModeTests {

    private func metrics(peak: Float, clip: Bool, voiced: Float, mode: RecordingMode) -> VoiceQualityMetrics {
        VoiceQualityMetrics(
            peakRmsDbfs: peak,
            hasClipping: clip,
            voicedDurationSeconds: voiced,
            grade: VoiceQualityRules.grade(
                peakRmsDbfs: peak, hasClipping: clip, voicedSeconds: voiced, mode: mode
            )
        )
    }

    @Test(arguments: [
        (Float(-18), false, Float(25), VoiceQualityGrade.good),
        (Float(-18), false, Float(10), VoiceQualityGrade.fair),
        (Float(-25), false, Float(25), VoiceQualityGrade.fair),
        (Float(-35), false, Float(25), VoiceQualityGrade.poor),
        (Float(-18), true, Float(25), VoiceQualityGrade.poor),
        (Float(-18), false, Float(7), VoiceQualityGrade.poor)
    ])
    func freeRuleUnchanged(peak: Float, clip: Bool, voiced: Float, expected: VoiceQualityGrade) {
        #expect(VoiceQualityRules.grade(
            peakRmsDbfs: peak, hasClipping: clip, voicedSeconds: voiced, mode: .free
        ) == expected)
    }

    @Test func freeBlockedOnlyWhenPoorAndShort() {
        #expect(VoiceQualityRules.isSaveBlocked(metrics(peak: -18, clip: false, voiced: 7, mode: .free), mode: .free))
        #expect(!VoiceQualityRules.isSaveBlocked(metrics(peak: -35, clip: false, voiced: 12, mode: .free), mode: .free))
    }

    @Test func guidedShortIsGood() {
        let mode = RecordingMode.guided(language: "spanish")
        let ok = metrics(peak: -18, clip: false, voiced: 7, mode: mode)
        #expect(ok.grade == .good)
        #expect(!VoiceQualityRules.isSaveBlocked(ok, mode: mode))
        let short = metrics(peak: -18, clip: false, voiced: 4, mode: mode)
        #expect(short.grade == .poor)
        #expect(VoiceQualityRules.isSaveBlocked(short, mode: mode))
    }

    @Test func guidedMaxSeconds() {
        #expect(RecordingMode.guided(language: "spanish").maxSeconds == QwenCloneConfiguration.guidedMaxSeconds)
        #expect(RecordingMode.guided(language: "spanish").maxSeconds == 15)
        #expect(RecordingMode.free.maxSeconds == 30)
    }

    @Test func guidedTextOnlyForGuided() {
        #expect(RecordingMode.free.guidedText == nil)
        #expect(RecordingMode.guided(language: "english").guidedText?.isEmpty == false)
    }

    @Test func trimSilence() {
        let rate = 24_000.0
        let silence = [Float](repeating: 0, count: Int(0.5 * rate))
        let tone = (0 ..< Int(rate)).map { 0.3 * sinf(Float($0) * 0.1) }
        let trimmed = VoiceQualityRules.trimSilence(silence + tone + silence, sampleRate: rate)
        let seconds = Double(trimmed.count) / rate
        // 1 s of tone + 0.3 s kept on each side
        #expect(abs(seconds - 1.6) < 0.05)
    }

    @Test func trimKeepsShortSilenceAndAllSilence() {
        let rate = 24_000.0
        let tone = (0 ..< Int(rate)).map { 0.3 * sinf(Float($0) * 0.1) }
        let pad = [Float](repeating: 0, count: Int(0.2 * rate))
        #expect(VoiceQualityRules.trimSilence(pad + tone + pad, sampleRate: rate).count == tone.count + 2 * pad.count)
        let quiet = [Float](repeating: 0, count: 24_000)
        #expect(VoiceQualityRules.trimSilence(quiet, sampleRate: rate).count == quiet.count)
    }
}
