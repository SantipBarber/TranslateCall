import CoreAudio

/// Identifies the specific BlackHole device required for call audio routing.
nonisolated enum BlackHoleDevice {
    static let name = "BlackHole 2ch"
    static let uid = "BlackHole2ch_UID"

    static func find(in devices: [AudioDevice] = CoreAudioDevices.allDevices()) -> AudioDeviceID? {
        devices.first {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame || $0.uid == uid
        }?.id
    }

    static func hasOtherBlackHole(in devices: [AudioDevice] = CoreAudioDevices.allDevices()) -> Bool {
        devices.contains(where: \.isBlackHole) && find(in: devices) == nil
    }
}
