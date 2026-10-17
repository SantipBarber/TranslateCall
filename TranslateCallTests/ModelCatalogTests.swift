import Foundation
import Testing
@testable import TranslateCall

private let en = Locale(identifier: "en-US")
private let es = Locale(identifier: "es-ES")
private let de = Locale(identifier: "de-DE")
private let uk = Locale(identifier: "uk-UA")

@Suite("ModelCatalog (M9 UI core)") @MainActor
struct ModelCatalogTests {

    /// What any catalog must hold, whatever the benchmark writes (D-2): a `default` entry in every
    /// table, no Edge TTS, and every list ending with an engine that is always ready.
    private func expectInvariants(_ catalog: ModelCatalog) {
        for (table, last) in [(catalog.stt, "appleSpeech"), (catalog.ttsOutgoing, "avSpeech"),
                              (catalog.ttsIncoming, "avSpeech")] {
            #expect(table["default"] != nil)
            for list in table.values {
                #expect(!list.contains(TTSEngine.edgeTTS.rawValue))
                #expect(list.last == last)
            }
        }
    }

    @Test("the bundled JSON is in the app, decodes and keeps the catalog invariants (REQ-UI-20, D-2)")
    func bundledInvariants() throws {
        let url = try #require(Bundle.main.url(forResource: "ModelCatalog", withExtension: "json"))
        let catalog = try #require(ModelCatalog.decode(from: url))
        #expect(ModelCatalog.bundled == catalog)
        expectInvariants(catalog)
        expectInvariants(.builtIn)
    }

    @Test("a missing or corrupt file falls back to the built-in catalog")
    func corruptFileFallsBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID()).json")
        try Data("{ not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ModelCatalog.decode(from: url) == nil)
        #expect(ModelCatalog.load(from: url) == ModelCatalog.builtIn)
        #expect(ModelCatalog.load(from: nil) == ModelCatalog.builtIn)
    }

    @Test("languages without an entry use `default`; unknown and edgeTTS names are dropped")
    func lookupUsesDefault() {
        let catalog = ModelCatalog(version: 1, stt: ["default": ["whisper", "nope", "appleSpeech"]],
                                   ttsOutgoing: ["default": ["edgeTTS", "avSpeech"]], ttsIncoming: [:])
        #expect(catalog.sttEngines(for: de) == [.whisper, .appleSpeech])
        #expect(catalog.ttsEngines(for: de, direction: .outgoing) == [.avSpeech])
        #expect(catalog.ttsEngines(for: de, direction: .incoming).isEmpty)
    }

    @Test("STT: English prefers Parakeet, then Whisper; others Whisper; nothing cached → Apple Speech",
          arguments: [
            (en, ModelAvailability(parakeetCached: true, whisperCached: true), STTEngine.parakeet),
            (en, ModelAvailability(whisperCached: true), .whisper),
            (es, ModelAvailability(parakeetCached: true, whisperCached: true), .whisper),
            (de, ModelAvailability(parakeetCached: true), .appleSpeech),
            (uk, ModelAvailability(), .appleSpeech),
          ])
    func sttResolution(locale: Locale, availability: ModelAvailability, expected: STTEngine) {
        #expect(ModelChoice.stt(for: locale, direction: .outgoing, catalog: .builtIn, availability: availability) == expected)
    }

    @Test("STT incoming never uses Parakeet (one shared ASR model, outgoing only as today)")
    func parakeetOutgoingOnly() {
        let all = ModelAvailability(parakeetCached: true, whisperCached: true)
        #expect(ModelChoice.stt(for: en, direction: .incoming, catalog: .builtIn, availability: all) == .whisper)
        let parakeet = ModelAvailability(parakeetCached: true)
        #expect(ModelChoice.stt(for: en, direction: .incoming, catalog: .builtIn, availability: parakeet) == .appleSpeech)
    }

    @Test("TTS outgoing: the voice clone when active, else Kokoro for English, else the system voice",
          arguments: [
            (en, ModelAvailability(kokoroCached: true, voiceCloneReady: true), TTSEngine.voiceClone),
            (en, ModelAvailability(kokoroCached: true), .kokoro),
            (es, ModelAvailability(kokoroCached: true, voiceCloneReady: true), .voiceClone),
            (es, ModelAvailability(kokoroCached: true), .avSpeech),
            (de, ModelAvailability(), .avSpeech),
          ])
    func ttsOutgoingResolution(locale: Locale, availability: ModelAvailability, expected: TTSEngine) {
        #expect(ModelChoice.tts(for: locale, direction: .outgoing, catalog: .builtIn,
                                availability: availability) == expected)
    }

    @Test("TTS incoming: Kokoro for English only while the voice clone is not active (MLX exclusivity, §3.3)")
    func ttsIncomingMLXExclusivity() {
        let kokoro = ModelAvailability(kokoroCached: true)
        let both = ModelAvailability(kokoroCached: true, voiceCloneReady: true)
        #expect(ModelChoice.tts(for: en, direction: .incoming, catalog: .builtIn, availability: kokoro) == .kokoro)
        #expect(ModelChoice.tts(for: en, direction: .incoming, catalog: .builtIn, availability: both) == .avSpeech)
        #expect(ModelChoice.tts(for: es, direction: .incoming, catalog: .builtIn, availability: kokoro) == .avSpeech)
    }

    @Test("automatic choice never picks Edge, even when it is the only listed engine (REQ-UI-22)")
    func neverEdge() {
        let catalog = ModelCatalog(version: 1, stt: [:], ttsOutgoing: ["default": ["edgeTTS"]],
                                   ttsIncoming: ["default": ["edgeTTS"]])
        let all = ModelAvailability(parakeetCached: true, whisperCached: true, kokoroCached: true, voiceCloneReady: true)
        #expect(ModelChoice.tts(for: uk, direction: .outgoing, catalog: catalog, availability: all) == .avSpeech)
        #expect(ModelChoice.tts(for: uk, direction: .incoming, catalog: catalog, availability: all) == .avSpeech)
        #expect(ModelChoice.stt(for: uk, direction: .outgoing, catalog: catalog, availability: all) == .appleSpeech)
    }
}
