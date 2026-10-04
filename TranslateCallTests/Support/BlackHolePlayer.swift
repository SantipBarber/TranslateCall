import AVFoundation
import CoreAudio
@testable import TranslateCall

/// Loops a fixture WAV into an output device (BlackHole) so a capture test hears known audio.
@MainActor
final class BlackHolePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    init(fixtureURL: URL, deviceID: AudioDeviceID) throws {
        let file = try AVAudioFile(forReading: fixtureURL)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MissingPrerequisite(description: "could not allocate buffer for \(fixtureURL.lastPathComponent)")
        }
        try file.read(into: buffer)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        engine.prepare()
        guard let unit = engine.outputNode.audioUnit else {
            throw MissingPrerequisite(description: "output node has no audio unit")
        }
        try CoreAudioDevices.setCurrentDevice(deviceID, on: unit)
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
