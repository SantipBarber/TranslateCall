import AVFoundation
import CoreAudio
import Testing
@testable import TranslateCall

@Suite("CoreAudioDevices")
struct CoreAudioDevicesTests {

    @Test("allDevices returns devices with unique IDs and input/output flags")
    func allDevicesAreWellFormed() {
        let devices = CoreAudioDevices.allDevices()
        #expect(Set(devices.map(\.id)).count == devices.count)
        #expect(devices.allSatisfy { $0.hasInput || $0.hasOutput })
    }

    @Test("default input device, when present, is one of the input devices")
    func defaultInputIsAnInput() {
        guard let id = CoreAudioDevices.defaultInputDeviceID() else { return }  // no input hardware at all
        #expect(CoreAudioDevices.allDevices().contains { $0.id == id && $0.hasInput })
    }
}
