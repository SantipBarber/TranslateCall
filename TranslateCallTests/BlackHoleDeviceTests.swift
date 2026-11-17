import Testing
@testable import TranslateCall

@Suite("BlackHoleDevice (REQ-FR-21)")
struct BlackHoleDeviceTests {

    @Test func prefersTwoChannel() {
        let devices = [
            AudioDevice(id: 7, name: "BlackHole 16ch", uid: "BlackHole16ch_UID", hasInput: true, hasOutput: true),
            AudioDevice(id: 9, name: "BlackHole 2ch", uid: "BlackHole2ch_UID", hasInput: true, hasOutput: true)
        ]

        #expect(BlackHoleDevice.find(in: devices) == 9)
    }

    @Test func matchesUID() {
        let devices = [
            AudioDevice(id: 9, name: "Renamed", uid: "BlackHole2ch_UID", hasInput: true, hasOutput: true)
        ]

        #expect(BlackHoleDevice.find(in: devices) == 9)
    }

    @Test func caseInsensitive() {
        let devices = [
            AudioDevice(id: 9, name: "blackhole 2CH", uid: "renamed", hasInput: true, hasOutput: true)
        ]

        #expect(BlackHoleDevice.find(in: devices) == 9)
    }

    @Test func onlySixteen() {
        let devices = [
            AudioDevice(id: 7, name: "BlackHole 16ch", uid: "BlackHole16ch_UID", hasInput: true, hasOutput: true)
        ]

        #expect(BlackHoleDevice.find(in: devices) == nil)
        #expect(BlackHoleDevice.hasOtherBlackHole(in: devices))
    }

    @Test func none() {
        let devices = [
            AudioDevice(id: 1, name: "MacBook Mic", uid: "MacBookMic", hasInput: true, hasOutput: false)
        ]

        #expect(BlackHoleDevice.find(in: devices) == nil)
        #expect(!BlackHoleDevice.hasOtherBlackHole(in: devices))
    }
}
