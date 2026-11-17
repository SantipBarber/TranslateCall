import AVFoundation
import Testing
@testable import TranslateCall

/// Consumes an `InputLevelSource` stream until a sustained level is reached or the deadline passes.
@MainActor
private func sustainedLevelPasses(
    _ stream: AsyncStream<LevelSample>,
    threshold: Float,
    minDuration: Duration,
    within timeout: Duration
) async -> Bool {
    var detector = SustainedLevelDetector(threshold: threshold, minDuration: minDuration)
    let deadline = ContinuousClock.now + timeout
    for await sample in stream {
        if detector.feed(sample) { return true }
        if ContinuousClock.now >= deadline { return false }
    }
    return false
}

extension IntegrationTests {
    @Suite("Setup audio sources (REQ-FR-40…55)", .serialized) @MainActor
    struct SetupAudioIntegrationTests {

        private func fixtureURL() throws -> URL {
            try Fixtures.url(for: #require(Fixtures.lang("en").first))
        }

        private func blackHole() async throws -> AudioDevice {
            try await requireMicrophoneAuthorization()
            return try requireBlackHole(in: CoreAudioDevices.allDevices())
        }

        @Test("listener hears audio played into BlackHole 2ch")
        func listenerHearsBlackHole() async throws {
            let blackHole = try await blackHole()
            let source = InputLevelSource(deviceID: blackHole.id, records: false)
            let stream = try source.start()
            defer { source.stop() }

            let player = try BlackHolePlayer(fixtureURL: try fixtureURL(), deviceID: blackHole.id)
            defer { player.stop() }

            #expect(await sustainedLevelPasses(stream, threshold: -70,
                                               minDuration: .milliseconds(200), within: .seconds(3)))
        }

        @Test("listener baseline is silent when nothing plays into BlackHole")
        func listenerSilentBaseline() async throws {
            let blackHole = try await blackHole()
            let source = InputLevelSource(deviceID: blackHole.id, records: false)
            let stream = try source.start()
            defer { source.stop() }

            var total: Duration = .zero
            var allQuiet = true
            for await sample in stream {
                if sample.dbfs >= -70 { allQuiet = false }
                total += sample.duration
                if total >= .milliseconds(300) { break }
            }
            #expect(allQuiet)
        }

        @Test("system voice phrase reaches BlackHole 2ch")
        func phraseReachesBlackHole() async throws {
            let blackHole = try await blackHole()
            let source = InputLevelSource(deviceID: blackHole.id, records: false)
            let stream = try source.start()
            defer { source.stop() }

            let heard = Task { @MainActor in
                await sustainedLevelPasses(stream, threshold: -70,
                                           minDuration: .milliseconds(200), within: .seconds(5))
            }
            try await SystemVoicePhrasePlayer().play(on: blackHole.id)
            let passed = await heard.value
            #expect(passed)
        }

        @Test("recording keeps the audio that reached BlackHole")
        func recordingKeepsAudio() async throws {
            let blackHole = try await blackHole()
            let source = InputLevelSource(deviceID: blackHole.id, records: true)
            _ = try source.start()
            defer { source.stop() }

            try await SystemVoicePhrasePlayer().play(on: blackHole.id)
            #expect(!source.recording.isEmpty)
        }
    }
}
