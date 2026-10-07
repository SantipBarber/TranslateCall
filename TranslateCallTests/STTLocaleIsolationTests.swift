import Foundation
import Testing
@testable import TranslateCall

private struct NoModel: Error {}

/// `locale` is read without `await` and written by `setLocale` on the actor (F8.5.4 REQ-TR-60).
/// No model is loaded: the factories are never called before `activate`.
@Suite("STT locale isolation (F8.5.4)")
struct STTLocaleIsolationTests {

    private static func services() -> [any SpeechRecognizerService] {
        [
            AppleSpeechService(locale: Locale(identifier: "es-ES")),
            WhisperSpeechService(locale: Locale(identifier: "es-ES"), pipeFactory: { throw NoModel() }),
            ParakeetSpeechService(locale: Locale(identifier: "es-ES"), transcriberFactory: { throw NoModel() }),
        ]
    }

    @Test("setLocale is visible to nonisolated reads")
    func setLocaleVisible() async {
        for service in Self.services() {
            #expect(service.locale == Locale(identifier: "es-ES"))
            await service.setLocale(Locale(identifier: "uk-UA"))
            #expect(service.locale == Locale(identifier: "uk-UA"), "\(type(of: service))")
        }
    }

    @Test("reads from other tasks while the actor writes always see a whole value")
    func concurrentReads() async {
        let locales = [Locale(identifier: "es-ES"), Locale(identifier: "en-US"), Locale(identifier: "uk-UA")]
        for service in Self.services() {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for index in 0..<300 { await service.setLocale(locales[index % 3]) }
                    return true
                }
                for _ in 0..<4 {
                    group.addTask { (0..<300).allSatisfy { _ in locales.contains(service.locale) } }
                }
                for await allValid in group { #expect(allValid) }
            }
        }
    }
}
