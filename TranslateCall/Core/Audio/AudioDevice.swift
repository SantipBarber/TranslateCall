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

// MARK: - CoreAudio device ID lookup

extension AudioDevice {
    /// Returns the `AudioDeviceID` for the first CoreAudio device whose name contains
    /// `substring` (case-insensitive). Returns `nil` if no matching device is found.
    ///
    /// Used by `AudioCoordinator` to resolve the BlackHole device ID at session start.
    static func deviceID(forNameContaining substring: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return nil }

        for deviceID in ids {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameValue: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &nameValue) {
                AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, $0)
            }
            guard status == noErr else { continue }

            if (nameValue as String).localizedCaseInsensitiveContains(substring) {
                return deviceID
            }
        }
        return nil
    }
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
