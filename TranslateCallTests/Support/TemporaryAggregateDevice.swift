import CoreAudio
import Foundation
@testable import TranslateCall

/// A private (this process only) aggregate device wrapping one sub-device: a second, distinct
/// input device that hears exactly what the sub-device hears. Destroyed on deinit.
final class TemporaryAggregateDevice {
    let id: AudioDeviceID
    let uid: String

    static let uidPrefix = "com.spbarber.TranslateCall.tests.aggregate."

    init(wrapping subDeviceUID: String) throws {
        uid = Self.uidPrefix + UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TranslateCall Test Input",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: subDeviceUID]],
            kAudioAggregateDeviceMainSubDeviceKey: subDeviceUID,
        ]
        var newID = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
        guard status == noErr, newID != kAudioObjectUnknown else {
            throw MissingPrerequisite(description: "could not create aggregate device over \(subDeviceUID) (OSStatus \(status))")
        }
        id = newID
    }

    /// The HAL publishes a new aggregate asynchronously (measured: absent at 3 ms, listed at ~90 ms),
    /// so wait until it is enumerated with input streams before building an AudioManager over it.
    func waitUntilListed(timeout: Duration = .seconds(2)) async -> Bool {
        let uid = uid
        return await waitUntil(timeout: timeout) {
            CoreAudioDevices.allDevices().contains { $0.uid == uid && $0.hasInput }
        }
    }

    deinit {
        AudioHardwareDestroyAggregateDevice(id)
    }
}
