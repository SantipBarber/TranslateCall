import Foundation
import Testing
@testable import TranslateCall

@Suite("Settings › Advanced logic (M9 UI settings REQ-ST-30…35)") @MainActor
struct AdvancedSettingsLogicTests {

    @Test("pairs: the three priority pairs, then the current one, then customised ones, no duplicates")
    func pairsList() {
        let list = AdvancedPairs.list(current: PairKey("fr", "es"),
                                      customized: [PairKey("en", "es"), PairKey("uk", "en")])
        #expect(list == [PairKey("es", "de"), PairKey("es", "en"), PairKey("de", "en"), PairKey("es", "fr"),
                         PairKey("en", "uk")])
        #expect(AdvancedPairs.list(current: PairKey("de", "es"), customized: []).count == 3)
    }

    @Test("a pair's title names my language first, else Spanish, German, English, else alphabetical")
    func titleOrder() {
        #expect(AdvancedPairs.ordered(PairKey("de", "es"), currentSource: "de") == ("de", "es"))
        #expect(AdvancedPairs.ordered(PairKey("de", "es"), currentSource: "fr") == ("es", "de"))
        #expect(AdvancedPairs.ordered(PairKey("en", "de"), currentSource: "fr") == ("de", "en"))
        #expect(AdvancedPairs.ordered(PairKey("uk", "fr"), currentSource: "es") == ("fr", "uk"))
    }

    @Test("the row value: Recommended, or Custom · the chosen engine (speech recognition first)")
    func rowValue() {
        #expect(AdvancedPairs.value(for: PairModelChoice()) == "Recommended")
        #expect(AdvancedPairs.value(for: PairModelChoice(stt: .appleSpeech, voice: .kokoro)) == "Custom · Apple Speech")
        #expect(AdvancedPairs.value(for: PairModelChoice(voice: .avSpeech)) == "Custom · Apple voices")
    }

    @Test("the voice detector: Silero by default; Basic makes the next session use the energy VAD (REQ-ST-33)")
    func voiceDetector() async {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        #expect(VADPreference.engine(in: defaults) == .silero)
        VADPreference.set(.energy, in: defaults)
        #expect(VADPreference.engine(in: defaults) == .energy)
        let provider = VADProvider(loadSilero: { _ in MockVADService(engine: .silero) },
                                   preferred: { VADPreference.engine(in: defaults) })
        #expect(await provider.makeVAD(config: VADConfiguration()).engine == .energy)
        VADPreference.set(.silero, in: defaults)
        #expect(await provider.makeVAD(config: VADConfiguration()).engine == .silero)
    }

    @Test("exported logs: one line per entry with time and category; the file name carries the date")
    func logText() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_792_256_662.5)   // 2026-10-17 17:04:22.500 UTC
        let text = LogExporter.text([LogLine(date: date, category: "VADProvider", message: "Silero VAD model ready")],
                                    timeZone: utc)
        #expect(text == "2026-10-17 17:04:22.500 [VADProvider] Silero VAD model ready\n")
        #expect(LogExporter.text([]) == "")
        #expect(LogExporter.fileName(on: date, timeZone: utc) == "TranslateCall-logs-2026-10-17.txt")
    }
}
