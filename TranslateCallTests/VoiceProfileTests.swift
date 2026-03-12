import Foundation
import Testing
@testable import TranslateCall

@Suite @MainActor
struct VoiceProfileTests {

    @Test func qualityGradeRawValues() {
        #expect(VoiceQualityGrade(rawValue: "good") == .good)
        #expect(VoiceQualityGrade(rawValue: "fair") == .fair)
        #expect(VoiceQualityGrade(rawValue: "poor") == .poor)
        #expect(VoiceQualityGrade(rawValue: "invalid") == nil)
    }

    @Test func qualityGradeAllCases() {
        #expect(VoiceQualityGrade.allCases.count == 3)
    }

    @Test func headerCodableRoundTrip() throws {
        let header = makeHeader()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(header)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VoiceProfileHeader.self, from: data)
        #expect(decoded.id == header.id)
        #expect(decoded.name == header.name)
        #expect(decoded.sampleRate == 24000)
        #expect(decoded.sampleCount == 684_000)
        #expect(decoded.quality.grade == .good)
        #expect(decoded.quality.peakRmsDbfs == header.quality.peakRmsDbfs)
        #expect(decoded.quality.hasClipping == false)
        #expect(decoded.formatVersion == 1)
    }

    @Test func profileIsDecryptedWhenSamplesPresent() {
        let header = makeHeader()
        var profile = VoiceProfile(header: header, samples: nil, transcript: nil)
        #expect(!profile.isDecrypted)
        profile.samples = [0.1, 0.2]
        #expect(profile.isDecrypted)
    }

    @Test func profileErrorDescriptionsNonEmpty() {
        let errors: [any LocalizedError] = [
            VoiceProfileError.payloadMissing,
            VoiceProfileError.corruptFile,
            VoiceProfileError.keychainError(-25293),
            VoiceProfileError.encryptionFailed,
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func recorderErrorDescriptionsNonEmpty() {
        let errors: [any LocalizedError] = [
            VoiceProfileRecorderError.permissionDenied,
            VoiceProfileRecorderError.sessionConflict,
            VoiceProfileRecorderError.engineSetupFailed,
            VoiceProfileRecorderError.notRecording,
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func validationErrorDescriptionNonEmpty() {
        let error: any LocalizedError = VoiceProfileValidationError.emptyTranscript
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test func headerEquatableUsesId() {
        let id = UUID()
        let header1 = makeHeader(id: id, name: "Name A")
        let header2 = makeHeader(id: id, name: "Name B")
        let header3 = makeHeader(id: UUID(), name: "Name A")
        #expect(header1 == header2)
        #expect(header1 != header3)
    }

    @Test func recordingResultStoresSamples() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        let result = RecordingResult(
            samples: samples,
            durationSeconds: 0.000_125,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -18.0,
                hasClipping: false,
                voicedDurationSeconds: 0.000_125,
                grade: .good
            )
        )
        #expect(result.samples.count == 3)
        #expect(result.durationSeconds > 0)
    }

    // MARK: - Helpers

    private func makeHeader(
        id: UUID = UUID(),
        name: String = "Test Voice",
        grade: VoiceQualityGrade = .good
    ) -> VoiceProfileHeader {
        VoiceProfileHeader(
            id: id,
            name: name,
            createdAt: Date(),
            durationSeconds: 28.5,
            sampleRate: 24000,
            sampleCount: 684_000,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -18.3,
                hasClipping: false,
                voicedDurationSeconds: 25.1,
                grade: grade
            ),
            formatVersion: 1
        )
    }
}
