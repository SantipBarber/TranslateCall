import CryptoKit
import Foundation
import Testing
@testable import TranslateCall

@Suite @MainActor
struct VoiceProfileStoreTests {

    /// Each test uses a unique temp directory + in-memory key (no real Keychain)
    private func makeStore() -> (VoiceProfileStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceProfileStoreTests-\(UUID())")
        let testKey = SymmetricKey(size: .bits256)
        let store = VoiceProfileStore(storageURL: dir, keychainProvider: { testKey })
        return (store, dir)
    }

    private func makeProfile(
        name: String = "Test",
        samples: [Float] = Array(repeating: 0.5, count: 24000),
        transcript: String = "Hello world"
    ) -> VoiceProfile {
        let header = VoiceProfileHeader(
            id: UUID(),
            name: name,
            createdAt: .now,
            durationSeconds: Float(samples.count) / 24000.0,
            sampleRate: 24000,
            sampleCount: samples.count,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -18.0,
                hasClipping: false,
                voicedDurationSeconds: 1.0,
                grade: .good
            ),
            formatVersion: 1
        )
        return VoiceProfile(header: header, samples: samples, transcript: transcript)
    }

    // MARK: - Tests

    @Test func saveAndLoadRoundTrip() async throws {
        let (store, _) = makeStore()
        let original = makeProfile(
            samples: [0.1, 0.5, -0.3, 0.8],
            transcript: "Testing one two three"
        )
        try await store.save(profile: original)
        let loaded = try await store.load(id: original.header.id)
        #expect(loaded.samples == original.samples)
        #expect(loaded.transcript == original.transcript)
        #expect(loaded.header.name == "Test")
        #expect(loaded.header.sampleRate == 24000)
        #expect(loaded.header.quality.grade == .good)
    }

    @Test func headerOnlyEnumeration() async throws {
        let (store, _) = makeStore()
        try await store.save(profile: makeProfile(name: "A"))
        try await store.save(profile: makeProfile(name: "B"))
        let headers = try await store.enumerateHeaders()
        #expect(headers.count == 2)
        let names = Set(headers.map(\.name))
        #expect(names.contains("A"))
        #expect(names.contains("B"))
    }

    @Test func corruptFileSkipped() async throws {
        let (store, dir) = makeStore()
        try await store.save(profile: makeProfile(name: "Good"))
        // Write a corrupt file alongside
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let corruptURL = dir.appendingPathComponent("\(UUID()).vpf")
        try Data("not a valid vpf file at all".utf8).write(to: corruptURL)
        let headers = try await store.enumerateHeaders()
        #expect(headers.count == 1)
        #expect(headers[0].name == "Good")
    }

    @Test func decryptionFailsOnTamperedCiphertext() async throws {
        let (store, dir) = makeStore()
        let profile = makeProfile()
        try await store.save(profile: profile)
        // Tamper the file: flip a byte in the ciphertext region
        let fileURL = dir.appendingPathComponent("\(profile.header.id).vpf")
        var data = try Data(contentsOf: fileURL)
        let tamperIndex = data.count - 20  // inside ciphertext/tag area
        data[tamperIndex] ^= 0xFF
        try data.write(to: fileURL)
        do {
            _ = try await store.load(id: profile.header.id)
            Issue.record("Expected decryption failure")
        } catch {
            // Expected — CryptoKit authentication error
        }
    }

    @Test func renamePreservesPayload() async throws {
        let (store, _) = makeStore()
        let profile = makeProfile(name: "Original", transcript: "Important text")
        try await store.save(profile: profile)
        try await store.updateName("Renamed", for: profile.header.id)
        let headers = try await store.enumerateHeaders()
        #expect(headers.first?.name == "Renamed")
        let loaded = try await store.load(id: profile.header.id)
        #expect(loaded.transcript == "Important text")
        #expect(loaded.samples == profile.samples)
    }

    @Test func deleteRemovesFile() async throws {
        let (store, dir) = makeStore()
        let profile = makeProfile()
        try await store.save(profile: profile)
        let fileURL = dir.appendingPathComponent("\(profile.header.id).vpf")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        try await store.delete(id: profile.header.id)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func saveWithoutPayloadThrows() async throws {
        let (store, _) = makeStore()
        let header = VoiceProfileHeader(
            id: UUID(),
            name: "Empty",
            createdAt: .now,
            durationSeconds: 0,
            sampleRate: 24000,
            sampleCount: 0,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -60,
                hasClipping: false,
                voicedDurationSeconds: 0,
                grade: .poor
            ),
            formatVersion: 1
        )
        let incomplete = VoiceProfile(header: header, samples: nil, transcript: nil)
        do {
            try await store.save(profile: incomplete)
            Issue.record("Expected payloadMissing error")
        } catch let error as VoiceProfileError {
            #expect(error == .payloadMissing)
        }
    }

    @Test func largeSampleRoundTrip() async throws {
        let (store, _) = makeStore()
        // 2 seconds of audio at 24 kHz = 48000 samples
        let samples: [Float] = (0 ..< 48000).map { Float(sin(Double($0) / 100.0)) }
        let profile = makeProfile(samples: samples, transcript: "Sine wave test")
        try await store.save(profile: profile)
        let loaded = try await store.load(id: profile.header.id)
        #expect(loaded.header.sampleRate == 24000)
        #expect(loaded.samples?.count == 48000)
        // Verify sample values match (Float equality is fine here — no computation)
        #expect(loaded.samples?[0] == samples[0])
        #expect(loaded.samples?[47999] == samples[47999])
    }

    @Test func keychainUnavailableThrows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceProfileStoreTests-\(UUID())")
        let store = VoiceProfileStore(storageURL: dir) {
            throw VoiceProfileError.keychainError(-25293)
        }
        let profile = makeProfile()
        do {
            try await store.save(profile: profile)
            Issue.record("Expected keychain error")
        } catch let error as VoiceProfileError {
            if case .keychainError = error { } else {
                Issue.record("Expected keychainError, got \(error)")
            }
        }
    }
}
