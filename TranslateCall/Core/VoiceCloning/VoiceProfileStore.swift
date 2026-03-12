import CryptoKit
import Foundation
import OSLog

private nonisolated(unsafe) let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "VoiceProfileStore"
)

// MARK: - Protocol

protocol VoiceProfileStoring: Actor {
    func enumerateHeaders() async throws -> [VoiceProfileHeader]
    func save(profile: VoiceProfile) async throws
    func load(id: UUID) async throws -> VoiceProfile
    func delete(id: UUID) async throws
    func updateName(_ name: String, for id: UUID) async throws
}

// MARK: - Keychain Key Store

nonisolated enum KeychainKeyStore {
    private static let service = "com.spbarber.TranslateCall.voiceProfiles"
    private static let account = "aes256EncryptionKey"

    static func loadOrCreate() throws -> SymmetricKey {
        if let existing = try load() { return existing }
        let key = SymmetricKey(size: .bits256)
        try store(key)
        return key
    }

    private static func load() throws -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw VoiceProfileError.keychainError(status)
        }
        return SymmetricKey(data: data)
    }

    private static func store(_ key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
            kSecValueData: keyData
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VoiceProfileError.keychainError(status)
        }
    }
}

// MARK: - Voice Profile Store

actor VoiceProfileStore: VoiceProfileStoring {

    // MARK: - Storage URL (injectable for tests)

    private let storageURL: URL
    private let keychainProvider: () throws -> SymmetricKey

    private nonisolated static let defaultKeychainProvider: @Sendable () throws -> SymmetricKey = {
        try KeychainKeyStore.loadOrCreate()
    }

    init(
        storageURL: URL = VoiceProfileStore.defaultStorageURL,
        keychainProvider: @escaping () throws -> SymmetricKey = VoiceProfileStore.defaultKeychainProvider
    ) {
        self.storageURL = storageURL
        self.keychainProvider = keychainProvider
    }

    nonisolated static var defaultStorageURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent("TranslateCall", isDirectory: true)
            .appendingPathComponent("VoiceProfiles", isDirectory: true)
    }

    // MARK: - Cached key

    private var cachedKey: SymmetricKey?

    private func encryptionKey() throws -> SymmetricKey {
        if let key = cachedKey { return key }
        let key = try keychainProvider()
        cachedKey = key
        return key
    }

    // MARK: - JSON coders

    private nonisolated static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private nonisolated static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    // MARK: - Enumerate Headers

    func enumerateHeaders() async throws -> [VoiceProfileHeader] {
        let fileMan = FileManager.default
        try fileMan.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let files = try fileMan.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "vpf" }

        return files.compactMap { url in
            do {
                return try readHeader(from: url)
            } catch {
                logger.error("Skipping corrupt profile at \(url.lastPathComponent): \(error)")
                return nil
            }
        }
    }

    // MARK: - Save

    func save(profile: VoiceProfile) async throws {
        guard let samples = profile.samples, let transcript = profile.transcript else {
            throw VoiceProfileError.payloadMissing
        }
        let key = try encryptionKey()
        let fileMan = FileManager.default
        try fileMan.createDirectory(at: storageURL, withIntermediateDirectories: true)

        let fileURL = storageURL.appendingPathComponent("\(profile.header.id).vpf")

        // 1. Encode payload binary
        let payload = Self.encodePayload(samples: samples, transcript: transcript)

        // 2. Encrypt
        let sealed = try AES.GCM.seal(payload, using: key)

        // 3. Encode header JSON
        let headerData = try Self.encoder.encode(profile.header)

        // 4. Build file bytes: [4B headerLen][header JSON][12B nonce][ciphertext][16B tag]
        var fileBytes = Data()
        DataHelper.appendUInt32(UInt32(headerData.count), to: &fileBytes)
        fileBytes.append(headerData)
        fileBytes.append(contentsOf: sealed.nonce)
        fileBytes.append(sealed.ciphertext)
        fileBytes.append(sealed.tag)

        // 5. Atomic write via temp file (no partial file on failure)
        let tmpURL = storageURL.appendingPathComponent("\(profile.header.id).tmp")
        try fileBytes.write(to: tmpURL, options: .atomic)

        // Move into place
        if fileMan.fileExists(atPath: fileURL.path) {
            _ = try fileMan.replaceItemAt(fileURL, withItemAt: tmpURL)
        } else {
            try fileMan.moveItem(at: tmpURL, to: fileURL)
        }

        logger.info("Saved voice profile \(profile.header.id)")
    }

    // MARK: - Load (decrypt)

    func load(id: UUID) async throws -> VoiceProfile {
        let key = try encryptionKey()
        let fileURL = storageURL.appendingPathComponent("\(id).vpf")
        let data = try Data(contentsOf: fileURL)
        let (header, payloadData) = try Self.parseAndDecrypt(data: data, key: key)
        let (samples, transcript) = try Self.decodePayload(payloadData)
        return VoiceProfile(header: header, samples: samples, transcript: transcript)
    }

    // MARK: - Delete (secure)

    func delete(id: UUID) async throws {
        let fileURL = storageURL.appendingPathComponent("\(id).vpf")
        let fileMan = FileManager.default
        guard fileMan.fileExists(atPath: fileURL.path) else { return }

        // Overwrite with zeros before removal
        if let attrs = try? fileMan.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > 0 {
            let zeros = Data(repeating: 0, count: size)
            try? zeros.write(to: fileURL)
        }
        try fileMan.removeItem(at: fileURL)
        logger.info("Deleted voice profile \(id)")
    }

    // MARK: - Rename (header only, no re-encryption)

    func updateName(_ name: String, for id: UUID) async throws {
        let fileURL = storageURL.appendingPathComponent("\(id).vpf")
        let data = try Data(contentsOf: fileURL)

        guard data.count >= 4 else { throw VoiceProfileError.corruptFile }
        let originalHeaderLen = Int(DataHelper.readUInt32(from: data, at: data.startIndex))
        guard data.count >= 4 + originalHeaderLen else { throw VoiceProfileError.corruptFile }

        var header = try Self.decoder.decode(
            VoiceProfileHeader.self,
            from: data[4 ..< (4 + originalHeaderLen)]
        )
        header.name = name

        let newHeaderData = try Self.encoder.encode(header)

        var newFile = Data()
        DataHelper.appendUInt32(UInt32(newHeaderData.count), to: &newFile)
        newFile.append(newHeaderData)
        // Append everything after the original header (nonce + ciphertext + tag)
        newFile.append(data[(4 + originalHeaderLen)...])

        try newFile.write(to: fileURL, options: .atomic)
        logger.info("Renamed voice profile \(id) to '\(name)'")
    }

    // MARK: - Private: Header parsing

    private func readHeader(from url: URL) throws -> VoiceProfileHeader {
        let data = try Data(contentsOf: url)
        guard data.count >= 4 else { throw VoiceProfileError.corruptFile }
        let headerLen = Int(DataHelper.readUInt32(from: data, at: data.startIndex))
        guard data.count >= 4 + headerLen else { throw VoiceProfileError.corruptFile }
        return try Self.decoder.decode(
            VoiceProfileHeader.self,
            from: data[4 ..< (4 + headerLen)]
        )
    }

    // MARK: - Private: Decrypt

    private nonisolated static func parseAndDecrypt(
        data: Data,
        key: SymmetricKey
    ) throws -> (VoiceProfileHeader, Data) {
        guard data.count >= 4 else { throw VoiceProfileError.corruptFile }
        let headerLen = Int(DataHelper.readUInt32(from: data, at: data.startIndex))
        let headerEnd = 4 + headerLen
        guard data.count >= headerEnd else { throw VoiceProfileError.corruptFile }

        let header = try decoder.decode(
            VoiceProfileHeader.self,
            from: data[4 ..< headerEnd]
        )

        let rest = data[headerEnd...]
        // 12 bytes nonce + at least 16 bytes tag
        guard rest.count > 28 else { throw VoiceProfileError.corruptFile }

        let nonceEnd = rest.startIndex + 12
        let tagStart = rest.endIndex - 16

        let nonce = try AES.GCM.Nonce(data: rest[rest.startIndex ..< nonceEnd])
        let ciphertext = rest[nonceEnd ..< tagStart]
        let tag = rest[tagStart ..< rest.endIndex]

        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(sealedBox, using: key)

        return (header, plaintext)
    }

    // MARK: - Private: Payload encoding/decoding

    nonisolated static func encodePayload(samples: [Float], transcript: String) -> Data {
        var data = Data()
        DataHelper.appendUInt32(UInt32(samples.count), to: &data)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        let transcriptBytes = transcript.data(using: .utf8) ?? Data()
        DataHelper.appendUInt32(UInt32(transcriptBytes.count), to: &data)
        data.append(transcriptBytes)
        return data
    }

    nonisolated static func decodePayload(_ data: Data) throws -> ([Float], String) {
        var offset = data.startIndex
        guard data.count >= offset + 4 else { throw VoiceProfileError.corruptFile }

        let sampleCount = Int(DataHelper.readUInt32(from: data, at: offset))
        offset += 4

        let sampleBytes = sampleCount * MemoryLayout<Float>.size
        guard data.count >= offset + sampleBytes + 4 else { throw VoiceProfileError.corruptFile }

        let samples: [Float] = data[offset ..< (offset + sampleBytes)].withUnsafeBytes {
            Array(UnsafeBufferPointer(
                start: $0.baseAddress!.assumingMemoryBound(to: Float.self),
                count: sampleCount
            ))
        }
        offset += sampleBytes

        let transcriptLen = Int(DataHelper.readUInt32(from: data, at: offset))
        offset += 4

        guard data.count >= offset + transcriptLen else { throw VoiceProfileError.corruptFile }
        let transcript = String(
            data: data[offset ..< (offset + transcriptLen)],
            encoding: .utf8
        ) ?? ""

        return (samples, transcript)
    }
}

// MARK: - Data helpers (nonisolated — used from actor + static contexts)

private enum DataHelper {
    nonisolated static func readUInt32(from data: Data, at index: Data.Index) -> UInt32 {
        data[index ..< (index + 4)].withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
    }

    nonisolated static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndianVal = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianVal) { data.append(contentsOf: $0) }
    }
}
