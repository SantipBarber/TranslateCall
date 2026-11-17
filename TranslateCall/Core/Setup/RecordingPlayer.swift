import AVFoundation
import CoreAudio
import Foundation

// MARK: - SetupAudioError

nonisolated enum SetupAudioError: LocalizedError, Equatable {
    case noSystemVoice
    case alreadyStarted
    case noInputUnit
    case invalidFormat
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSystemVoice:
            return "No English system voice is installed"
        case .alreadyStarted:
            return "The level source is already running"
        case .noInputUnit:
            return "The input node has no audio unit"
        case .invalidFormat:
            return "The device reports no usable input format"
        case .engineStartFailed(let message):
            return "Audio engine failed to start: \(message)"
        }
    }
}

// MARK: - PhrasePlayer

/// Plays the fixed route-test phrase into an output device (REQ-FR-41).
@MainActor
protocol PhrasePlayer {
    func play(on device: AudioDeviceID) async throws
}

/// System-voice implementation of the route-test phrase (the former wizard route test).
@MainActor
final class SystemVoicePhrasePlayer: PhrasePlayer {
    private let phrase = "Testing audio routing. TranslateCall is ready."
    private let locale = Locale(identifier: "en-US")

    func play(on device: AudioDeviceID) async throws {
        guard AVSpeechUtteranceSynthesizer.hasVoice(for: locale) else {
            throw SetupAudioError.noSystemVoice
        }
        let tts = TTSPlaybackService(
            primary: AVSpeechUtteranceSynthesizer(),
            output: try TTSOutput(deviceID: device)
        )
        await tts.speak(text: phrase, locale: locale)
        for await speaking in tts.isSpeakingStream where !speaking {
            break
        }
        await tts.deactivate()
    }
}

// MARK: - RecordingPlayer

/// Plays in-memory recorded buffers back on the default output device (REQ-FR-55).
@MainActor
final class RecordingPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isConfigured = false

    func play(_ buffers: [AVAudioPCMBuffer]) throws {
        guard let first = buffers.first else { return }
        if !isConfigured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: first.format)
            isConfigured = true
        }
        engine.prepare()
        for buffer in buffers {
            player.scheduleBuffer(buffer, at: nil)
        }
        if !engine.isRunning {
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
