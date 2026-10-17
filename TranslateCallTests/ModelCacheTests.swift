import Foundation
import Testing
@testable import TranslateCall

/// A throwaway home folder; removed when the test ends.
private final class TempHome {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID())", isDirectory: true)
    deinit { try? FileManager.default.removeItem(at: url) }

    func make(_ names: [String], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(name),
                                                        withIntermediateDirectories: true)
            } else {
                let contents = name.hasSuffix(".json") ? "{}" : "x"
                try Data(contents.utf8).write(to: folder.appendingPathComponent(name))
            }
        }
    }
}

@Suite("ModelCache (M9 UI core D-6)")
struct ModelCacheTests {

    @Test("Whisper: complete with the three CoreML bundles, not with two")
    func whisperFolder() throws {
        let home = TempHome()
        let folder = ModelCache.whisperDirectory(for: .base, home: home.url)
        #expect(folder.path.hasSuffix("Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-base"))
        try home.make(Array(ModelCache.whisperRequired.prefix(2)), in: folder)
        #expect(!ModelCache.allExist(ModelCache.whisperRequired, in: folder))
        try home.make(ModelCache.whisperRequired, in: folder)
        #expect(ModelCache.allExist(ModelCache.whisperRequired, in: folder))
    }

    @Test("Whisper: the tokenizer counts too (WhisperKit would fetch a missing one)")
    func whisperTokenizer() throws {
        let home = TempHome()
        #expect(!ModelCache.hasWhisperTokenizer(for: .base, home: home.url))
        try home.make(["tokenizer.json"],
                      in: home.url.appendingPathComponent("Documents/huggingface/models/openai/whisper-base"))
        #expect(ModelCache.hasWhisperTokenizer(for: .base, home: home.url))
    }

    @Test("Kokoro: both variants are required")
    func kokoroFolder() throws {
        let home = TempHome()
        let folder = ModelCache.kokoroDirectory(home: home.url)
        #expect(folder.path.hasSuffix(".cache/fluidaudio/Models/kokoro"))
        try home.make(["kokoro_21_5s.mlmodelc"], in: folder)
        #expect(!ModelCache.allExist(ModelCache.kokoroRequired, in: folder))
        try home.make(["kokoro_21_15s.mlmodelc"], in: folder)
        #expect(ModelCache.allExist(ModelCache.kokoroRequired, in: folder))
    }

    @Test("mlx-audio: needs a config.json that parses and a non-empty .safetensors")
    func mlxWeights() throws {
        let home = TempHome()
        let folder = ModelCache.mlxAudioDirectory(repo: "owner/model", home: home.url)
        #expect(folder.lastPathComponent == "owner_model")
        #expect(!ModelCache.hasMLXWeights(in: folder))
        try home.make(["config.json"], in: folder)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("model.safetensors").path, contents: Data())
        #expect(!ModelCache.hasMLXWeights(in: folder), "a zero-byte weights file is a partial download")
        try home.make(["model.safetensors"], in: folder)
        #expect(ModelCache.hasMLXWeights(in: folder))
        try Data("{ partial".utf8).write(to: folder.appendingPathComponent("config.json"))
        #expect(!ModelCache.hasMLXWeights(in: folder), "mlx-audio would clear an invalid config and download")
    }

    @Test("Qwen: the old `models--…` hub folder alone is not a cached model")
    func qwenIgnoresHubFolder() async throws {
        let home = TempHome()
        let config = QwenCloneConfiguration(modelRepo: "owner/model")
        let manager = QwenCloneModelManager(config: config, modelLoader: { _ in MockQwenCloneInferrer() })
        try home.make(["blobs.txt"], in: home.url.appendingPathComponent(".cache/huggingface/hub/models--owner--model"))
        #expect(!manager.isModelCached(home: home.url))
        try home.make(["config.json", "model.safetensors"],
                      in: ModelCache.mlxAudioDirectory(repo: "owner/model", home: home.url))
        #expect(manager.isModelCached(home: home.url))
    }
}
