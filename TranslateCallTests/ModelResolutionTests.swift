import Foundation
import Testing
@testable import TranslateCall

private let en = Locale(identifier: "en-US")
private let es = Locale(identifier: "es-ES")
private let de = Locale(identifier: "de-DE")
private let edgeOK = CloudSnapshot(allowed: true, consented: [.edgeTTS])

private let both = ModelAvailability(parakeetCached: true, whisperCached: true)

private struct STTCase {
    let choice: STTEngine
    let locale: Locale
    let direction: TranscriptDirection
    let availability: ModelAvailability
    let expected: STTEngine
}

@Suite("Resolution with a pair choice (M9 UI settings REQ-ST-02…04)") @MainActor
struct ModelResolutionTests {

    @Test("a usable STT choice wins over the catalog")
    func sttChoiceWins() {
        let all = ModelAvailability(parakeetCached: true, whisperCached: true)
        #expect(ModelChoice.stt(for: es, direction: .outgoing, pairChoice: .appleSpeech,
                                catalog: .builtIn, availability: all) == .appleSpeech)
    }

    @Test("an STT choice that is not usable falls back to the catalog",
          arguments: [
            STTCase(choice: .whisper, locale: es, direction: .outgoing,
                    availability: ModelAvailability(), expected: .appleSpeech),
            STTCase(choice: .parakeet, locale: es, direction: .outgoing, availability: both, expected: .whisper),
            STTCase(choice: .parakeet, locale: en, direction: .incoming, availability: both, expected: .whisper),
            STTCase(choice: .parakeet, locale: en, direction: .outgoing,
                    availability: ModelAvailability(parakeetCached: true), expected: .parakeet)
          ])
    private func sttChoiceFallsBack(testCase: STTCase) {
        #expect(ModelChoice.stt(for: testCase.locale, direction: testCase.direction,
                                pairChoice: testCase.choice, catalog: .builtIn,
                                availability: testCase.availability) == testCase.expected)
    }

    @Test("a voice choice applies to both directions where it serves the language (REQ-ST-03)")
    func voiceChoiceBothDirections() {
        let kokoro = ModelAvailability(kokoroCached: true)
        #expect(ModelChoice.tts(for: en, direction: .outgoing, pairChoice: .avSpeech,
                                catalog: .builtIn, availability: kokoro) == .avSpeech)
        #expect(ModelChoice.tts(for: en, direction: .incoming, pairChoice: .avSpeech,
                                catalog: .builtIn, availability: kokoro) == .avSpeech)
        #expect(ModelChoice.tts(for: es, direction: .incoming, pairChoice: .kokoro,
                                catalog: .builtIn, availability: kokoro) == .avSpeech, "Kokoro: English only")
    }

    @Test("the voice clone wins outgoing whatever the choice; the choice still applies incoming (REQ-ST-04)")
    func voiceCloneWinsOutgoing() {
        let clone = ModelAvailability(voiceCloneReady: true, cloud: edgeOK)
        #expect(ModelChoice.tts(for: es, direction: .outgoing, pairChoice: .edgeTTS,
                                catalog: .builtIn, availability: clone) == .voiceClone)
        #expect(ModelChoice.tts(for: es, direction: .incoming, pairChoice: .edgeTTS,
                                catalog: .builtIn, availability: clone) == .edgeTTS)
    }

    @Test("Kokoro chosen while the voice clone is ready falls back to the system voice (NF-04)")
    func kokoroBlockedByVoiceClone() {
        let both = ModelAvailability(kokoroCached: true, voiceCloneReady: true)
        #expect(ModelChoice.tts(for: en, direction: .incoming, pairChoice: .kokoro,
                                catalog: .builtIn, availability: both) == .avSpeech)
    }

    @Test("Edge as a choice needs cloud allowed, consent and availability (REQ-ST-32, S-3)",
          arguments: [
            (edgeOK, TTSEngine.edgeTTS),
            (CloudSnapshot(allowed: false, consented: [.edgeTTS]), .avSpeech),
            (CloudSnapshot(allowed: true), .avSpeech),
            (CloudSnapshot(allowed: true, consented: [.edgeTTS], unavailable: [.edgeTTS]), .avSpeech)
          ])
    func edgeChoiceNeedsCloud(cloud: CloudSnapshot, expected: TTSEngine) {
        #expect(ModelChoice.tts(for: de, direction: .incoming, pairChoice: .edgeTTS, catalog: .builtIn,
                                availability: ModelAvailability(cloud: cloud)) == expected)
    }

    @Test("serves ignores the disk: Parakeet and the voice clone are outgoing only")
    func servesRules() {
        #expect(ModelChoice.serves(STTEngine.parakeet, locale: en, direction: .outgoing))
        #expect(!ModelChoice.serves(STTEngine.parakeet, locale: en, direction: .incoming))
        #expect(!ModelChoice.serves(STTEngine.parakeet, locale: es, direction: .outgoing))
        #expect(!ModelChoice.serves(TTSEngine.voiceClone, locale: es, direction: .incoming))
        #expect(ModelChoice.serves(TTSEngine.kokoro, locale: en, direction: .incoming))
    }
}
