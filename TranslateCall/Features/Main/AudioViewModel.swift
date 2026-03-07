import Combine
import Foundation
import SwiftUI

// MARK: - Alert model (file-level to avoid nesting violations)

struct AlertItem: Identifiable {
    enum Action { case openSettings }

    let id = UUID()
    let title: String
    let message: String
    let action: Action?
}

// MARK: - ViewModel

@MainActor
final class AudioViewModel: ObservableObject {

    // MARK: - Published state (mirrored from AudioManager)

    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published var selectedInput: AudioDevice?
    @Published var selectedOutput: AudioDevice?
    @Published private(set) var inputLevel: Float = -160
    @Published private(set) var isCapturing = false

    // MARK: - UI-specific state

    @Published private(set) var isStarting = false
    @Published var errorAlert: AlertItem?

    // MARK: - Private

    private let audioManager: AudioManager
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    init(audioManager: AudioManager = AudioManager()) {
        self.audioManager = audioManager
        bindAudioManager()
    }

    // MARK: - Combine bindings

    private func bindAudioManager() {
        audioManager.$inputDevices
            .assign(to: &$inputDevices)
        audioManager.$outputDevices
            .assign(to: &$outputDevices)
        audioManager.$selectedInput
            .assign(to: &$selectedInput)
        audioManager.$selectedOutput
            .assign(to: &$selectedOutput)
        audioManager.$inputLevel
            .assign(to: &$inputLevel)
        audioManager.$isCapturing
            .assign(to: &$isCapturing)
    }

    // MARK: - Actions

    func toggleCapture() async {
        if isCapturing {
            audioManager.stopCapture()
        } else {
            isStarting = true
            defer { isStarting = false }
            do {
                try await audioManager.startCapture()
            } catch AudioError.permissionDenied {
                errorAlert = AlertItem(
                    title: "Microphone Access Required",
                    message: "TranslateCall needs microphone access. Open System Settings to allow it.",
                    action: .openSettings
                )
            } catch {
                errorAlert = AlertItem(
                    title: "Audio Error",
                    message: error.localizedDescription,
                    action: nil
                )
            }
        }
    }

    func selectInput(_ device: AudioDevice) {
        do {
            try audioManager.selectInput(device)
        } catch {
            errorAlert = AlertItem(title: "Device Error", message: error.localizedDescription, action: nil)
        }
    }

    func selectOutput(_ device: AudioDevice) {
        do {
            try audioManager.selectOutput(device)
        } catch {
            errorAlert = AlertItem(title: "Device Error", message: error.localizedDescription, action: nil)
        }
    }

    // MARK: - Preview factory

    static func preview(capturing: Bool = false, level: Float = -60) -> AudioViewModel {
        let instance = AudioViewModel(audioManager: AudioManager())
        instance.inputDevices = AudioDevice.mockInputs
        instance.outputDevices = AudioDevice.mockOutputs
        instance.selectedInput = AudioDevice.mockInputs.first
        instance.selectedOutput = AudioDevice.mockOutputs.first
        instance.inputLevel = level
        return instance
    }
}
