import AVFoundation
import CryptoKit
import Foundation
@testable import TranslateCall

/// What the bench was asked to run, from the `TC_*` variables `just bench` sets (M9 design §3.7).
struct BenchEnvironment: Sendable {
    /// "pr" or "full".
    let set: String
    let profiles: [BenchProfile]
    let edge: Bool
    let overrideSTT: STTEngine?
    let overrideTTS: TTSEngine?
    let cache: URL
    let out: URL
    let manifest: URL
    let commit: String
    let dirty: Bool

    /// The repository root (this file is `TranslateCallTests/Bench/BenchRunner.swift`). The test host's
    /// working directory is not the repo, so relative paths in the variables resolve against this.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func current() throws -> BenchEnvironment { try parse(ProcessInfo.processInfo.environment) }

    /// The pure core of `current()`.
    static func parse(_ env: [String: String]) throws -> BenchEnvironment {
        func path(_ value: String) -> URL { URL(fileURLWithPath: value, relativeTo: root).standardizedFileURL }
        guard let out = env["TC_BENCH_OUT"], !out.isEmpty else {
            throw BenchSetupError(description: "TC_BENCH_OUT is not set — run through `just bench`")
        }
        let set = env["TC_BENCH_SET"] ?? "pr"
        guard ["pr", "full"].contains(set) else {
            throw BenchSetupError(description: "TC_BENCH_SET must be pr or full, got \(set)")
        }
        let profiles: [BenchProfile]
        switch env["TC_BENCH_PROFILE"] ?? "all" {
        case "all": profiles = [.basic, .best]
        case let name:
            guard let profile = BenchProfile(rawValue: name) else {
                throw BenchSetupError(description: "TC_BENCH_PROFILE must be basic, best or all, got \(name)")
            }
            profiles = [profile]
        }
        func engine<E: RawRepresentable>(_ key: String, as _: E.Type) throws -> E? where E.RawValue == String {
            guard let raw = env[key], !raw.isEmpty else { return nil }
            guard let value = E(rawValue: raw) else { throw BenchSetupError(description: "\(key) is unknown: \(raw)") }
            return value
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return BenchEnvironment(
            set: set,
            profiles: profiles,
            edge: ["1", "true"].contains(env["TC_BENCH_EDGE"] ?? "0"),
            overrideSTT: try engine("TC_BENCH_OVERRIDE_STT", as: STTEngine.self),
            overrideTTS: try engine("TC_BENCH_OVERRIDE_TTS", as: TTSEngine.self),
            cache: env["TC_BENCH_CACHE"].map(path) ?? home.appending(path: "Library/Caches/TranslateCallBench"),
            out: path(out),
            manifest: path(env["TC_BENCH_MANIFEST"] ?? "bench/manifests/phase1.json"),
            commit: env["TC_COMMIT"] ?? "unknown",
            dirty: ["1", "true"].contains(env["TC_DIRTY"] ?? "0")
        )
    }

    func options(for profile: BenchProfile) -> BenchOptions {
        BenchOptions(profile: profile, edge: edge, overrideSTT: overrideSTT, overrideTTS: overrideTTS)
    }
}

extension BenchRunLine {
    /// Directory name under `<out>/<profile>/`: `outgoing-es-ES-en`, `incoming-en-es`.
    var slug: String { "\(direction.rawValue)-\(variant)-\(incoming ? userLanguage : otherLanguage)" }
}

/// Plays a run line's clips through a traced session in real time and writes `raw.json` (M9 REQ-BH-21…23).
@MainActor
enum BenchRunner {
    /// Longest wait for an utterance to finish after its clip (REQ-BH-21).
    private static let idleTimeout = Duration.seconds(15)

    /// Runs `line` on `profile`. Returns the `raw.json` path, or nil when the pair is skipped.
    @discardableResult
    static func run(_ line: BenchRunLine, profile: BenchProfile, env: BenchEnvironment) async throws -> URL? {
        // Best has no incoming engine of its own: those are the Basic ones (design §3.6).
        if profile == .best && line.incoming { return nil }
        let manifestData = try Data(contentsOf: env.manifest)
        let manifest = try JSONDecoder().decode(BenchManifest.self, from: manifestData)
        let options = env.options(for: profile)
        let session = try await BenchPipelineFactory.make(line, options: options)
        do {
            let run = try await play(session, manifest: manifest, manifestData: manifestData,
                                     profile: profile, options: options, env: env)
            await session.tearDown()
            return try write(run.record, audio: run.audio, to: rawDirectory(env, profile, line))
        } catch {
            await session.tearDown()
            throw error
        }
    }

