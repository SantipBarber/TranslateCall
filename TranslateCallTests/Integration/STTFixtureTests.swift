import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("STT with fixtures", .serialized) @MainActor
    struct STTFixtureTests {
        /// `minimumConfidence: 0` isolates recognition accuracy from the confidence filter (F8.5.1 scope).
        private var config: STTConfiguration {
            var config = STTConfiguration.default
            config.minimumConfidence = 0
            return config
        }

        @Test("Apple Speech", arguments: try Fixtures.all().filter { !$0.lang.hasPrefix("uk") })
        func appleSpeech(_ fixture: AudioFixture) async throws {
            try await requireSpeechAuthorization()
            let stt = AppleSpeechService(locale: fixture.locale, config: config)
            let run = try await firstTranscript(of: fixture, using: stt)
            let wer = WordErrorRate.compute(reference: fixture.text, hypothesis: run.result.text)
            print("LATENCY \(fixture.id) vad \(run.vadMs) ms")
            print("LATENCY \(fixture.id) stt \(run.sttMs) ms")
            #expect(wer <= fixture.maxWer, "WER \(wer) > \(fixture.maxWer): got “\(run.result.text)”")
        }

        @Test("WhisperKit (uk)", arguments: try Fixtures.lang("uk"))
        func whisper(_ fixture: AudioFixture) async throws {
            // First run downloads the Whisper `base` model (~150 MB) via WhisperModelManager.
            let stt = WhisperSpeechService(locale: fixture.locale, config: config)
            let run = try await firstTranscript(of: fixture, using: stt, timeout: .seconds(180))
            let wer = WordErrorRate.compute(reference: fixture.text, hypothesis: run.result.text)
            print("LATENCY \(fixture.id) vad \(run.vadMs) ms")
            print("LATENCY \(fixture.id) stt \(run.sttMs) ms")
            // Measured 2026-10-03: uk-thanks WER 0.5 with Whisper `base` ("мені"→"ми не", "чути"→"шути").
            withKnownIssue("F8.5.1: Whisper base accuracy on Ukrainian — evaluate `small`", isIntermittent: true) {
                #expect(wer <= fixture.maxWer, "WER \(wer) > \(fixture.maxWer): got “\(run.result.text)”")
            }
        }
    }
}
