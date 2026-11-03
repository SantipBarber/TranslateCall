import Foundation
@testable import TranslateCall

/// Runs one scenario on a real-time bench session and writes `<out>/<name>/scenario.json`
/// (M9 scenario-tests design §3.3).
@MainActor
enum ScenarioRunner {
    /// Longest wait for the pipeline to settle after a clip.
    private static let idleTimeout = Duration.seconds(20)

    struct Result: Codable {
        struct Event: Codable {
            let direction: String
            let seq: Int
            let stage: String
            /// Since the session's origin.
            let ms: Double
            let detail: [String: String]
        }

        let scenario: String
        let commit: String
        let clips: [String]
        let verdicts: [ScenarioVerdict]
        let events: [Event]
        /// TTS buffers scheduled, ms since the origin.
        let scheduledMs: [Double]
        let lastClipEndMs: Double

        var passed: Bool { verdicts.allSatisfy(\.passed) }
    }

    static func run(_ scenario: Scenario, env: BenchEnvironment) async throws -> Result {
        let manifest = try JSONDecoder().decode(BenchManifest.self, from: Data(contentsOf: env.manifest))
        let clips = Array(manifest.clips(variant: scenario.line.variant, set: "pr").prefix(scenario.clipLimit))
        try requirePrerequisite(!clips.isEmpty, "no \(scenario.line.variant) clips in the PR set")

        let session = try await BenchPipelineFactory.make(
            scenario.line, options: env.options(for: scenario.profile),
            output: { mic, system in
                BenchOutput(realtime: .init(
                    playedLatency: scenario.playedLatency,
                    routes: scenario.echoes.map { echo in
                        BenchOutput.EchoRoute(from: echo.from,
                                              to: echo.from == .incoming ? mic.player : system.player,
                                              gain: echo.gain, delay: echo.delay)
                    }))
            })
        session.coordinator.listeningMode = scenario.listeningMode
        do {
            let result = try await play(scenario, clips: clips, session: session, env: env)
            await session.tearDown()
            try write(result, to: env.out.appending(path: scenario.name))
            return result
        } catch {
            await session.tearDown()
            throw error
        }
    }

    private static func play(_ scenario: Scenario, clips: [BenchManifest.Clip], session: BenchSession,
                             env: BenchEnvironment) async throws -> Result {
        try await BenchPipelineFactory.start(session, options: env.options(for: scenario.profile))
        await session.player.playSilence(seconds: 2)   // translation warm-up
        let pause = ConversationSettings.defaultPauseSeconds
        var lastClipEnd = ContinuousClock.now
        for clip in clips {
            let feed = await session.player.play(try BenchRunner.loadClip(clip, cache: env.cache))
            lastClipEnd = feed.end
            await settle(session, after: feed.end, pause: pause)
        }
        // Keep the stream running: a loop feeds itself through the echo routes with no clip playing.
        let observeEnd = lastClipEnd + scenario.observeAfter
        while ContinuousClock.now < observeEnd {
            await session.player.playSilence(seconds: 0.5)
        }
        let events = session.sink.events
        let schedules = session.output.scheduleTimes
        let seen = ScenarioObservation(events: events, clipCount: clips.count, lastClipEnd: lastClipEnd,
                                       scheduleTimes: schedules)
        let origin = session.origin
        func ms(_ instant: ContinuousClock.Instant) -> Double { origin.duration(to: instant).milliseconds }
        return Result(
            scenario: scenario.name,
            commit: env.commit,
            clips: clips.map(\.id),
            verdicts: scenario.rules.map { $0.check(seen) },
            events: events.sorted { $0.time < $1.time }.map {
                .init(direction: $0.direction.rawValue, seq: $0.seq, stage: $0.stage.rawValue, ms: ms($0.time),
                      detail: $0.detail)
            },
            scheduledMs: schedules.map(ms),
            lastClipEndMs: ms(lastClipEnd)
        )
    }

    /// Silence until neither direction has an utterance in flight and `pause + 0.5 s` passed, or the timeout.
    private static func settle(_ session: BenchSession, after end: ContinuousClock.Instant, pause: Double) async {
        let settled = end + .seconds(pause + 0.5)
        let deadline = end + idleTimeout
        while ContinuousClock.now < deadline {
            let idle = session.tracer.openSeqs.isEmpty && session.otherTracer.openSeqs.isEmpty
            if idle && ContinuousClock.now >= settled { return }
            await session.player.playSilence(seconds: 0.1)
        }
    }

    private static func write(_ result: Result, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var bytes = try encoder.encode(result)
        bytes.append(0x0A)
        try bytes.write(to: directory.appending(path: "scenario.json"))
    }
}
