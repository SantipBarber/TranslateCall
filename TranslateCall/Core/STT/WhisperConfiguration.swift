import Foundation

// MARK: - WhisperModelSize

enum WhisperModelSize: String, Codable, Sendable, CaseIterable {
    case tiny
    case base
    case small
    case medium
    case largeV3

    /// WhisperKit model identifier on HuggingFace (argmaxinc/whisperkit-coreml).
    nonisolated var whisperKitName: String {
        switch self {
        case .tiny:    return "openai_whisper-tiny"
        case .base:    return "openai_whisper-base"
        case .small:   return "openai_whisper-small"
        case .medium:  return "openai_whisper-medium"
        case .largeV3: return "openai_whisper-large-v3"
        }
    }

    nonisolated var approximateSizeMB: Int {
        switch self {
        case .tiny:    return 75
        case .base:    return 150
        case .small:   return 500
        case .medium:  return 1500
        case .largeV3: return 3000
        }
    }

    nonisolated var displayName: String {
        switch self {
        case .tiny:    return "Tiny"
        case .base:    return "Base"
        case .small:   return "Small"
        case .medium:  return "Medium"
        case .largeV3: return "Large v3"
        }
    }

    nonisolated var qualityDescription: String {
        switch self {
        case .tiny:    return "Fastest, lowest quality"
        case .base:    return "Real-time, balanced"
        case .small:   return "Good quality"
        case .medium:  return "High quality"
        case .largeV3: return "Best quality, slowest"
        }
    }
}

// MARK: - WhisperConfiguration

struct WhisperConfiguration: Sendable {
    nonisolated var modelSize: WhisperModelSize = .base
    /// BCP-47 language code, or nil for auto-detect.
    nonisolated var language: String?
    nonisolated var beamSize: Int = 5
    nonisolated var noSpeechThreshold: Float = 0.6

    nonisolated static let `default` = WhisperConfiguration()
}
