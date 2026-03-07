import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let hasInput: Bool
    let hasOutput: Bool

    var isBlackHole: Bool { name.contains("BlackHole") }
}

// MARK: - Mock data for previews and tests
extension AudioDevice {
    static let mockMic = AudioDevice(
        id: 1,
        name: "Built-in Microphone",
        uid: "BuiltInMicrophoneDevice",
        hasInput: true,
        hasOutput: false
    )

    static let mockSpeakers = AudioDevice(
        id: 2,
        name: "Built-in Output",
        uid: "BuiltInSpeakerDevice",
        hasInput: false,
        hasOutput: true
    )

    static let mockBlackHole = AudioDevice(
        id: 3,
        name: "BlackHole 2ch",
        uid: "BlackHole2ch_UID",
        hasInput: true,
        hasOutput: true
    )

    static let mockInputs: [AudioDevice] = [mockMic, mockBlackHole]
    static let mockOutputs: [AudioDevice] = [mockSpeakers, mockBlackHole]
}
