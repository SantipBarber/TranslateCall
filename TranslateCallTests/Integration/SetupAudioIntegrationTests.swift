import AVFoundation
import Testing
@testable import TranslateCall

/// Races `body` against the deadline: when the deadline wins, `body` is cancelled and nil returned,
/// so a wait is bounded even when no sample ever arrives (a hung CoreAudio tap must not hang tests).
@MainActor
private func withDeadline<T: Sendable>(
    _ deadline: Duration,
    _ body: @escaping @MainActor @Sendable () async -> T?
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await Task.sleep(for: deadline)
            return nil
        }
        let winner = await group.next() ?? nil
        group.cancelAll()
        return winner
    }
}

/// Consumes an `InputLevelSource` stream until a sustained level is reached or the deadline passes.
@MainActor
private func sustainedLevelPasses(
    _ stream: AsyncStream<LevelSample>,
    threshold: Float,
    minDuration: Duration,
    within timeout: Duration
) async -> Bool {
    let passed = await withDeadline(timeout) {
        var detector = SustainedLevelDetector(threshold: threshold, minDuration: minDuration)
        for await sample in stream { if detector.feed(sample) { return true } }
        return false
    }
    return passed ?? false
}

/// The quiet baseline the route check needs: 300 ms of samples, all below the threshold.
private struct QuietBaseline: Sendable {
    var sawSample = false
    var filled = false
    var allQuiet = true
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

            // Bounded to 3 s: BlackHole may deliver no samples at all (the bug that hung `just pr`).
            let baseline = await withDeadline(.seconds(3)) { () -> QuietBaseline? in
                var result = QuietBaseline()
                var total: Duration = .zero
                for await sample in stream {
                    result.sawSample = true
                    if sample.dbfs >= -70 { result.allQuiet = false }
                    total += sample.duration
                    if total >= .milliseconds(300) { result.filled = true; return result }
                }
                return result
            }
            guard let baseline else {
                Issue.record("BlackHole delivered no samples")
                return
            }
            #expect(baseline.filled)
            #expect(baseline.allQuiet)
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
