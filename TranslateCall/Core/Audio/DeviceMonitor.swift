import CoreAudio
import Foundation

/// Monitors CoreAudio device additions and removals via kAudioHardwarePropertyDevices.
/// Delivers change notifications on the main queue.
final class DeviceMonitor {
    var onDevicesChanged: (() -> Void)?

    init() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.onDevicesChanged?()
        }
    }
}
