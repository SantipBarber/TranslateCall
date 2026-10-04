import AVFoundation
import CoreAudio
import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("TTS playback through BlackHole", .serialized) @MainActor
    struct TTSPlaybackIntegrationTests {
        private let sentence = "The quick brown fox jumps over the lazy dog, then rests in the warm afternoon sun."

        @Test("TTSOutput opens the default output, and refuses a device that does not exist")
        func outputDevices() throws {
            let output = try TTSOutput(deviceID: nil)
            output.shutdown()
            #expect(throws: STSError.deviceRoutingFailed) { _ = try TTSOutput(deviceID: AudioDeviceID(99_999)) }
        }

        @Test("AVSpeech through TTSPlaybackService into BlackHole: audio arrives, tail not cut, isSpeaking false within 150 ms (A12, NFR-T-02)")
        func avSpeechThroughBlackHole() async throws {
            try await requireMicrophoneAuthorization()
            try requirePrerequisite(AVSpeechUtteranceSynthesizer.hasVoice(for: english), "an English system voice")
            let manager = AudioManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
            let blackHole = try requireBlackHole(in: manager.inputDevices)
            try manager.selectInput(blackHole)
            let log = BufferLog(try await manager.startCapture())
            defer { log.cancel(); manager.stopCapture() }

            let output = RecordingOutput(wrapping: try TTSOutput(deviceID: blackHole.id))
            let service = TTSPlaybackService(primary: AVSpeechUtteranceSynthesizer(), output: output)
            let speaking = StreamRecorder(service.isSpeakingStream)
            let start = ContinuousClock.now
            await service.speak(text: sentence, locale: english)

            #expect(await waitUntil(timeout: .seconds(30)) { speaking.values == [true, false] },
                    "isSpeaking did not go true → false within 30 s")
            let falseAt = try #require(speaking.timed.last?.at)
            // BlackHole keeps delivering (silent) buffers: wait until capture has moved 300 ms past the end.
            #expect(await waitUntil(timeout: .seconds(2)) { (log.entries.last?.at ?? start) > falseAt + .milliseconds(300) })
            await service.deactivate()

            let first = try #require(log.firstEntry(since: start, threshold: -70), "no TTS audio reached BlackHole")
            let last = try #require(log.lastEntry(since: start, threshold: -70))
            let trailing = output.trailingSilence
            // BufferLog stamps each buffer at its first sample's capture instant (arrival minus one tap
            // block); BlackHole's loopback and the main-actor hop can still put it up to ~60 ms late.
            print("[TTS-latency] last.at - falseAt = \(last.at - falseAt)")
            #expect(falseAt >= last.at - .milliseconds(60),
                    "isSpeaking went false \(last.at - falseAt) before the last captured audio (NFR-T-02)")
            #expect(falseAt - last.at <= .milliseconds(150) + trailing,
                    "isSpeaking went false \(falseAt - last.at) after the last captured audio (NFR-T-02)")
            let heard = last.at - first.at + last.duration
            #expect(heard >= output.scheduledDuration * 0.8,
                    "heard \(heard) of \(output.scheduledDuration) scheduled: the tail was cut (A12)")
        }
    }
}
