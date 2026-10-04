import AudioToolbox
import CoreAudio
import Foundation

nonisolated enum CoreAudioError: Error, Equatable {
    case status(OSStatus)
}

/// Thin CoreAudio HAL queries shared by AudioManager and tests (F8.5.1 §3.4).
nonisolated enum CoreAudioDevices {

    static func allDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }

        return ids.compactMap { makeDevice(id: $0) }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Binds an AUHAL unit (e.g. `AVAudioEngine.inputNode.audioUnit`) to a device. Engine must be stopped.
    static func setCurrentDevice(_ id: AudioDeviceID, on unit: AudioUnit) throws {
        var deviceID = id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw CoreAudioError.status(status) }
    }

    static func currentDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &size
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private static func makeDevice(id: AudioDeviceID) -> AudioDevice? {
        guard
            let name = stringProperty(
                id, selector: kAudioDevicePropertyDeviceNameCFString,
                scope: kAudioObjectPropertyScopeGlobal
            ),
            let uid = stringProperty(
                id, selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            )
        else { return nil }

        let hasInput = channelCount(id, scope: kAudioDevicePropertyScopeInput) > 0
        let hasOutput = channelCount(id, scope: kAudioDevicePropertyScopeOutput) > 0
        guard hasInput || hasOutput else { return nil }

        return AudioDevice(id: id, name: name, uid: uid, hasInput: hasInput, hasOutput: hasOutput)
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var value: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, $0)
        }
        return status == noErr ? (value as String) : nil
    }

    /// Read-only: the device's total input channel count (0 when unavailable).
    static func inputChannelCount(of id: AudioDeviceID) -> Int {
        channelCount(id, scope: kAudioObjectPropertyScopeInput)
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            id, &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(
            id, &address, 0, nil, &dataSize, bufferList
        ) == noErr else { return 0 }

        // UnsafeMutableAudioBufferListPointer is the safe way to iterate AudioBufferList
        return UnsafeMutableAudioBufferListPointer(bufferList)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
