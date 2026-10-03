import Foundation

enum AudioError: LocalizedError {
    case permissionDenied
    case deviceUnavailable(String)
    case engineStartFailed(Error)
    case noInputDevice
    case alreadyCapturing

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
        }
    }
}
