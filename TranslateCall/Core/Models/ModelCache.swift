import FluidAudio
import Foundation

// MARK: - ModelCache

/// Cheap on-disk checks: is a model downloaded? No loading, no network (D-6, design §3.3).
/// Folders mirror where each package stores its model (FluidAudio, WhisperKit, mlx-audio-swift).
nonisolated enum ModelCache {

    // MARK: Generic checks

    /// Every name exists in `directory` (file or folder, e.g. `Encoder.mlmodelc`).
    static func allExist(_ names: [String], in directory: URL) -> Bool {
        names.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// An mlx-audio model folder is usable: a `config.json` that parses plus at least one non-empty
    /// `.safetensors`. This is the rule `ModelUtils.resolveOrDownloadModel` applies before it trusts a
    /// cached copy, so loading a folder that passes never downloads (P20).
    static func hasMLXWeights(in directory: URL) -> Bool {
        let manager = FileManager.default
        guard let config = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              (try? JSONSerialization.jsonObject(with: config)) != nil,
              let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return false }
        return files.contains { file in
            file.pathExtension == "safetensors"
                && ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
    }

    // MARK: Folders and required files

    static let whisperRequired = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
    static let kokoroRequired = ["kokoro_21_5s.mlmodelc", "kokoro_21_15s.mlmodelc"]

    /// WhisperKit's default download base: `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<size>`.
    static func whisperDirectory(for size: WhisperModelSize, home: URL = homeDirectory) -> URL {
        home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(size.whisperKitName)
    }

    /// WhisperKit's tokenizer, fetched on first load: `~/Documents/huggingface/models/openai/whisper-<size>`
    /// (or bundled in the model folder).
    static func hasWhisperTokenizer(for size: WhisperModelSize, home: URL = homeDirectory) -> Bool {
        let repo = size.whisperKitName.replacingOccurrences(of: "openai_", with: "openai/")
        let hub = home.appendingPathComponent("Documents/huggingface/models").appendingPathComponent(repo)
        return [hub, whisperDirectory(for: size, home: home)].contains { allExist(["tokenizer.json"], in: $0) }
    }

    /// FluidAudio TTS on macOS: `~/.cache/fluidaudio/Models/kokoro`.
    static func kokoroDirectory(home: URL = homeDirectory) -> URL {
        home.appendingPathComponent(".cache/fluidaudio/Models/kokoro")
    }

    /// mlx-audio's working copy: `~/.cache/huggingface/hub/mlx-audio/<owner>_<name>`.
    static func mlxAudioDirectory(repo: String, home: URL = homeDirectory) -> URL {
        home.appendingPathComponent(".cache/huggingface/hub/mlx-audio")
            .appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_"))
    }

    static var homeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Per model (production paths)

    static func isParakeetCached(_ config: ParakeetConfiguration = .default) -> Bool {
        let version = config.modelVersion
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// The size the app loads (`WhisperConfiguration.default`; the size is not persisted).
    static func isWhisperCached(_ config: WhisperConfiguration = .default) -> Bool {
        allExist(whisperRequired, in: whisperDirectory(for: config.modelSize))
    }

    static func isKokoroCached() -> Bool {
        allExist(kokoroRequired, in: kokoroDirectory())
    }
}

// MARK: - ModelCacheProbe

/// Injectable view of `ModelCache` for the selectors and the preloader (tests pass fixed answers).
nonisolated struct ModelCacheProbe: Sendable {
    var parakeet: @Sendable () -> Bool
    var whisper: @Sendable () -> Bool
    var kokoro: @Sendable () -> Bool
    var voiceClone: @Sendable () -> Bool

    static let live = ModelCacheProbe(
        parakeet: { ModelCache.isParakeetCached() },
        whisper: { ModelCache.isWhisperCached() },
        kokoro: { ModelCache.isKokoroCached() },
        voiceClone: { QwenCloneModelManager.shared.isModelCached() }
    )
    static let none = ModelCacheProbe(parakeet: { false }, whisper: { false }, kokoro: { false },
                                      voiceClone: { false })
}

// MARK: - ModelCacheError

/// A load-only path found no usable copy on disk (it never downloads; M9 UI core D-6).
nonisolated enum ModelCacheError: Error, Equatable {
    case notCached
}
