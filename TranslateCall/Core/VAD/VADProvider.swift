import Combine
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "VADProvider")

/// Builds each session's VADs: Silero when its model loads, Energy otherwise (F8.5.3 REQ-V-01…04).
///
/// `preload()` warms the Silero model (download + CoreML compile) at launch. While that is still
/// running a session gets Energy instead of waiting; afterwards every session tries Silero again,
/// which is cheap once the model is cached and lets a later download succeed.
@MainActor
final class VADProvider: ObservableObject {
    typealias SileroLoader = @Sendable (VADConfiguration) async throws -> any VADService

    private enum Warmup { case idle, warming, done }

    /// Engine of the last VAD handed out; nil before the first session (REQ-V-03).
    @Published private(set) var activeEngine: VADEngine?

    private let loadSilero: SileroLoader
    private var warmup = Warmup.idle

    init(loadSilero: @escaping SileroLoader = { try await SileroVADService(config: $0) }) {
        self.loadSilero = loadSilero
    }

    /// Starts warming the Silero model in the background; a no-op after the first call (REQ-V-02).
    func preload() {
        guard warmup == .idle else { return }
        warmup = .warming
        let load = loadSilero
        Task { [weak self] in
            do {
                let warm = try await load(.default)
                await warm.deactivate()
                logger.info("Silero VAD model ready")
            } catch {
                logger.warning("Silero VAD preload failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.warmup = .done
        }
    }

    /// A VAD for one direction of the next session, on a validated copy of `config` (REQ-V-06).
    func makeVAD(config: VADConfiguration) async -> any VADService {
        let config = config.validated()
        guard warmup != .warming else {
            logger.info("Silero VAD still loading — using energy VAD for this session")
            return energy(config)
        }
        do {
            let vad = try await loadSilero(config)
            activeEngine = vad.engine
            return vad
        } catch {
            let reason = error.localizedDescription
            logger.warning("Silero VAD unavailable (\(reason, privacy: .public)) — using energy VAD")
            return energy(config)
        }
    }

    private func energy(_ config: VADConfiguration) -> any VADService {
        activeEngine = .energy
        return EnergyVADService(config: config)
    }
}
