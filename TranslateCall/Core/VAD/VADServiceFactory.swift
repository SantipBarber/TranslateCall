import Combine
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "VADServiceFactory")

// MARK: - VADServiceFactory

/// Creates and manages the active VADService instance.
///
/// Strategy: always starts with EnergyVADService (synchronous init, no model download).
/// Attempts to load SileroVADService in the background; on success, switches service
/// for the next capture session. If Silero fails, stays on Energy — no user-visible error.
///
/// `@MainActor` because it is observed by `AudioViewModel` which lives on `@MainActor`.
@MainActor
final class VADServiceFactory: ObservableObject {

    @Published private(set) var activeEngine: VADEngine = .energy
    @Published private(set) var sileroModelAvailable: Bool = false

    /// The current VAD service. AudioViewModel activates this when capture starts.
    private(set) var service: any VADService

    private let energyService: EnergyVADService
    private let config: VADConfiguration

    // MARK: - Init

    init(config: VADConfiguration = .default) {
        self.config = config
        let energy = EnergyVADService(config: config)
        self.energyService = energy
        self.service = energy
        self.activeEngine = .energy

        // Attempt Silero model load in background — non-blocking
        Task { [weak self] in
            await self?.tryLoadSilero()
        }
    }

    // MARK: - Private

    private func tryLoadSilero() async {
        do {
            let silero = try await SileroVADService(config: config)
            service = silero
            activeEngine = .silero
            sileroModelAvailable = true
            logger.info("Silero VAD ready — switched to neural engine")
        } catch {
            sileroModelAvailable = false
            logger.info("Silero VAD unavailable (\(error.localizedDescription)) — staying on energy VAD")
        }
    }
}
