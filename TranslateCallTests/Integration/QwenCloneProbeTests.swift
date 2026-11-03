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

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
    }

    private struct Row {
        let reference: String
        let number: Int        // 1-based index of the sentence
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

        let outDir: URL
        if let given = ProcessInfo.processInfo.environment["TC_QWEN_PROBE_OUT"] {
            outDir = URL(fileURLWithPath: given)       // the script's run directory
        } else {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            outDir = refsDir.deletingLastPathComponent().appendingPathComponent(stamp)
        }
        let config = QwenCloneConfiguration.default
        let params = GenerateParameters(maxTokens: config.maxTokens, temperature: config.temperature,
                                        topP: config.topP, repetitionPenalty: config.repetitionPenalty)
        var rows: [Row] = []
        for reference in references {
            // A fresh load per reference. Only the first reference's cold run is truly cold (later ones
            // run on a warm MLX process); the summary says so.
            let model = try await TTS.loadModel(modelRepo: config.modelRepo)
            let refDir = outDir.appendingPathComponent(reference.name)
            try FileManager.default.createDirectory(at: refDir, withIntermediateDirectories: true)
            // Sentence 1 runs cold (first run after load), then every sentence runs warm.
            let plan = [(1, true)] + Self.sentences.indices.map { ($0 + 1, false) }
            for (number, cold) in plan {
                let sentence = Self.sentences[number - 1]
                let result = try await Self.synthesize(model, sentence, reference, params)
                let file = "\(sentence.lang)-s\(number)-\(cold ? "cold" : "warm").wav"
                try Self.writeWAV(result.samples, to: refDir.appendingPathComponent(file))
                rows.append(Row(reference: reference.name, number: number, cold: cold, sentence: sentence,
                                first: result.first, total: result.total,
                                audioSeconds: Double(result.samples.count) / 24_000,
                                tokensPerSecond: result.tokensPerSecond))
                print("PROBE \(reference.name) \(file) first=\(result.first ?? -1)")
            }
        }
        let summary = outDir.appendingPathComponent("summary.md")
        try Self.summaryText(rows, references).write(to: summary, atomically: true, encoding: .utf8)
        print("QWEN_PROBE_SUMMARY=\(summary.path)")
        #expect(rows.count == references.count * (Self.sentences.count + 1))
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
            let wav = dir.appendingPathComponent("\(stem).wav")
            let txt = dir.appendingPathComponent("\(stem).txt")
            let need = "each \(stem).wav needs a UTF-8 transcript \(stem).txt next to it"
            guard let text = try? String(contentsOf: txt, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProbeError(description: "cannot read \(txt.path): \(need)")
            }
            let samples: [Float]
            do { samples = try readWAV(wav) } catch {
                throw ProbeError(description: "cannot read audio \(wav.path): \(error.localizedDescription)")
            }
            return Reference(name: stem, samples: samples,
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
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error || error != nil {
            throw error ?? ProbeError(description: "audio conversion to 24 kHz mono failed")
        }
        // .haveData: the output buffer filled before the input ended (capacity is sized to avoid it);
        // .endOfStream / .inputRanDry: everything was converted. Dropping a tail silently is not allowed.
        if status == .haveData, output.frameLength == output.frameCapacity {
            throw ProbeError(description: "conversion of \(url.lastPathComponent) was truncated")
        }
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
        text += "Sentences:\n\n"
        for (index, sentence) in sentences.enumerated() {
            text += "- s\(index + 1) (\(sentence.lang)): \(sentence.text)\n"
        }
        text += "\nFiles: `<ref>/<lang>-s<n>-<cold|warm>.wav`.\n\n"
        text += "| reference | ref audio s | sentence | run | first chunk | total | audio s | tok/s |\n"
        text += "|---|---|---|---|---|---|---|---|\n"
        for row in rows {
            let refSeconds = references.first { $0.name == row.reference }.map { Double($0.samples.count) / 24_000 }
            text += "| \(row.reference) | \(f(refSeconds)) | s\(row.number) \(row.sentence.lang) | "
            text += "\(row.cold ? "cold" : "warm") | \(f(row.first)) | \(f(row.total)) | "
            text += "\(f(row.audioSeconds)) | \(f(row.tokensPerSecond)) |\n"
        }
        if let name = rows.first?.reference,
           let cold = rows.first(where: { $0.reference == name && $0.cold })?.first,
           let warm = rows.first(where: { $0.reference == name && $0.number == 1 && !$0.cold })?.first, warm > 0 {
            text += "\nCold/warm first-chunk ratio (reference \(name), sentence s1): \(f(cold / warm)) "
            text += "(\(f(cold)) s / \(f(warm)) s).\n"
        }
        text += "\nNote: the model reloads per reference, but only the first reference's cold run is truly cold; "
        text += "later references run on an already warm MLX process, so their cold rows are not comparable.\n"
        return text
    }
}
