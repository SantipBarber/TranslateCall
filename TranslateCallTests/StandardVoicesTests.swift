import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

@Suite("Standard voices (M9 UI settings REQ-ST-22)") @MainActor
struct StandardVoicesTests {

    private let installed = [
        SystemVoice(identifier: "de.anna", name: "Anna", language: "de-DE", quality: 1),
        SystemVoice(identifier: "de.helena", name: "Helena", language: "de-DE", quality: 2),
        SystemVoice(identifier: "de.petra", name: "Petra", language: "de-AT", quality: 3),
        SystemVoice(identifier: "es.monica", name: "Mónica", language: "es-ES", quality: 1)
    ]

    @Test("Apple options: Automatic first, then the language's voices, best quality first")
    func appleOptions() {
        let options = StandardVoices.appleOptions(for: Locale(identifier: "de-DE"), installed: installed)
        #expect(options.map(\.id) == ["", "de.petra", "de.helena", "de.anna"])
        #expect(options.map(\.name) == ["Automatic", "Petra (Premium) · Apple", "Helena (Enhanced) · Apple",
                                        "Anna · Apple"])
    }

    @Test("the pick is stored per language; empty means Automatic")
    func preferenceRoundTrip() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let german = Locale(identifier: "de-DE")
        #expect(SystemVoicePreference.identifier(for: german, defaults: defaults) == nil)
        SystemVoicePreference.set("de.anna", for: "de", defaults: defaults)
        #expect(SystemVoicePreference.identifier(for: german, defaults: defaults) == "de.anna")
        #expect(SystemVoicePreference.identifier(for: Locale(identifier: "es-ES"), defaults: defaults) == nil)
        SystemVoicePreference.set(nil, for: "de", defaults: defaults)
        #expect(SystemVoicePreference.identifier(for: german, defaults: defaults) == nil)
    }

    @Test("a picked voice that is not installed falls back to the best voice")
    func missingVoiceFallsBack() {
        let locale = Locale(identifier: "en-US")
        #expect(AVSpeechUtteranceSynthesizer.voice(for: locale, preferred: "not.a.voice")?.identifier
                == AVSpeechUtteranceSynthesizer.bestVoice(for: locale)?.identifier)
    }

    @Test("Kokoro keeps the legacy list; Edge shows its fixed voice")
    func kokoroAndEdge() {
        #expect(StandardVoices.kokoroOptions.first == VoiceOption(id: "", name: "Default (af_heart)"))
        #expect(StandardVoices.kokoroOptions.count == 5)
        #expect(StandardVoices.edgeVoiceName(for: Locale(identifier: "uk-UA")) != nil)
        #expect(StandardVoices.edgeVoiceName(for: Locale(identifier: "xx")) == nil)
    }
}
