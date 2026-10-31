import AVFoundation
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import MLXLMCommon
import Testing
@testable import TranslateCall

/// Opt-in probe (REQ-QS-30), run in Release by `just qwen-probe` (TC_QWEN_PROBE=1): times Qwen3-TTS streaming
/// per reference length and writes the generated audio as WAV files to listen to. Never part of `just test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TC_QWEN_PROBE"] == "1"))
struct QwenCloneProbeTests {
    private struct Reference {
        let name: String
        let samples: [Float]
        let transcript: String
    }

    private struct Sentence {
        let lang: String       // file prefix
        let language: String   // mlx-audio language
        let text: String
    }

    private static let sentences = [
        Sentence(lang: "es", language: "spanish",
                 text: "Creo que deberíamos revisar el presupuesto antes de la reunión del jueves."),
        Sentence(lang: "es", language: "spanish", text: "¿Te viene bien que hablemos mañana por la tarde?"),
        Sentence(lang: "en", language: "english",
                 text: "I think we should review the budget before Thursday's meeting."),
        Sentence(lang: "en", language: "english", text: "Could we talk tomorrow afternoon instead?")
    ]

    private struct Row {
        let reference: String
        let run: Int
        let cold: Bool
        let sentence: Sentence
        let first: Double?
        let total: Double
        let audioSeconds: Double
        let tokensPerSecond: Double
    }

    @Test func probeReferenceLength() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let refsDir = ProcessInfo.processInfo.environment["TC_QWEN_PROBE_REFS"]
            .map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/qwen-probe/refs")
        var references = try Self.loadReferences(in: refsDir)
        references.append(try await Self.activeProfileReference())

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let outDir = refsDir.deletingLastPathComponent().appendingPathComponent(stamp)
        let config = QwenCloneConfiguration.default
        let params = GenerateParameters(maxTokens: config.maxTokens, temperature: config.temperature,
                                        topP: config.topP, repetitionPenalty: config.repetitionPenalty)
        var rows: [Row] = []
        for reference in references {
            // A fresh load per reference: run 0 is the cold run of that reference.
            let model = try await TTS.loadModel(modelRepo: config.modelRepo)
            let refDir = outDir.appendingPathComponent(reference.name)
            try FileManager.default.createDirectory(at: refDir, withIntermediateDirectories: true)
            // Run 0 is cold (first sentence, first run after load); runs 1... are warm, every sentence.
            let plan = [Self.sentences[0]] + Self.sentences
            for (run, sentence) in plan.enumerated() {
                let result = try await Self.synthesize(model, sentence, reference, params)
                try Self.writeWAV(result.samples, to: refDir.appendingPathComponent("\(sentence.lang)-\(run).wav"))
                rows.append(Row(reference: reference.name, run: run, cold: run == 0, sentence: sentence,
                                first: result.first, total: result.total,
                                audioSeconds: Double(result.samples.count) / 24_000,
                                tokensPerSecond: result.tokensPerSecond))
                print("PROBE \(reference.name) run=\(run) \(sentence.lang) first=\(result.first ?? -1)")
            }
        }
        let summary = outDir.appendingPathComponent("summary.md")
        try Self.summaryText(rows, references).write(to: summary, atomically: true, encoding: .utf8)
        print("PROBE summary: \(summary.path)")
        #expect(!rows.isEmpty)
    }

    // MARK: - Generation

    private static func synthesize(
        _ model: SpeechGenerationModel, _ sentence: Sentence, _ reference: Reference, _ params: GenerateParameters
    ) async throws -> (samples: [Float], first: Double?, total: Double, tokensPerSecond: Double) {
        let start = ContinuousClock.now
        var first: Double?
        var samples: [Float] = []
        var tps = 0.0
        let events = model.generateStream(
            text: sentence.text, voice: nil, refAudio: MLXArray(reference.samples), refText: reference.transcript,
            language: sentence.language, generationParameters: params,
            streamingInterval: QwenCloneConfiguration.default.streamingInterval)
        for try await event in events {
            switch event {
            case .audio(let chunk):
                if first == nil { first = seconds(ContinuousClock.now - start) }
                samples += chunk.asArray(Float.self)
            case .info(let info):
                tps = info.tokensPerSecond
            default:
                break
            }
        }
        return (samples, first, seconds(ContinuousClock.now - start), tps)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - References

    private static func activeProfileReference() async throws -> Reference {
        let raw = UserDefaults.standard.string(forKey: "tlk.voiceCloning.activeProfileId")
        let id = try #require(raw.flatMap(UUID.init(uuidString:)), "no active voice profile")
        let profile = try await VoiceProfileStore().load(id: id)
        let samples = try #require(profile.samples)
        let transcript = try #require(profile.transcript)
        return Reference(name: "31s", samples: samples, transcript: transcript)
    }

    /// Every `<n>s.wav` with its `<n>s.txt` in `dir`, shortest first.
    private static func loadReferences(in dir: URL) throws -> [Reference] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let stems = names.filter { $0.hasSuffix(".wav") }.map { String($0.dropLast(4)) }
            .filter { $0 != "31s" }
            .sorted { (Int($0.dropLast()) ?? 0) < (Int($1.dropLast()) ?? 0) }
        return try stems.map { stem in
            let text = try String(contentsOf: dir.appendingPathComponent("\(stem).txt"), encoding: .utf8)
            return Reference(name: stem, samples: try readWAV(dir.appendingPathComponent("\(stem).wav")),
                             transcript: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Reads any audio file as 24 kHz mono Float.
    private static func readWAV(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                                channels: 1, interleaved: false))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: input)
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: target))
        let capacity = AVAudioFrameCount(Double(file.length) * 24_000 / file.processingFormat.sampleRate) + 1024
        let output = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData?[0], count: Int(output.frameLength)))
    }

    private static func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                                channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard !samples.isEmpty else { return }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        try file.write(from: buffer)
    }

    // MARK: - Summary

    private static func summaryText(_ rows: [Row], _ references: [Reference]) -> String {
        func f(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
        var text = "# Qwen reference-length probe\n\nStreaming interval "
        text += "\(QwenCloneConfiguration.default.streamingInterval) s. Times in seconds.\n\n"
        text += "| reference | ref audio s | run | sentence | cold | first chunk | total | audio s | tok/s |\n"
        text += "|---|---|---|---|---|---|---|---|---|\n"
        for row in rows {
            let refSeconds = references.first { $0.name == row.reference }.map { Double($0.samples.count) / 24_000 }
            text += "| \(row.reference) | \(f(refSeconds)) | \(row.run) | \(row.sentence.lang)-\(row.run) | "
            text += "\(row.cold ? "cold" : "warm") | \(f(row.first)) | \(f(row.total)) | "
            text += "\(f(row.audioSeconds)) | \(f(row.tokensPerSecond)) |\n"
        }
        return text
    }
}
