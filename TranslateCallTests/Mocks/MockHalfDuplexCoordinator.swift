import Combine
@testable import TranslateCall

/// Minimal mock of `HalfDuplexCoordinating` for `HalfDuplexManagerTests`.
/// Tracks suppress calls for assertion in tests.
@MainActor
final class MockHalfDuplexCoordinator: HalfDuplexCoordinating {

    @Published var isOutgoingSpeaking: Bool = false
    @Published var isIncomingSpeaking: Bool = false

    var isOutgoingSpeakingPublisher: AnyPublisher<Bool, Never> {
        $isOutgoingSpeaking.eraseToAnyPublisher()
    }
    var isIncomingSpeakingPublisher: AnyPublisher<Bool, Never> {
        $isIncomingSpeaking.eraseToAnyPublisher()
    }

    private(set) var suppressOutgoingCaptureCalls: [Bool] = []
    private(set) var suppressIncomingPipelineCalls: [Bool] = []

    func suppressOutgoingCapture(_ suppress: Bool) {
        suppressOutgoingCaptureCalls.append(suppress)
    }

    func suppressIncomingPipeline(_ suppress: Bool) {
        suppressIncomingPipelineCalls.append(suppress)
    }
}
