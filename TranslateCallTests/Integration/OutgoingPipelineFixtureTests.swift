import AppKit
import Foundation
import Testing
@testable import TranslateCall

extension IntegrationTests {
    /// Composes the same stages `AudioCoordinator+Pipeline.swift` wires (VAD → STT → translate → TTS)
    /// without modifying production code. `total` = end of speech → first TTS audio (what a listener perceives).
    @Suite("Outgoing pipeline latency", .serialized) @MainActor
    struct OutgoingPipelineFixtureTests {
        @Test("ES→EN end to end", arguments: try Fixtures.lang("es"))
        func esToEn(_ fixture: AudioFixture) async throws {
            try await requireSpeechAuthorization()
            let (model, window) = hostTranslationBridge()
            defer { window.close() }
            let translator = AppleTranslationService(model: model)
            let src = Locale.Language(identifier: "es"), dst = Locale.Language(identifier: "en")
            try await requireTranslationPack(from: "es", to: "en")
            await translator.warmUp(from: src, to: dst)

            var config = STTConfiguration.default
            config.minimumConfidence = 0
            let run = try await firstTranscript(of: fixture, using: AppleSpeechService(locale: fixture.locale, config: config))

            let translateStart = ContinuousClock.now
            let text = try await translator.translate(text: run.result.text, from: src, to: dst)
            let translateMs = translateStart.duration(to: .now).milliseconds

            // First TTS audio = the first buffer handed to the device (speak() only enqueues).
            let output = RecordingOutput(wrapping: try TTSOutput(deviceID: nil))
            let tts = TTSPlaybackService(primary: AVSpeechUtteranceSynthesizer(), output: output)
            let ttsStart = ContinuousClock.now
            await tts.speak(text: text, locale: Locale(identifier: "en-US"))
            #expect(await waitUntil(timeout: .seconds(15)) { output.firstScheduleAt != nil }, "no TTS audio within 15 s")
            let ttsMs = ttsStart.duration(to: output.firstScheduleAt ?? .now).milliseconds
            await tts.deactivate()

            let total = run.vadMs + run.sttMs + translateMs + ttsMs
            let id = "\(fixture.id)→en"
            let stages: [(LatencyStage, Double)] = [(.vad, run.vadMs), (.stt, run.sttMs), (.translate, translateMs),
                                                    (.ttsFirstAudio, ttsMs), (.total, total)]
            for (stage, ms) in stages {
                await LatencyReport.shared.record(fixture: id, stage: stage, ms: ms)
            }
            #expect(!text.isEmpty)
            // Latency is recorded, not enforced, in F8.5.0 (spec: Out of Scope).
        }
    }
}
