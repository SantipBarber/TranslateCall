import Foundation
@testable import TranslateCall

actor MockVoiceProfileStore: VoiceProfileStoring {

    var storedProfiles: [UUID: VoiceProfile] = [:]
    private var throwOnSave: Error?
    private var throwOnLoad: Error?

    // MARK: - Test configuration

    func setShouldThrowOnSave(_ error: Error?) {
        throwOnSave = error
    }

    func setShouldThrowOnLoad(_ error: Error?) {
        throwOnLoad = error
    }

    func forceStore(_ profile: VoiceProfile) {
        storedProfiles[profile.header.id] = profile
    }

    // MARK: - VoiceProfileStoring

    func enumerateHeaders() async throws -> [VoiceProfileHeader] {
        storedProfiles.values.map(\.header).sorted { $0.createdAt > $1.createdAt }
    }

    func save(profile: VoiceProfile) async throws {
        if let error = throwOnSave { throw error }
        storedProfiles[profile.header.id] = profile
    }

    func load(id: UUID) async throws -> VoiceProfile {
        if let error = throwOnLoad { throw error }
        guard let profile = storedProfiles[id] else {
            throw VoiceProfileError.corruptFile
        }
        return profile
    }

    func delete(id: UUID) async throws {
        storedProfiles.removeValue(forKey: id)
    }

    func updateName(_ name: String, for id: UUID) async throws {
        guard var profile = storedProfiles[id] else {
            throw VoiceProfileError.corruptFile
        }
        var header = profile.header
        // VoiceProfileHeader.name is var, so we can update it
        header.name = name
        profile = VoiceProfile(
            header: header,
            samples: profile.samples,
            transcript: profile.transcript
        )
        storedProfiles[id] = profile
    }
}