    private static func play(_ session: BenchSession, manifest: BenchManifest, manifestData: Data,
                             profile: BenchProfile, options: BenchOptions, env: BenchEnvironment) async throws
        -> (record: RawRun, audio: AudioCollector) {
        let line = session.line
        try await BenchPipelineFactory.start(session, options: options)
        await session.player.playSilence(seconds: 2)   // translation warm-up (REQ-TR-05)

        let mtResults = await runMTOnly(manifest: manifest, line: line, session: session, set: env.set)

        let pause = ConversationSettings.defaultPauseSeconds   // the session's throwaway suite holds the default
        var clips: [RawRun.Clip] = []
        var audio = AudioCollector()
        for clip in manifest.clips(variant: line.variant, set: env.set) {
            let samples = try loadClip(clip, cache: env.cache)
            let feed = await session.player.play(samples)
            clips.append(RawRun.Clip(
                id: clip.id,
                feedStartNs: session.origin.nanoseconds(to: feed.start),
                feedEndNs: session.origin.nanoseconds(to: feed.end),
                speechStartNs: session.origin.nanoseconds(to: feed.instant(ofSample: Int(clip.speechStartMs * 16))),
                speechEndNs: session.origin.nanoseconds(to: feed.instant(ofSample: Int(clip.speechEndMs * 16)))
            ))
            // REQ-BH-21: the run ends by draining, never by deactivate (which drops a flushed segment).
            if !(await idleWait(session: session, feedEnd: feed.end, pause: pause)) {
                session.tracer.closeOpen(reason: "idle-timeout")
            }
            await session.player.playSilence(seconds: 0.5)
            audio.add(session.output.drain(), events: session.sink.events.filter { $0.direction == line.direction })
        }
        // Only the measured direction's events: `Utterance.from` does not filter by direction.
        let events = session.sink.events.filter { $0.direction == line.direction }
        let meta = makeMeta(session: session, options: options, env: env, events: events,
                            manifestData: manifestData, pause: pause)
        let record = RawRun(
            runId: "\(timestamp())-\(env.commit)",
            set: env.set,
            profile: profile.rawValue,
            runLine: line.description,
            informative: env.edge,
            override: overrideDescription(env),
            meta: meta,
            clips: clips,
            utterances: RawRun.Utterance.from(events, origin: session.origin) {
                audio.hasAudio(seq: $0) ? "audio/\($0).wav" : nil
            },
            mtOnly: mtResults
        )
        return (record, audio)
    }

    // MARK: - Idle wait

    /// Keeps the stream running (silence) until every utterance of the measured direction has left the
    /// pipeline and `pause + 0.5 s` passed since the clip ended, or the timeout. False on a timeout.
    private static func idleWait(session: BenchSession, feedEnd: ContinuousClock.Instant, pause: Double) async -> Bool {
        let settled = feedEnd + .seconds(pause + 0.5)
        let deadline = feedEnd + idleTimeout
        while true {
            if session.tracer.openSeqs.isEmpty && .now >= settled { return true }
            if .now >= deadline { return session.tracer.openSeqs.isEmpty }
            await session.player.playSilence(seconds: 0.1)
        }
    }

    // MARK: - MT-only

    /// Translates the manifest's MT-only sentences of the line's pair directly (untraced: the tracing
    /// wrapper only matches traced utterances), timing each call.
    private static func runMTOnly(manifest: BenchManifest, line: BenchRunLine, session: BenchSession,
                                  set: String) async -> [RawRun.MTResult] {
        let (from, to) = line.incoming ? (line.otherLanguage, line.userLanguage)
                                       : (line.userLanguage, line.otherLanguage)
        let service = line.incoming ? session.coordinator.incomingTranslationService
                                    : session.coordinator.outgoingTranslationService
        let (source, target) = (language(from), language(to))
        var results: [RawRun.MTResult] = []
        for sentence in manifest.mtOnly(from: code(from), to: code(to), set: set) {
            let start = ContinuousClock.now
            do {
                let hyp = try await service.translate(text: sentence.src, from: source, to: target)
                results.append(.init(id: sentence.id, hyp: hyp, error: nil, ms: start.duration(to: .now).milliseconds))
            } catch {
                results.append(.init(id: sentence.id, hyp: nil, error: "\(error)",
                                     ms: start.duration(to: .now).milliseconds))
            }
        }
        return results
    }

    /// What the coordinator passes to translation for a stored language.
    private static func language(_ id: String) -> Locale.Language {
        Locale.Language(identifier: Locale.Language(identifier: id).minimalIdentifier)
    }

    /// The manifest's language code (`es` for both `es-ES` and `es-419`).
    private static func code(_ id: String) -> String {
        Locale.Language(identifier: id).languageCode?.identifier ?? id
    }

    // MARK: - Clips

