import Combine
import Foundation

// MARK: - DownloadableModel

/// A model the app downloads on request (M9 UI settings S-4).
nonisolated enum DownloadableModel: String, CaseIterable, Sendable {
    case parakeet, whisper, kokoro, voiceClone

    /// The figures the legacy sheets show.
    var approximateSize: String {
        switch self {
        case .parakeet: return "≈800 MB"
        case .whisper: return "≈150 MB"
        case .kokoro: return "≈300 MB"
        case .voiceClone: return "≈2 GB"
        }
    }

    /// The model behind a speech engine; nil for Apple Speech, which needs no download.
    init?(_ engine: STTEngine) {
        switch engine {
        case .appleSpeech: return nil
        case .parakeet: self = .parakeet
        case .whisper: self = .whisper
        }
    }

    /// The model behind a voice engine; nil for the system voice and Edge, which need no download.
    init?(_ engine: TTSEngine) {
        switch engine {
        case .avSpeech, .edgeTTS: return nil
        case .kokoro: self = .kokoro
        case .voiceClone: self = .voiceClone
        }
    }
}

// MARK: - DownloadState

/// Where one model stands. Progress is `nil` (indeterminate) today: no manager reports it (design §5).
nonisolated enum DownloadState: Equatable, Sendable {
    case notOnDisk
    case downloading(progress: Double?)
    case ready
    case failed(String)
}

// MARK: - DownloadManagers

/// The managers' download and cancel paths, injectable so tests never touch a model or the network.
nonisolated struct DownloadManagers: Sendable {
    var download: @Sendable (DownloadableModel) async throws -> Void
    var cancel: @Sendable (DownloadableModel) async -> Void

    /// Each manager's existing download+load path. Whisper loads through `loadIfNeeded()` (P8); Kokoro
    /// is unloaded once on disk, so the download does not keep it in memory (P7). Cancel unloads, which
    /// stops the manager's load task; the voice clone has no cancel (P19).
    static let live = DownloadManagers(
        download: { model in
            switch model {
            case .parakeet: _ = try await ParakeetModelManager.shared.ensureReady()
            case .whisper: try await WhisperModelManager.shared.loadIfNeeded()
            case .kokoro:
                _ = try await KokoroModelManager.shared.ensureReady()
                await KokoroModelManager.shared.unload()
            case .voiceClone: try await QwenCloneModelManager.shared.ensureReady()
            }
        },
        cancel: { model in
            switch model {
            case .parakeet: await ParakeetModelManager.shared.unload()
            case .whisper: await WhisperModelManager.shared.unloadModel()
            case .kokoro: await KokoroModelManager.shared.unload()
            case .voiceClone: break
            }
        }
    )
}

// MARK: - ModelDownloads

/// The one place the UI starts model downloads (M9 UI settings S-4): the models sheet and "Use my voice"
/// show the same state. Nothing starts while a session runs (S-7).
@MainActor
final class ModelDownloads: ObservableObject {
    @Published private(set) var states: [DownloadableModel: DownloadState] = [:]
    /// A download completed and the model is on disk (the preloader listens).
    let didFinish = PassthroughSubject<DownloadableModel, Never>()

    private let probe: ModelCacheProbe
    private let managers: DownloadManagers
    private let isSessionActive: () -> Bool
    private var tasks: [DownloadableModel: Task<Void, Never>] = [:]

    init(probe: ModelCacheProbe, managers: DownloadManagers = .live,
         isSessionActive: @escaping () -> Bool = { false }) {
        self.probe = probe
        self.managers = managers
        self.isSessionActive = isSessionActive
        refresh()
    }

    /// True while a session runs: downloads wait until it ends (S-7).
    var isBlocked: Bool { isSessionActive() }

    func state(_ model: DownloadableModel) -> DownloadState {
        states[model] ?? .notOnDisk
    }

    /// Downloads `model`; a no-op while blocked, while it downloads, or when it is on disk.
    func start(_ model: DownloadableModel) {
        guard !isBlocked, tasks[model] == nil, state(model) != .ready else { return }
        states[model] = .downloading(progress: nil)
        let download = managers.download
        tasks[model] = Task { [weak self] in
            let outcome: Result<Void, any Error>
            do {
                try await download(model)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            guard !Task.isCancelled else { return }   // cancelled: `cancel(_:)` already set the state
            self?.complete(model, with: outcome)
        }
    }

    /// Best effort (design §5): asks the manager to stop, then shows what the disk holds. The transfer may
    /// run on and leave partial files, which the disk checks treat as not on disk.
    func cancel(_ model: DownloadableModel) {
        guard let task = tasks.removeValue(forKey: model) else { return }
        task.cancel()
        let cancel = managers.cancel
        Task.detached { await cancel(model) }
        states[model] = diskState(model)
    }

    /// Re-reads the disk for every model not downloading (e.g. when the models sheet appears).
    func refresh() {
        for model in DownloadableModel.allCases where tasks[model] == nil {
            states[model] = diskState(model)
        }
    }

    // MARK: - Private

    private func complete(_ model: DownloadableModel, with outcome: Result<Void, any Error>) {
        tasks[model] = nil
        switch outcome {
        case .success:
            states[model] = .ready
            didFinish.send(model)
        case .failure(let error):
            states[model] = .failed(error.localizedDescription)
        }
    }

    private func diskState(_ model: DownloadableModel) -> DownloadState {
        let onDisk = switch model {
        case .parakeet: probe.parakeet()
        case .whisper: probe.whisper()
        case .kokoro: probe.kokoro()
        case .voiceClone: probe.voiceClone()
        }
        return onDisk ? .ready : .notOnDisk
    }
}
