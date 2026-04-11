import Foundation

// MARK: - TranslationEngine

/// Pluggable translation backend identifier.
/// M8 ships with Apple Translation only; future milestones add on-device or cloud backends.
enum TranslationEngine: String, Codable, Sendable, CaseIterable {
    case appleTranslation

    // Future cases (not implemented in M8):
    // case opusMT           // On-device Opus-MT via CoreML/ONNX
    // case libreTranslate   // Self-hosted LibreTranslate API

    nonisolated var displayName: String {
        switch self {
        case .appleTranslation: return "Apple Translation"
        }
    }
}