    private static func loadClip(_ clip: BenchManifest.Clip, cache: URL) throws -> [Float] {
        let url = cache.appending(path: clip.audio)
        let data = try Data(contentsOf: url)
        let digest = sha256Hex(data)
        guard digest == clip.sha256 else {
            throw BenchSetupError(description: "clip \(clip.id): sha256 \(digest) differs from the manifest's "
                + "\(clip.sha256) (\(url.path)) — run `just bench-fetch`")
        }
        return try FileAudioSource.decode16kMono(url)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Record

    private static func makeMeta(session: BenchSession, options: BenchOptions, env: BenchEnvironment,
                                 events: [TraceEvent], manifestData: Data, pause: Double) -> RawRun.Meta {
        let line = session.line
        func first(_ stage: TraceStage, _ key: String) -> String? {
            events.filter { $0.stage == stage }.sorted { $0.time < $1.time }.lazy.compactMap { $0.detail[key] }.first
        }
        let sttEngine = BenchPipelineFactory.sttEngine(for: line, options: options)
        let translation = line.incoming ? session.coordinator.incomingTranslationService
                                        : session.coordinator.outgoingTranslationService
        var engines: [String: String] = [
            "vad": session.vads.activeEngine.map { "\($0)" } ?? "none",
            // P8: what the coordinator hands STT (region dropped when it is the likely one).
            "sttLocale": Locale.Language(identifier: BenchPipelineFactory.recognizedLocale(line).identifier)
                .minimalIdentifier,
            "translation": translation.engineName,
            // What the profile resolves to (start asserted it), for Task 9 to compare per utterance.
            // The sttFinal `engine` detail is the recognizer's type name, so expectedSTT is that name too.
            "expectedSTT": recognizerTypeName(sttEngine),
            "expectedSTTEngine": sttEngine.rawValue,
        ]
        engines["stt"] = first(.sttFinal, "engine")
        engines["tts"] = first(.ttsFirstBuffer, "engine")
        engines["expectedTTS"] = session.builtEngines[line.direction]?.rawValue
        return RawRun.Meta(
            commit: env.commit, dirty: env.dirty, machine: sysctlString("hw.model"),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            xcode: ProcessInfo.processInfo.environment["TC_XCODE"] ?? "unknown",
            manifestSha256: sha256Hex(manifestData),
            engines: engines,
            settings: [
                "pauseSeconds": String(pause),
                "vadChunkSamples": "4096",
                "listeningMode": session.coordinator.listeningMode.rawValue,
            ]
        )
    }

    private static func recognizerTypeName(_ engine: STTEngine) -> String {
        switch engine {
        case .appleSpeech: "AppleSpeechService"
        case .parakeet: "ParakeetSpeechService"
        case .whisper: "WhisperSpeechService"
        }
    }

    private static func overrideDescription(_ env: BenchEnvironment) -> String? {
        let parts = [env.overrideSTT.map { "stt=\($0.rawValue)" }, env.overrideTTS.map { "tts=\($0.rawValue)" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    private static func rawDirectory(_ env: BenchEnvironment, _ profile: BenchProfile, _ line: BenchRunLine) -> URL {
        env.out.appending(path: profile.rawValue).appending(path: line.slug)
    }

    private static func write(_ run: RawRun, audio: AudioCollector, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try audio.write(to: directory.appending(path: "audio"))
        var bytes = try BenchJSON.encoder().encode(run)
        bytes.append(0x0A)
        let url = directory.appending(path: "raw.json")
        try bytes.write(to: url)
        return url
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// TTS output of the run, per utterance (P10): `BenchOutput.drain()` is shared by both directions and
/// untagged, but only the measured direction plays, so a buffer belongs to the utterance(s) whose
/// `ttsFirstBuffer`…`ttsEnd` window holds its schedule instant. Samples are kept as 16-bit PCM.
struct AudioCollector {
    private struct Track {
        var rate: Double
        var samples: [Int16]
    }

    private var tracks: [Int: Track] = [:]

    func hasAudio(seq: Int) -> Bool { tracks[seq] != nil }

    mutating func add(_ buffers: [(ContinuousClock.Instant, AVAudioPCMBuffer)], events: [TraceEvent]) {
        let windows: [(seq: Int, start: ContinuousClock.Instant, end: ContinuousClock.Instant)] =
            Set(events.filter { $0.stage == .ttsFirstBuffer }.map(\.seq)).sorted().compactMap { seq in
                guard let start = events.first(where: { $0.seq == seq && $0.stage == .ttsFirstBuffer })?.time,
                      let end = events.first(where: { $0.seq == seq && $0.stage == .ttsEnd })?.time else { return nil }
                return (seq, start, end)
            }
        for (instant, buffer) in buffers {
            let pcm = Self.pcm16(buffer)
            for window in windows where instant >= window.start && instant <= window.end {
                var track = tracks[window.seq] ?? Track(rate: buffer.format.sampleRate, samples: [])
                track.samples += pcm
                tracks[window.seq] = track
            }
        }
    }

    /// Writes `<seq>.wav` for each utterance that has audio.
    func write(to directory: URL) throws {
        guard !tracks.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (seq, track) in tracks {
            try Self.wav(track.samples, rate: Int(track.rate)).write(to: directory.appending(path: "\(seq).wav"))
        }
    }

    private static func pcm16(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        let count = Int(buffer.frameLength)
        if let floats = buffer.floatChannelData?[0] {
            return (0..<count).map { Int16(max(-1, min(1, floats[$0])) * Float(Int16.max)) }
        }
        if let ints = buffer.int16ChannelData?[0] { return Array(UnsafeBufferPointer(start: ints, count: count)) }
        return []
    }

    private static func wav(_ samples: [Int16], rate: Int) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        samples.forEach { put($0) }
        return data
    }
}
