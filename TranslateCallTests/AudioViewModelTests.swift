import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

/// AudioViewModel wiring over a mock-backed coordinator. The view model's own AudioManager uses an
/// injected no-op `configure` and injected devices, so no engine or hardware stream is started.
@MainActor
private struct ViewModelHarness {
    let mocks = CoordinatorMocks()
    let coordinator: AudioCoordinator
    let audioManager: AudioManager
    let setupDefaults: UserDefaults
    let viewModel: AudioViewModel

    static let mic = AudioDevice(id: 201, name: "Mic VM", uid: "vm-mic", hasInput: true, hasOutput: false)

    init() {
        let mocks = self.mocks
        coordinator = AudioCoordinator(
            audioCapture: mocks.mockAudioCapture,
            systemCapture: mocks.mockSystemCapture,
            outgoingVADFactory: { mocks.mockVADFactory },
            incomingVADFactory: { mocks.mockIncomingVAD },
            outgoingSTTFactory: { _ in mocks.mockOutgoingSTT },
            incomingSTTFactory: { _ in mocks.mockIncomingSTT },
            outgoingTranslationService: mocks.mockOutgoingTranslation,
            incomingTranslationService: mocks.mockIncomingTranslation,
            outgoingTTSFactory: { _, _ in mocks.mockOutgoingTTS },
            incomingTTSFactory: { _, _ in mocks.mockIncomingTTS },
            languagePairManager: mocks.languagePairManager
        )
        audioManager = AudioManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                                    configure: { _, _ in })
        audioManager.injectInputDevicesForTesting([Self.mic])
        setupDefaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        viewModel = AudioViewModel(
            coordinator: coordinator,
            audioManager: audioManager,
            languagePairManager: mocks.languagePairManager,
            setupManager: SetupManager(defaults: setupDefaults)
        )
    }
}

@Suite("AudioViewModel", .serialized) @MainActor
struct AudioViewModelTests {

    @Test("toggle stops an active coordinator session even when the mic is not capturing")
    func toggleStopsOnCoordinatorState() async {
        let harness = ViewModelHarness()
        await harness.coordinator.start()
        #expect(harness.coordinator.isOutgoingActive)
        #expect(!harness.viewModel.isCapturing)   // the VM's AudioManager is idle

        await harness.viewModel.toggleCapture()

        #expect(!harness.coordinator.isOutgoingActive)
    }

    @Test("toggle while the coordinator is starting stops it; the start does not go active")
    func toggleWhileStartingStops() async {
        let harness = ViewModelHarness()
        await harness.mocks.mockVADFactory.holdNextActivation()
        let starting = Task { await harness.coordinator.start() }
        #expect(await waitUntil { await harness.mocks.mockVADFactory.isWaitingAtGate })
        #expect(harness.coordinator.isStarting)

        await harness.viewModel.toggleCapture()
        await harness.mocks.mockVADFactory.releaseActivation()
        await starting.value

        #expect(!harness.coordinator.isOutgoingActive)
        #expect(harness.mocks.mockAudioCapture.startCount == 1)
    }

    @Test("AudioManager stopping the mic on its own ends the coordinator session")
    func managerStopEndsCoordinatorSession() async throws {
        let harness = ViewModelHarness()
        _ = try await harness.audioManager.startCaptureSkippingPermissionForTesting()
        await harness.coordinator.start()
        #expect(harness.viewModel.isCapturing)
        #expect(harness.coordinator.isOutgoingActive)

        harness.audioManager.injectInputDevicesForTesting([])   // the only mic is gone
        harness.audioManager.handleConfigurationChange(engineRunning: false)

        #expect(!harness.audioManager.isCapturing)
        #expect(await waitUntil { !harness.coordinator.isOutgoingActive })
        #expect(harness.viewModel.errorAlert?.title == "Microphone")
    }
}
