import Combine
import Foundation

// MARK: - HalfDuplexState

/// Visual and operational state of the half-duplex echo prevention system.
enum HalfDuplexState: Equatable {
    /// No TTS is active. Both mic and system audio capture are enabled.
    case listening
    /// At least one TTS is playing. Appropriate captures are suppressed to prevent feedback.
    case speaking
    /// All TTS just finished. Captures remain suppressed during the settling buffer (default 300ms).
    case transitioning
}

// MARK: - HalfDuplexCoordinating

/// Minimal interface consumed by `HalfDuplexManager`.
/// Extracted for DI: `AudioCoordinator` conforms in production; `MockHalfDuplexCoordinator` in tests.
@MainActor
protocol HalfDuplexCoordinating: AnyObject {
    var isOutgoingSpeaking: Bool { get }
    var isIncomingSpeaking: Bool { get }
    /// Publisher that fires when `isOutgoingSpeaking` changes.
    var isOutgoingSpeakingPublisher: AnyPublisher<Bool, Never> { get }
    /// Publisher that fires when `isIncomingSpeaking` changes.
    var isIncomingSpeakingPublisher: AnyPublisher<Bool, Never> { get }
    /// Suppress (or resume) the outgoing pipeline's translation stage.
    /// Called when incoming TTS is speaking, to prevent mic pickup → re-translation loop.
    func suppressOutgoingCapture(_ suppress: Bool)
    /// Suppress (or resume) the incoming pipeline's translation stage.
    /// Called when outgoing TTS is speaking, to prevent BlackHole loopback → re-translation loop.
    func suppressIncomingPipeline(_ suppress: Bool)
}

// MARK: - HalfDuplexManager

/// Software half-duplex state machine that coordinates echo prevention between the two pipelines.
///
/// Observes `isOutgoingSpeaking` and `isIncomingSpeaking` from the coordinator.
/// When either TTS is active it suppresses the corresponding capture path.
/// A 300ms settling buffer prevents immediate re-activation after TTS ends.
///
/// State transitions (from PoC5 — 315ms measured latency, 100% echo prevention):
/// ```
/// .listening ──(any TTS starts)──▶ .speaking
/// .speaking  ──(all TTS ends)────▶ .transitioning ──(300ms)──▶ .listening
/// .transitioning ──(TTS starts)──▶ .speaking  (buffer task cancelled)
/// ```
@MainActor
final class HalfDuplexManager {

    // MARK: - Public state

    @Published private(set) var state: HalfDuplexState = .listening

    // MARK: - Configuration

    let transitionDelay: Duration

    // MARK: - Private

    private weak var coordinator: (any HalfDuplexCoordinating)?
    private var bufferTask: Task<Void, Never>?
    private var observations: [AnyCancellable] = []

    // MARK: - Init

    init(coordinator: any HalfDuplexCoordinating, transitionDelay: Duration = .milliseconds(300)) {
        self.coordinator = coordinator
        self.transitionDelay = transitionDelay
        bind()
    }

    // MARK: - Deactivation

    /// Cancel in-flight transition, lift all suppressions, and reset state.
    /// Called by `AudioCoordinator.stop()`.
    func deactivate() {
        bufferTask?.cancel()
        bufferTask = nil
        observations.removeAll()
        coordinator?.suppressOutgoingCapture(false)
        coordinator?.suppressIncomingPipeline(false)
        state = .listening
    }

    // MARK: - Binding

    private func bind() {
        guard let coordinator else { return }
        Publishers.CombineLatest(
            coordinator.isOutgoingSpeakingPublisher,
            coordinator.isIncomingSpeakingPublisher
        )
        .sink { @MainActor [weak self] outgoing, incoming in
            self?.handle(outgoing: outgoing, incoming: incoming)
        }
        .store(in: &observations)
    }

    // MARK: - State machine

    private func handle(outgoing: Bool, incoming: Bool) {
        if outgoing || incoming {
            handleSpeakingActive(outgoing: outgoing, incoming: incoming)
        } else if state == .speaking {
            handleAllSpeakingEnded()
        }
        // .transitioning + no TTS: buffer task is already running — do nothing.
        // .listening + no TTS: nothing to do.
    }

    private func handleSpeakingActive(outgoing: Bool, incoming: Bool) {
        // Cancel any pending transition buffer so we don't flash .listening.
        bufferTask?.cancel()
        bufferTask = nil
        state = .speaking
        // Suppress the path that would pick up the currently-active TTS:
        // • incoming TTS plays on speakers → mic picks it up → suppress outgoing pipeline
        // • outgoing TTS goes to BlackHole → loopback via system audio → suppress incoming pipeline
        coordinator?.suppressOutgoingCapture(incoming)
        coordinator?.suppressIncomingPipeline(outgoing)
    }

    private func handleAllSpeakingEnded() {
        state = .transitioning
        let delay = transitionDelay
        bufferTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return  // Cancelled — a new speaking event arrived before buffer elapsed
            }
            guard let self else { return }
            self.state = .listening
            self.coordinator?.suppressOutgoingCapture(false)
            self.coordinator?.suppressIncomingPipeline(false)
            self.bufferTask = nil
        }
    }
}
