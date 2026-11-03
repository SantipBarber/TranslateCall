import AVFoundation
import Foundation
import Testing
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
        let reference = try await overrideReference(session)
        do {
            let result = try await play(scenario, clips: clips, session: session, env: env, reference: reference)
            await session.tearDown()
            try write(result, to: env.out.appending(path: scenario.name))
            return result
        } catch {
            await session.tearDown()
            throw error
        }
    }

    private static func play(_ scenario: Scenario, clips: [BenchManifest.Clip], session: BenchSession,
                             env: BenchEnvironment, reference: [Float]?) async throws -> Result {
        try await BenchPipelineFactory.start(session, options: env.options(for: scenario.profile))
        await session.player.playSilence(seconds: 2)   // translation warm-up
        let pause = ConversationSettings.defaultPauseSeconds
        var lastClipEnd = ContinuousClock.now
        var audio = AudioCollector()
        for clip in clips {
            let feed = await session.player.play(try BenchRunner.loadClip(clip, cache: env.cache))
            lastClipEnd = feed.end
            await settle(session, after: feed.end, pause: pause)
            audio.add(session.output.drain(), events: session.sink.events.filter { $0.direction == .outgoing })
        }
        // Keep the stream running: a loop feeds itself through the echo routes with no clip playing.
        let observeEnd = lastClipEnd + scenario.observeAfter
        while ContinuousClock.now < observeEnd {
            await session.player.playSilence(seconds: 0.5)
        }
        let events = session.sink.events
        let schedules = session.output.scheduleTimes
        var seen = ScenarioObservation(events: events, clipCount: clips.count, lastClipEnd: lastClipEnd,
                                       scheduleTimes: schedules)
        if scenario.rules.contains(where: { if case .pitchNearReference = $0 { true } else { false } }) {
            seen.outgoingF0 = audio.attempts.compactMapValues { PitchEstimator.medianF0($0.samples, rate: $0.rate) }
            if let reference {
                seen.referenceF0 = PitchEstimator.medianF0(reference, rate: 24_000)
            } else {
                seen.referenceF0 = try await referenceF0(session)
            }
            try audio.write(to: env.out.appending(path: scenario.name).appending(path: "audio"))
        }
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

    /// `TC_SCENARIO_REFERENCE=<file>.wav` (24 kHz mono, transcript in `<file>.txt`): the clone uses that
    /// recording instead of the active profile, to compare references. Returns its samples.
    private static func overrideReference(_ session: BenchSession) async throws -> [Float]? {
        guard let path = ProcessInfo.processInfo.environment["TC_SCENARIO_REFERENCE"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        try requirePrerequisite(file.processingFormat.sampleRate == 24_000 && file.processingFormat.channelCount == 1,
                                "TC_SCENARIO_REFERENCE must be 24 kHz mono")
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
        let transcript = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        let header = VoiceProfileHeader(
            id: UUID(), name: url.lastPathComponent, createdAt: .now,
            durationSeconds: Float(samples.count) / 24_000, sampleRate: 24_000, sampleCount: samples.count,
            quality: VoiceQualityMetrics(peakRmsDbfs: -20, hasClipping: false,
                                         voicedDurationSeconds: Float(samples.count) / 24_000, grade: .good),
            formatVersion: 1)
        let store = MockVoiceProfileStore()
        await store.forceStore(VoiceProfile(header: header, samples: samples,
                                            transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines)))
        session.tts.setProfileStore(store)
        session.tts.activeVoiceProfileId = header.id
        print("SCENARIO reference override: \(url.lastPathComponent)")
        return samples
    }

    /// The active voice profile's median F0 (decrypted in memory, never written).
    private static func referenceF0(_ session: BenchSession) async throws -> Double? {
        guard let id = session.tts.activeVoiceProfileId else { return nil }
        let profile = try await VoiceProfileStore().load(id: id)
        return profile.samples.flatMap { PitchEstimator.medianF0($0, rate: 24_000) }
    }

    /// Silence until the measured direction has no utterance in flight and `pause + 0.5 s` passed, or the
    /// timeout. The other direction is not waited for: an echo the guard dropped stays open in its trace.
    private static func settle(_ session: BenchSession, after end: ContinuousClock.Instant, pause: Double) async {
        let settled = end + .seconds(pause + 0.5)
        let deadline = end + idleTimeout
        while ContinuousClock.now < deadline {
            let idle = session.tracer.openSeqs.isEmpty
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
