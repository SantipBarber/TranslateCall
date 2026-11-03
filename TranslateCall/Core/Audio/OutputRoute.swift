import CoreAudio
import Foundation

/// What the device the other side's translation plays on sounds like to the microphone
/// (M9 scenario-tests: the Task 18 Q6 loop). Only `.speakers` changes anything.
nonisolated enum OutputRoute: Sendable, Equatable {
    /// The mic can hear it: built-in speakers, a display's or an AirPlay speaker.
    case speakers
    /// The mic cannot hear it: the headphone jack, Bluetooth (earbuds, mostly).
    case headphones
    /// Can't tell (USB, virtual, aggregate): the user's choice stands.
    case unknown

    /// Built-in data sources (`kAudioDevicePropertyDataSource`): 'ispk' internal speakers, 'hdpn' headphones.
    static let internalSpeakers: UInt32 = 0x6973_706B
    static let headphonesJack: UInt32 = 0x6864_706E

    static func classify(transport: UInt32, dataSource: UInt32?) -> OutputRoute {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // No data source, or an unknown one, on a built-in output: speakers (the safe side).
            return dataSource == headphonesJack ? .headphones : .speakers
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .headphones
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return .speakers
        default:
            return .unknown
        }
    }

    /// The route of output device `id`, read from CoreAudio.
    static func of(_ id: AudioDeviceID) -> OutputRoute {
        guard let transport = property(id, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        else { return .unknown }
        let source = property(id, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        return classify(transport: transport, dataSource: source)
    }

    /// The system's default output device.
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        let id = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                          scope: kAudioObjectPropertyScopeGlobal)
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

extension ListeningMode {
    /// The mode the echo gate runs on: speakers when the user says so or the output is detected as
    /// speakers. Detection only ever adds the gate, never removes one the user chose.
    nonisolated static func effective(chosen: ListeningMode, route: OutputRoute) -> ListeningMode {
        chosen == .speakers || route == .speakers ? .speakers : .headphones
    }
}
