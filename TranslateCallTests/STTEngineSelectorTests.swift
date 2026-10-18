import Foundation
import Testing
@testable import TranslateCall

/// Records which STT factory a selector used.
@MainActor
private final class STTPicks {
    var used: [String] = []
    func factory(_ name: String) -> (Locale) -> any SpeechRecognizerService {
        { [weak self] locale in self?.used.append(name); return MockSpeechRecognizerService(locale: locale) }
    }
}

@MainActor
private func makeSTT(_ picks: STTPicks, probe: ModelCacheProbe,
                     choice: PairModelChoice = PairModelChoice()) -> STTEngineSelector {
    let selector = STTEngineSelector(appleSpeechFactory: picks.factory("apple"),
                                     parakeetFactory: picks.factory("parakeet"), whisperFactory: picks.factory("whisper"))
    selector.catalog = .builtIn
    selector.cacheProbe = probe
    selector.pairChoice = { choice }
    return selector
}

private let cachedAll = ModelCacheProbe(parakeet: { true }, whisper: { true }, kokoro: { true }, voiceClone: { false })

@Suite("STTEngineSelector (M9 UI settings REQ-ST-02)") @MainActor
struct STTEngineSelectorTests {

    @Test("recommended: the catalog with what is on disk, per direction")
    func recommended() {
        let picks = STTPicks()
        let stt = makeSTT(picks, probe: cachedAll)
        _ = stt.makeOutgoingService(for: Locale(identifier: "en-US"))
        _ = stt.makeIncomingService(for: Locale(identifier: "en-US"))
        _ = stt.makeOutgoingService(for: Locale(identifier: "es-ES"))
        #expect(picks.used == ["parakeet", "whisper", "whisper"])
    }

    @Test("nothing on disk → Apple Speech, even with Parakeet chosen for the pair")
    func nothingOnDisk() {
        let picks = STTPicks()
        let stt = makeSTT(picks, probe: .none, choice: PairModelChoice(stt: .parakeet))
        _ = stt.makeOutgoingService(for: Locale(identifier: "en-US"))
        #expect(picks.used == ["apple"])
    }

    @Test("the pair's choice wins where it is usable; elsewhere the catalog decides (REQ-ST-03)")
    func pairChoice() {
        let picks = STTPicks()
        let stt = makeSTT(picks, probe: cachedAll, choice: PairModelChoice(stt: .parakeet))
        _ = stt.makeOutgoingService(for: Locale(identifier: "en-US"))   // Parakeet: English, outgoing
        _ = stt.makeIncomingService(for: Locale(identifier: "es-ES"))   // not Spanish → catalog: Whisper
        #expect(picks.used == ["parakeet", "whisper"])
        #expect(stt.resolvedEngine(for: Locale(identifier: "en-US"), direction: .incoming) == .whisper)
    }
}
