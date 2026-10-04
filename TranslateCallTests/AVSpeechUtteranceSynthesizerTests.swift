import AVFoundation
import Testing
@testable import TranslateCall

/// `AVSpeechSynthesizer.write` renders offline: no audio device is opened (NFR-T-03).
@Suite("AVSpeechUtteranceSynthesizer", .serialized)
struct AVSpeechUtteranceSynthesizerTests {
    private let synthesizer = AVSpeechUtteranceSynthesizer()

    @Test("an English sentence yields audio and the stream finishes (REQ-T-03)")
    func yieldsAndFinishes() async throws {
        let buffers = try #require(try await collect(synthesizer.synthesize(text: "Hello there", locale: english)),
                                   "the stream did not finish within 10 s")
        #expect(!buffers.isEmpty)
        #expect(buffers.allSatisfy { $0.frameLength > 0 })
    }

    @Test("blank text finishes at once with no buffers (REQ-T-03)")
    func blankFinishesEmpty() async throws {
        let buffers = try await collect(synthesizer.synthesize(text: "  ", locale: english))
        #expect(buffers?.isEmpty == true)
    }

    @Test("a locale without a system voice throws voiceUnavailable and cannot be spoken")
    func unknownLocale() async {
        let locale = Locale(identifier: "xx-XX")
        #expect(!synthesizer.canSpeak(locale))
        await #expect(throws: STSError.voiceUnavailable(locale)) {
            _ = try await collect(synthesizer.synthesize(text: "Test", locale: locale))
        }
    }

    @Test("English has a voice; the best one is premium or enhanced when installed")
    func englishVoice() throws {
        #expect(synthesizer.canSpeak(english))
        #expect(AVSpeechUtteranceSynthesizer.hasVoice(for: Locale(identifier: "en")))
        let voice = try #require(AVSpeechUtteranceSynthesizer.bestVoice(for: english))
        let installedBetter = AVSpeechSynthesisVoice.speechVoices().contains {
            $0.language.hasPrefix("en") && $0.quality != .default
        }
        #expect(!installedBetter || voice.quality != .default)
    }

    @Test("hasVoice matches the voices installed on this machine")
    func hasVoiceMatchesInstalled() {
        let installed = AVSpeechSynthesisVoice.speechVoices().contains { $0.language.hasPrefix("uk") }
        #expect(AVSpeechUtteranceSynthesizer.hasVoice(for: Locale(identifier: "uk")) == installed)
    }
}
