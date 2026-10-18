import Foundation
import Testing
@testable import TranslateCall

@MainActor
private func freshDefaults() -> UserDefaults {
    let name = "PairModelChoicesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Per-pair model choices (M9 UI settings REQ-ST-01)") @MainActor
struct PairModelChoicesTests {

    @Test("a pair has no order: ES ↔ DE is DE ↔ ES; the storage key round-trips")
    func pairKeyIsUnordered() throws {
        #expect(PairKey("es", "de") == PairKey("de", "es"))
        #expect(PairKey("es", "de").storageKey == "de|es")
        #expect(PairKey(Locale.Language(identifier: "es-ES"), Locale.Language(identifier: "de")) == PairKey("de", "es"))
        #expect(try #require(PairKey(storageKey: "de|es")) == PairKey("es", "de"))
        #expect(PairKey(storageKey: "nope") == nil)
    }

    @Test("choices persist across instances; an empty choice removes the pair")
    func persistAndRemove() {
        let defaults = freshDefaults()
        let store = PairModelChoices(defaults: defaults)
        store.set(PairModelChoice(stt: .appleSpeech), for: PairKey("es", "de"))
        #expect(PairModelChoices(defaults: defaults).choice(for: PairKey("de", "es")).stt == .appleSpeech)

        store.set(PairModelChoice(), for: PairKey("es", "de"))
        #expect(PairModelChoices(defaults: defaults).all.isEmpty)
        #expect(store.choice(for: PairKey("es", "de")).isEmpty)
    }

    @Test("the voice clone is never stored as a pair's voice (S-6)")
    func voiceCloneNeverStored() {
        #expect(PairModelChoice(voice: .voiceClone).voice == nil)
    }

    @Test("unknown engine names decode as nil; a corrupt value is an empty store")
    func tolerantDecoding() throws {
        let defaults = freshDefaults()
        let json = #"{"de|es":{"stt":"futureEngine","voice":"kokoro"}}"#
        defaults.set(Data(json.utf8), forKey: PairModelChoices.defaultsKey)
        let choice = PairModelChoices(defaults: defaults).choice(for: PairKey("es", "de"))
        #expect(choice == PairModelChoice(voice: .kokoro))

        defaults.set(Data("{ nope".utf8), forKey: PairModelChoices.defaultsKey)
        #expect(PairModelChoices(defaults: defaults).all.isEmpty)
    }
}
