import AVFoundation
import Testing
@testable import TranslateCall

@Suite("TTSPlaybackService fallback and breaker")
struct TTSPlaybackFallbackTests {
    private let failing = FakeSynthesizer.Script(failAfter: 0)
    private let ukrainian = Locale(identifier: "uk-UA")

    private func edge(_ scripts: [FakeSynthesizer.Script]) -> FakeSynthesizer {
        FakeSynthesizer(engine: .edgeTTS, scripts: scripts)
    }

    @Test("the primary fails before any audio: the fallback speaks the same utterance and .fellBack is emitted (REQ-T-20/22)")
    func fallsBackBeforeAudio() async {
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let harness = TTSPlaybackHarness(primary: edge([failing]), fallback: fallback,
                                         output: FakeOutput(autoComplete: true))
        await harness.service.speak(text: "hola", locale: english)
        #expect(await waitUntil { fallback.texts == ["hola"] })
        #expect(await waitUntil { harness.events.values == [.fellBack(from: .edgeTTS, to: .avSpeech)] })
        #expect(await waitUntil { await harness.metrics.recent.map(\.engine) == [.avSpeech] })
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("the primary fails after audio started: the rest is dropped, .interrupted, no fallback (REQ-T-21)")
    func interruptedAfterAudio() async {
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let harness = TTSPlaybackHarness(primary: edge([FakeSynthesizer.Script(failAfter: 1)]), fallback: fallback)
        await harness.service.speak(text: "half", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 && harness.speaking.values == [true] })

        harness.output.completeAll()                      // the part already heard plays out first

        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.interrupted)] })
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(fallback.texts.isEmpty)
        await harness.service.deactivate()
    }

    @Test("the fallback cannot speak the locale: skipped with .primaryFailed (REQ-T-20)")
    func fallbackCannotSpeak() async {
        let fallback = FakeSynthesizer(engine: .avSpeech, canSpeak: { _ in false })
        let harness = TTSPlaybackHarness(primary: edge([failing]), fallback: fallback)
        await harness.service.speak(text: "x", locale: ukrainian)
        let expected = TTSEvent.utteranceSkipped(.primaryFailed(FakeSynthError.boom.localizedDescription))
        #expect(await waitUntil { harness.events.values == [expected] })
        #expect(fallback.texts.isEmpty)
        await harness.service.deactivate()
    }

    @Test("neither engine can speak the locale: skipped with .noVoice")
    func neitherCanSpeak() async {
        let primary = FakeSynthesizer(engine: .edgeTTS, canSpeak: { _ in false })
        let fallback = FakeSynthesizer(engine: .avSpeech, canSpeak: { _ in false })
        let harness = TTSPlaybackHarness(primary: primary, fallback: fallback)
        await harness.service.speak(text: "x", locale: Locale(identifier: "xx-XX"))
        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.noVoice)] })
        #expect(primary.texts.isEmpty && fallback.texts.isEmpty)
        await harness.service.deactivate()
    }

    @Test("the primary cannot speak the locale but the fallback can: the fallback speaks, .fellBack")
    func primaryCannotSpeak() async {
        let primary = FakeSynthesizer(engine: .kokoro, canSpeak: { _ in false })
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let harness = TTSPlaybackHarness(primary: primary, fallback: fallback, output: FakeOutput(autoComplete: true))
        await harness.service.speak(text: "bonjour", locale: Locale(identifier: "fr-FR"))
        #expect(await waitUntil { fallback.texts == ["bonjour"] })
        #expect(await waitUntil { harness.events.values == [.fellBack(from: .kokoro, to: .avSpeech)] })
        #expect(primary.texts.isEmpty)
        await harness.service.deactivate()
    }

    @Test("the fallback fails too: one .primaryFailed skip, and the breaker only counts the primary")
    func fallbackFailsToo() async {
        let fallback = FakeSynthesizer(engine: .avSpeech, scripts: [failing])
        let harness = TTSPlaybackHarness(primary: edge([failing]), fallback: fallback)
        await harness.service.speak(text: "x", locale: english)
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(await waitUntil { harness.events.values.count == 2 })
        #expect(harness.events.values.last == .utteranceSkipped(.primaryFailed(FakeSynthError.boom.localizedDescription)))
        #expect(!(await harness.service.isBreakerOpen))
        await harness.service.deactivate()
    }

    @Test("3 primary failures in a row: fallback only for 30 s, then the primary is tried again (REQ-T-23)")
    func breaker() async {
        let primary = edge([failing])
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let harness = TTSPlaybackHarness(primary: primary, fallback: fallback, output: FakeOutput(autoComplete: true))
        for index in 1...3 {
            await harness.service.speak(text: "s\(index)", locale: english)
            #expect(await waitUntil { fallback.texts.count == index })
        }
        #expect(await harness.service.isBreakerOpen)

        await harness.service.speak(text: "s4", locale: english)
        #expect(await waitUntil { fallback.texts.count == 4 })
        #expect(primary.texts.count == 3, "the open breaker still tried the primary")

        #expect(await waitUntil { harness.clock.pendingDeadlines == [.seconds(30)] })   // only the cooldown sleeps
        harness.clock.advance(by: .seconds(30))
        #expect(await waitUntil { await !harness.service.isBreakerOpen })

        await harness.service.speak(text: "s5", locale: english)
        #expect(await waitUntil { primary.texts.count == 4 && fallback.texts.count == 5 })
        #expect(await harness.service.isBreakerOpen, "one failure after the cooldown reopens the breaker")
        await harness.service.deactivate()
    }

    @Test("a primary success resets the failure count")
    func successResets() async {
        let ok = FakeSynthesizer.Script()
        let primary = edge([failing, failing, ok, failing, failing, ok])
        let harness = TTSPlaybackHarness(primary: primary, fallback: FakeSynthesizer(engine: .avSpeech),
                                         output: FakeOutput(autoComplete: true))
        for index in 1...5 {
            await harness.service.speak(text: "s\(index)", locale: english)
            #expect(await waitUntil { harness.speaking.values.count == 2 * index })
        }
        #expect(primary.texts.count == 5)
        #expect(!(await harness.service.isBreakerOpen))
        await harness.service.deactivate()
    }

    @Test("Review focus: with no usable fallback (Edge-only locale) the breaker never diverts; every sentence tries the primary")
    func breakerNeedsAFallback() async {
        let primary = edge([failing])
        let harness = TTSPlaybackHarness(primary: primary, output: FakeOutput(autoComplete: true))
        for index in 1...4 {
            await harness.service.speak(text: "s\(index)", locale: ukrainian)
            #expect(await waitUntil { harness.speaking.values.count == 2 * index })
        }
        #expect(primary.texts.count == 4)
        #expect(await waitUntil { harness.events.values.count == 4 })
        #expect(harness.events.values.allSatisfy { event in
            if case .utteranceSkipped(.primaryFailed) = event { true } else { false }
        })
        await harness.service.deactivate()
    }
}

@Suite("TTSAudioMonitor format changes")
struct TTSAudioMonitorFormatTests {
    @Test("Review focus: a buffer in a new format (fallback engine mid-session) reconnects the monitor's player")
    func reconnectsOnNewFormat() throws {
        let edge = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let system = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        #expect(TTSAudioMonitor.needsReconnect(current: nil, incoming: edge))
        #expect(!TTSAudioMonitor.needsReconnect(current: edge, incoming: edge))
        #expect(TTSAudioMonitor.needsReconnect(current: edge, incoming: system))
    }

    @Test("Review focus: the recording keeps its first format; a fallback-format buffer is skipped, not mis-written")
    func recordingSkipsOtherFormat() throws {
        let edge = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let system = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        #expect(TTSAudioMonitor.recordingAction(pending: false, fileFormat: nil, incoming: edge) == .none)
        #expect(TTSAudioMonitor.recordingAction(pending: true, fileFormat: nil, incoming: edge) == .create)
        #expect(TTSAudioMonitor.recordingAction(pending: false, fileFormat: edge, incoming: edge) == .write)
        #expect(TTSAudioMonitor.recordingAction(pending: false, fileFormat: edge, incoming: system) == .skip)
    }
}
