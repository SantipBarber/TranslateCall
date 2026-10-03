import AVFoundation
import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("TTS", .serialized) @MainActor
    struct TTSFixtureTests {
        @Test("AVSpeech produces audio", arguments: ["es-ES", "en-US", "uk-UA"])
        func avSpeech(_ lang: String) async throws {
            let locale = Locale(identifier: lang)
            try requirePrerequisite(AVSpeechService.hasVoice(for: locale), "system voice for \(lang)")
            let tts = try AVSpeechService(outputDeviceID: nil) // default output: audible during the run
            let monitor = try TTSAudioMonitor()
            monitor.isEnabled = true
            let file = try monitor.startRecording()
            await tts.setAudioMonitor(monitor)

            var events = tts.isSpeakingStream.makeAsyncIterator()
            let text = lang.hasPrefix("uk") ? "Добрий день" : lang.hasPrefix("es") ? "Hola" : "Hello"
            await tts.speak(text: text, locale: locale)

            var sawStart = false, sawEnd = false
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline, !sawEnd, let speaking = await events.next() {
                if speaking { sawStart = true } else if sawStart { sawEnd = true }
            }
            _ = monitor.stopRecording()
            await tts.deactivate()

            #expect(sawStart && sawEnd, "isSpeakingStream did not report start→end")
            let frames = (try? AVAudioFile(forReading: file).length) ?? 0
            #expect(frames > 0, "no audio recorded for \(lang)")
        }
    }
}
