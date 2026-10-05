import Combine
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "VADProvider")

/// Builds each session's VADs: Silero when its model loads, Energy otherwise (F8.5.3 REQ-V-01…04).
///
/// `preload()` warms the Silero model (download + CoreML compile) at launch. While that is still
/// running a session gets Energy instead of waiting. Once the model is ready every session loads
/// Silero (cheap, it is cached). After a failed load (preload or per-session) a session never
/// awaits another load inline, which could hang Start on a download: it gets Energy at once and
/// restarts the background load, so a later session gets Silero when that succeeds.
@MainActor
final class VADProvider: ObservableObject {
    typealias SileroLoader = @Sendable (VADConfiguration) async throws -> any VADService

    private enum Warmup { case idle, warming, ready, failed }

    /// Engine of the last VAD handed out; nil before the first session (REQ-V-03).
    @Published private(set) var activeEngine: VADEngine?

    private let loadSilero: SileroLoader
    private var warmup = Warmup.idle

    /// True while a background Silero load is running (sessions then get Energy).
    var isWarmingUp: Bool { warmup == .warming }

    init(loadSilero: @escaping SileroLoader = { try await SileroVADService(config: $0) }) {
        self.loadSilero = loadSilero
    }

    /// Starts warming the Silero model in the background; a no-op after the first call (REQ-V-02).
    func preload() {
        guard warmup == .idle else { return }
        loadInBackground()
    }

    /// A VAD for one direction of the next session, on a validated copy of `config` (REQ-V-06).
    func makeVAD(config: VADConfiguration) async -> any VADService {
        let config = config.validated()
        switch warmup {
        case .warming:
            logger.info("Silero VAD still loading — using energy VAD for this session")
            return energy(config)
        case .failed:
            logger.info("Silero VAD unavailable — retrying in the background, energy VAD for this session")
            loadInBackground()
            return energy(config)
        case .idle, .ready:
            do {
                let vad = try await loadSilero(config)
                activeEngine = vad.engine
                return vad
            } catch {
                let reason = error.localizedDescription
                logger.warning("Silero VAD unavailable (\(reason, privacy: .public)) — using energy VAD")
                if warmup != .warming { warmup = .failed }
                return energy(config)
            }
        }
    }

    /// One background Silero load at a time; its outcome decides what the next session gets.
    private func loadInBackground() {
        guard warmup != .warming else { return }
        warmup = .warming
        let load = loadSilero
        Task { [weak self] in
            let loaded: Bool
            do {
                let warm = try await load(.default)
                await warm.deactivate()
                logger.info("Silero VAD model ready")
                loaded = true
            } catch {
                logger.warning("Silero VAD background load failed: \(error.localizedDescription, privacy: .public)")
                loaded = false
            }
            self?.warmup = loaded ? .ready : .failed
        }
    }

    private func energy(_ config: VADConfiguration) -> any VADService {
        activeEngine = .energy
        return EnergyVADService(config: config)
    }
}
