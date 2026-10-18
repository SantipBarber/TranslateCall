import Foundation
import Testing
@testable import TranslateCall

@Suite("ModelCatalog v2 (M9 UI settings S-2, S-3)") @MainActor
struct ModelCatalogV2Tests {

    private func decode(_ json: String) throws -> ModelCatalog {
        try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
    }

    @Test("a v1 file still decodes, with no engine flags and no pair data")
    func v1StillDecodes() throws {
        let catalog = try decode(#"{"version":1,"stt":{"default":["appleSpeech"]},"ttsOutgoing":{},"ttsIncoming":{}}"#)
        #expect(catalog.engines.isEmpty && catalog.pairs.isEmpty)
        #expect(!catalog.isUnavailable(.edgeTTS))
    }

    @Test("v2 reads engine flags and per-pair metrics; the label formats seconds")
    func v2Fields() throws {
        let catalog = try decode("""
            {"version":2,"stt":{},"ttsOutgoing":{},"ttsIncoming":{},
             "engines":{"edgeTTS":{"unavailable":true}},
             "pairs":{"de|es":{"whisper":{"tested":true,"latencyMs":400},"voiceClone":{"latencyMs":500}}}}
            """)
        #expect(catalog.isUnavailable(.edgeTTS))
        let whisper = try #require(catalog.metrics(for: PairKey("es", "de"), engine: "whisper"))
        #expect(whisper.tested)
        #expect(whisper.latencyLabel(isVoice: false) == "~0.4 s")
        let clone = try #require(catalog.metrics(for: PairKey("de", "es"), engine: "voiceClone"))
        #expect(!clone.tested)
        #expect(clone.latencyLabel(isVoice: true) == "~0.5 s to first audio")
        #expect(catalog.metrics(for: PairKey("en", "es"), engine: "whisper") == nil)
        #expect(EngineMetrics(tested: true).latencyLabel(isVoice: false) == nil)
    }

    @Test("the bundled catalog and the built-in fallback mark Edge unavailable (A27) and carry no pair data")
    func bundledMarksEdgeUnavailable() {
        for catalog in [ModelCatalog.bundled, .builtIn] {
            #expect(catalog.version == 2)
            #expect(catalog.isUnavailable(.edgeTTS))
            #expect(catalog.pairs.isEmpty)
        }
    }
}
