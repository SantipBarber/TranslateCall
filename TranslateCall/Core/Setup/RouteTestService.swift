import Combine
import CoreAudio
import Foundation

// MARK: - RouteTestService

/// Plays a short TTS phrase routed to BlackHole to verify audio routing is working.
@MainActor
final class RouteTestService: ObservableObject {

    // MARK: - State

    enum TestState: Equatable {
        case idle
        case playing
        case succeeded
        case failed(String)

        static func == (lhs: TestState, rhs: TestState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.playing, .playing), (.succeeded, .succeeded): return true
            case (.failed(let lhsMsg), .failed(let rhsMsg)): return lhsMsg == rhsMsg
            default: return false
            }
        }
    }

    @Published private(set) var state: TestState = .idle

    // MARK: - Private

    private let testPhrase = "Testing audio routing. TranslateCall is ready."

    // MARK: - Actions

    /// Plays the test phrase routed to the given BlackHole device.
    /// - Parameter blackHoleDeviceID: The CoreAudio device ID for BlackHole 2ch, or `nil` if absent.
    func run(blackHoleDeviceID: AudioDeviceID?) async {
        guard let deviceID = blackHoleDeviceID else {
            state = .failed("BlackHole not detected")
            return
        }
        guard state != .playing else { return }

        let locale = Locale(identifier: "en-US")
        guard AVSpeechUtteranceSynthesizer.hasVoice(for: locale) else {
            state = .failed("No English system voice is installed")
            return
        }

        state = .playing
        do {
            let tts = TTSPlaybackService(primary: AVSpeechUtteranceSynthesizer(),
                                         output: try TTSOutput(deviceID: deviceID))
            await tts.speak(text: testPhrase, locale: locale)
            for await speaking in tts.isSpeakingStream where !speaking {
                break
            }
            await tts.deactivate()
            state = .succeeded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func reset() {
        state = .idle
    }
}
