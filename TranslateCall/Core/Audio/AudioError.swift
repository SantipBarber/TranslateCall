import Foundation

enum AudioError: LocalizedError {
    case permissionDenied
    case deviceUnavailable(String)
    case engineStartFailed(Error)
    case noInputDevice
    case alreadyCapturing
    case deviceSwitchFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied. Please allow access in System Settings → Privacy & Security → Microphone."
        case .deviceUnavailable(let name):
            return "Audio device '\(name)' is not available."
        case .engineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        case .noInputDevice:
            return "No input audio device selected or available."
        case .alreadyCapturing:
            return "Microphone capture is already running."
        case .deviceSwitchFailed(let name, let error):
            return "Could not use microphone '\(name)': \(error.localizedDescription)"
        }
    }
}
