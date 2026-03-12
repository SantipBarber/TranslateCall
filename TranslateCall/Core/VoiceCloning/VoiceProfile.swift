import Foundation

// MARK: - Quality Grade

// All types in this file are nonisolated to opt out of the default @MainActor isolation.
// They are value types used from actors (VoiceProfileStore, VoiceProfileRecorder) and
// their Codable conformances must be callable from non-MainActor contexts.

nonisolated enum VoiceQualityGrade: String, Codable, Sendable, CaseIterable {
    case good   // RMS ≥ -20 dBFS, no clipping, voiced ≥ 20 s
    case fair   // RMS ≥ -30 dBFS, no clipping, voiced ≥ 10 s
    case poor   // RMS < -30 dBFS OR clipping OR voiced < 10 s
}

// MARK: - Quality Metrics

nonisolated struct VoiceQualityMetrics: Codable, Sendable, Equatable {
    let peakRmsDbfs: Float
    let hasClipping: Bool
    let voicedDurationSeconds: Float
    let grade: VoiceQualityGrade
}

// MARK: - Profile Header (always loaded; no audio data)

nonisolated struct VoiceProfileHeader: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    let durationSeconds: Float
    let sampleRate: Int             // always 24000
    let sampleCount: Int
    let quality: VoiceQualityMetrics
    let formatVersion: Int          // = 1

    static func == (lhs: VoiceProfileHeader, rhs: VoiceProfileHeader) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Full Profile (header + optional decrypted payload)

nonisolated struct VoiceProfile: Sendable {
    let header: VoiceProfileHeader
    var samples: [Float]?           // Float32 PCM at 24 kHz mono
    var transcript: String?

    var isDecrypted: Bool { samples != nil }
}

// MARK: - Recording Result

nonisolated struct RecordingResult: Sendable {
    let samples: [Float]            // 24 kHz mono Float32
    let durationSeconds: Float
    let quality: VoiceQualityMetrics
}

// MARK: - Errors

nonisolated enum VoiceProfileError: LocalizedError, Equatable {
    case payloadMissing
    case corruptFile
    case keychainError(OSStatus)
    case encryptionFailed

    var errorDescription: String? {
        switch self {
        case .payloadMissing:
            return "Voice profile has no audio data."
        case .corruptFile:
            return "Voice profile file is corrupt or unreadable."
        case .keychainError(let status):
            return "Keychain error (\(status)) — cannot access encryption key."
        case .encryptionFailed:
            return "Failed to encrypt voice profile data."
        }
    }
}

nonisolated enum VoiceProfileRecorderError: LocalizedError {
    case permissionDenied
    case sessionConflict
    case engineSetupFailed
    case notRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied. Check System Settings > Privacy > Microphone."
        case .sessionConflict:
            return "Recording is unavailable while a translation session is active."
        case .engineSetupFailed:
            return "Failed to configure the recording engine."
        case .notRecording:
            return "No recording is in progress."
        }
    }
}

nonisolated enum VoiceProfileValidationError: LocalizedError {
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "A transcript is required for voice cloning quality."
        }
    }
}
