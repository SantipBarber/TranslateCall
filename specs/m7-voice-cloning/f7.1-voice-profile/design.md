# F7.1 — Voice Profile Training: Technical Design

> **Feature**: F7.1 — Voice Profile Training
> **Milestone**: M7 — Voice Cloning
> **Status**: DRAFT
> **Author**: SDD Process
> **Date**: 2026-03-12
> **Depends on**: F6.2 (TTSEngineSelector pattern reused); M6 patterns (actor singletons, @MainActor ObservableObject, nonisolated(unsafe))

---

## 1. Overview & Key Decisions

### 1.1 Encryption: CryptoKit AES-256-GCM

macOS 15 ships `CryptoKit` natively. We use `AES.GCM.seal/open` directly — no third-party crypto dependency. One AES-256 key per app installation is stored in the macOS Keychain (`kSecAttrAccessibleWhenUnlocked`). Each `.vpf` file gets a fresh 12-byte random nonce (IV) embedded in the file header so the key itself never needs to rotate.

This avoids adding any new SPM dependency and is fully auditable.

### 1.2 Audio Capture: Dedicated Engine at 24 kHz

`VoiceProfileRecorder` uses its own `AVAudioEngine` separate from `AudioManager`. This allows:
- Capture at exactly 24 kHz mono Float32 — no post-hoc SRC needed.
- No conflict with the live translation pipeline (both engines can coexist on macOS; recording is blocked while `AudioCoordinator` is active — REQ-VCP-NF-14).
- Clean teardown: the recorder engine is started only during the recording session.

If the device natively supports 24 kHz input (most Apple Silicon mics do), the tap runs at native rate. If not, `AVAudioConverter` resamples on the audio thread — the same SRC pattern established in `AudioManager` (F1.2).

### 1.3 `.vpf` File Format

A binary format designed to be:
- **Parseable without full decryption** (header in plaintext JSON for list view).
- **Forward-compatible** (header contains `formatVersion`).
- **Directly usable by F7.2** Python microservice bridge (raw Float32 PCM at 24 kHz + UTF-8 transcript — exactly CSM-1B's `Segment` input).

```
┌──────────────────────────────────────┐
│  4 bytes LE uint32: headerByteLen    │
│  headerByteLen bytes: UTF-8 JSON     │  ← plaintext; UUID, name, date, metrics
├──────────────────────────────────────┤
│  12 bytes: AES-GCM nonce             │  ← per-file random IV
│  N bytes: AES-GCM sealed ciphertext  │  ← auth tag appended by CryptoKit (16B)
└──────────────────────────────────────┘

Plaintext payload (before encryption):
  4 bytes LE uint32: sampleCount S
  S × 4 bytes: Float32 LE PCM samples (24 kHz mono)
  4 bytes LE uint32: transcriptByteLen T
  T bytes: UTF-8 transcript
```

Header JSON schema (all fields required):
```json
{
  "formatVersion": 1,
  "id": "<UUID>",
  "name": "My Voice",
  "createdAt": "<ISO 8601>",
  "durationSeconds": 28.5,
  "sampleRate": 24000,
  "sampleCount": 684000,
  "quality": {
    "peakRmsDbfs": -18.3,
    "hasClipping": false,
    "voicedDurationSeconds": 25.1,
    "grade": "good"
  }
}
```

`grade` values: `"good"` | `"fair"` | `"poor"` (see § 3.3).

### 1.4 Architecture

Four new types, responsibility-separated:

| Type | Kind | Responsibility |
|------|------|---------------|
| `VoiceProfile` | Struct | Pure data model: header metadata + (optional) decrypted payload |
| `VoiceProfileStore` | Actor | File I/O, encryption/decryption, Keychain key management |
| `VoiceProfileRecorder` | Actor | AVAudioEngine capture, quality validation, SRC |
| `VoiceProfileManager` | `@MainActor ObservableObject` | UI state machine; owns store + recorder; active profile selection |

UI lives in `Features/VoiceCloning/` with four views.

---

## 2. Component Inventory

### New files — `Core/VoiceCloning/`

| File | Role |
|------|------|
| `VoiceProfile.swift` | `VoiceProfile` struct + `VoiceQualityMetrics` struct + `VoiceQualityGrade` enum |
| `VoiceProfileStore.swift` | Actor; CRUD + AES-256-GCM encrypt/decrypt; Keychain key; injectable URL |
| `VoiceProfileRecorder.swift` | Actor; `AVAudioEngine` capture at 24 kHz; `AVAudioConverter` SRC if needed; quality validation |
| `VoiceProfileManager.swift` | `@MainActor ObservableObject`; recording state machine; `@Published` properties for all UI state |

### New files — `Features/VoiceCloning/`

| File | Role |
|------|------|
| `VoiceProfileListView.swift` | Settings sheet: profile list + empty state + Add/Delete |
| `VoiceProfileDetailView.swift` | Detail pane: metrics, transcript excerpt, rename, delete |
| `VoiceRecordingView.swift` | Capture step: level meter, countdown, quality indicator, Stop button |
| `VoiceTranscriptView.swift` | Review step: transcript text field, quality warning, Re-record / Save |

### Modified files

| File | Change |
|------|--------|
| `Features/Main/AudioViewModel.swift` | Own `VoiceProfileManager`; pass `isRunning` flag to `VoiceProfileRecorder` |
| `Core/TTS/TTSEngineSelector.swift` | Add `activeVoiceProfile: VoiceProfile?` read from `VoiceProfileManager`; expose `voiceCloningAvailable: Bool` |
| `Features/ContentView.swift` | Add "Voice Profiles" settings row that presents `VoiceProfileListView` |

### New test files — `TranslateCallTests/`

| File | Coverage |
|------|----------|
| `VoiceProfileStoreTests.swift` | Save/load round-trip; corrupt file; missing key; rename; delete |
| `VoiceProfileRecorderTests.swift` | Quality validation thresholds; SRC output format; session conflict |
| `VoiceProfileManagerTests.swift` | State machine transitions; active profile persistence; concurrent ops |

### New test support — `TranslateCallTests/Mocks/`

| File | Role |
|------|------|
| `MockVoiceProfileStore.swift` | Actor; in-memory; injectable into `VoiceProfileManager` |

---

## 3. Detailed Component Design

### 3.1 `VoiceProfile.swift`

```swift
import Foundation

// MARK: - Quality

enum VoiceQualityGrade: String, Codable, Sendable {
    case good  // REQ-VCP-12: RMS ≥ -20 dBFS, no clipping, voiced ≥ 20 s
    case fair  // RMS ≥ -30 dBFS, no clipping, voiced ≥ 10 s
    case poor  // RMS < -30 dBFS OR clipping OR voiced < 10 s (blocks save)
}

struct VoiceQualityMetrics: Codable, Sendable {
    let peakRmsDbfs: Float          // REQ-VCP-12, REQ-VCP-13
    let hasClipping: Bool           // REQ-VCP-14: any sample ≥ 0.98 FS in > 0.1% of frames
    let voicedDurationSeconds: Float // REQ-VCP-15
    let grade: VoiceQualityGrade
}

// MARK: - Profile header (always in memory after enumeration)

struct VoiceProfileHeader: Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    let durationSeconds: Float
    let sampleRate: Int             // always 24000
    let sampleCount: Int            // durationSeconds × 24000
    let quality: VoiceQualityMetrics
    let formatVersion: Int          // = 1

    var transcriptExcerpt: String   // NOT stored in header; populated after decryption for detail view
        = ""
}

// MARK: - Full profile (header + optional decrypted payload)

struct VoiceProfile: Sendable {
    let header: VoiceProfileHeader

    // Populated only after decrypt(); nil when loaded from header-only enumeration
    var samples: [Float]?           // Float32 PCM at 24 kHz mono
    var transcript: String?         // Full verbatim transcript

    var isDecrypted: Bool { samples != nil }
}
```

### 3.2 `VoiceProfileStore.swift`

```swift
import CryptoKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "VoiceProfileStore")

// MARK: - Protocol (for MockVoiceProfileStore injection)

protocol VoiceProfileStoring: Actor {
    func enumerateHeaders() async throws -> [VoiceProfileHeader]
    func save(profile: VoiceProfile) async throws
    func load(id: UUID) async throws -> VoiceProfile        // decrypts payload
    func delete(id: UUID) async throws
    func updateName(_ name: String, for id: UUID) async throws
}

// MARK: - Implementation

actor VoiceProfileStore: VoiceProfileStoring {

    // MARK: - Storage URL (injectable for tests — REQ-VCP-NF-13)

    private let storageURL: URL

    init(storageURL: URL = VoiceProfileStore.defaultStorageURL) {
        self.storageURL = storageURL
    }

    static var defaultStorageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("TranslateCall/VoiceProfiles", isDirectory: true)
    }

    // MARK: - Keychain key (one key per app, lazy)

    private var _encryptionKey: SymmetricKey?

    private func encryptionKey() throws -> SymmetricKey {
        if let key = _encryptionKey { return key }
        let key = try KeychainKeyStore.loadOrCreate()
        _encryptionKey = key
        return key
    }

    // MARK: - Enumeration (REQ-VCP-20: header-only, no audio decrypted)

    func enumerateHeaders() async throws -> [VoiceProfileHeader] {
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: storageURL, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "vpf" }

        return files.compactMap { url in
            do {
                return try readHeader(from: url)
            } catch {
                logger.error("Skipping corrupt profile at \(url.lastPathComponent): \(error)")
                return nil  // REQ-VCP-NF-12
            }
        }
    }

    // MARK: - Save (REQ-VCP-17)

    func save(profile: VoiceProfile) async throws {
        guard let samples = profile.samples, let transcript = profile.transcript else {
            throw VoiceProfileError.payloadMissing
        }
        let key = try encryptionKey()
        let fileURL = storageURL.appendingPathComponent("\(profile.header.id).vpf")

        // 1. Encode payload
        let payload = encodePayload(samples: samples, transcript: transcript)
        // 2. Encrypt
        let sealed = try AES.GCM.seal(payload, using: key)
        // 3. Encode header JSON
        let headerData = try JSONEncoder().encode(profile.header)
        // 4. Build file bytes
        var fileBytes = Data()
        var headerLen = UInt32(headerData.count).littleEndian
        fileBytes.append(contentsOf: withUnsafeBytes(of: &headerLen) { Data($0) })
        fileBytes.append(headerData)
        fileBytes.append(sealed.nonce.withUnsafeBytes { Data($0) })    // 12 bytes
        fileBytes.append(sealed.ciphertext)
        fileBytes.append(sealed.tag)                                    // 16 bytes
        // 5. Atomic write (no partial file — REQ-VCP-19)
        let tmpURL = storageURL.appendingPathComponent("\(profile.header.id).tmp")
        try fileBytes.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        logger.info("Saved voice profile \(profile.header.id)")
    }

    // MARK: - Load / decrypt (REQ-VCP-21)

    func load(id: UUID) async throws -> VoiceProfile {
        let key = try encryptionKey()
        let fileURL = storageURL.appendingPathComponent("\(id).vpf")
        let data = try Data(contentsOf: fileURL)
        let (header, payloadData) = try parseFile(data: data, key: key)
        let (samples, transcript) = try decodePayload(payloadData)
        return VoiceProfile(header: header, samples: samples, transcript: transcript)
    }

    // MARK: - Delete (REQ-VCP-26, REQ-VCP-NF-09: secure delete)

    func delete(id: UUID) async throws {
        let fileURL = storageURL.appendingPathComponent("\(id).vpf")
        // Overwrite with zeros then remove
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size > 0 {
                let zeros = Data(repeating: 0, count: size)
                try zeros.write(to: fileURL)
            }
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Rename (REQ-VCP-25: name in header only, no re-encryption)

    func updateName(_ name: String, for id: UUID) async throws {
        let fileURL = storageURL.appendingPathComponent("\(id).vpf")
        var data = try Data(contentsOf: fileURL)
        var header = try readHeader(from: fileURL)
        header.name = name
        let newHeaderData = try JSONEncoder().encode(header)
        // Rebuild just the header portion, keep the rest (nonce + ciphertext + tag) intact
        var newFile = Data()
        var newLen = UInt32(newHeaderData.count).littleEndian
        newFile.append(contentsOf: withUnsafeBytes(of: &newLen) { Data($0) })
        newFile.append(newHeaderData)
        // Append everything after the original header (nonce+cipher+tag)
        let originalHeaderLen = Int(UInt32(littleEndian: data[..<4].withUnsafeBytes { $0.load(as: UInt32.self) }))
        newFile.append(data[(4 + originalHeaderLen)...])
        try newFile.write(to: fileURL, options: .atomic)
    }

    // MARK: - Private helpers

    private func readHeader(from url: URL) throws -> VoiceProfileHeader {
        let data = try Data(contentsOf: url)
        guard data.count >= 4 else { throw VoiceProfileError.corruptFile }
        let headerLen = Int(UInt32(littleEndian: data[..<4].withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard data.count >= 4 + headerLen else { throw VoiceProfileError.corruptFile }
        return try JSONDecoder().decode(VoiceProfileHeader.self, from: data[4..<(4 + headerLen)])
    }

    private func parseFile(data: Data, key: SymmetricKey) throws -> (VoiceProfileHeader, Data) {
        guard data.count >= 4 else { throw VoiceProfileError.corruptFile }
        let headerLen = Int(UInt32(littleEndian: data[..<4].withUnsafeBytes { $0.load(as: UInt32.self) }))
        let headerData = data[4..<(4 + headerLen)]
        let header = try JSONDecoder().decode(VoiceProfileHeader.self, from: headerData)
        let rest = data[(4 + headerLen)...]
        guard rest.count > 28 else { throw VoiceProfileError.corruptFile } // 12 nonce + 16 tag minimum
        let nonce = try AES.GCM.Nonce(data: rest[..<12])
        let ciphertext = rest[12...(rest.endIndex - 17)]
        let tag = rest[(rest.endIndex - 16)...]
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        return (header, plaintext)
    }

    private func encodePayload(samples: [Float], transcript: String) -> Data {
        var data = Data()
        var sampleCount = UInt32(samples.count).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &sampleCount) { Data($0) })
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        let transcriptBytes = transcript.data(using: .utf8) ?? Data()
        var transcriptLen = UInt32(transcriptBytes.count).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &transcriptLen) { Data($0) })
        data.append(transcriptBytes)
        return data
    }

    private func decodePayload(_ data: Data) throws -> ([Float], String) {
        var offset = data.startIndex
        guard data.count >= 4 else { throw VoiceProfileError.corruptFile }
        let sampleCount = Int(UInt32(littleEndian: data[offset..<(offset + 4)].withUnsafeBytes { $0.load(as: UInt32.self) }))
        offset += 4
        let sampleBytes = sampleCount * MemoryLayout<Float>.size
        guard data.count >= offset + sampleBytes + 4 else { throw VoiceProfileError.corruptFile }
        let samples = data[offset..<(offset + sampleBytes)].withUnsafeBytes {
            Array(UnsafeBufferPointer<Float>(start: $0.baseAddress!.assumingMemoryBound(to: Float.self),
                                             count: sampleCount))
        }
        offset += sampleBytes
        let transcriptLen = Int(UInt32(littleEndian: data[offset..<(offset + 4)].withUnsafeBytes { $0.load(as: UInt32.self) }))
        offset += 4
        guard data.count >= offset + transcriptLen else { throw VoiceProfileError.corruptFile }
        let transcript = String(data: data[offset..<(offset + transcriptLen)], encoding: .utf8) ?? ""
        return (samples, transcript)
    }
}

// MARK: - Errors

enum VoiceProfileError: LocalizedError {
    case payloadMissing
    case corruptFile
    case keychainError(OSStatus)
    case encryptionFailed

    var errorDescription: String? {
        switch self {
        case .payloadMissing:       return "Voice profile has no audio data."
        case .corruptFile:          return "Voice profile file is corrupt or unreadable."
        case .keychainError(let s): return "Keychain error (\(s)) — cannot access encryption key."
        case .encryptionFailed:     return "Failed to encrypt voice profile data."
        }
    }
}
```

### 3.3 `KeychainKeyStore` (internal helper, same file or `VoiceProfileStore.swift`)

```swift
import CryptoKit
import Foundation
import Security

enum KeychainKeyStore {
    private static let service = "com.spbarber.TranslateCall.voiceProfiles"
    private static let account = "aes256EncryptionKey"

    static func loadOrCreate() throws -> SymmetricKey {
        if let existing = try? load() { return existing }
        let key = SymmetricKey(size: .bits256)
        try store(key)
        return key
    }

    private static func load() throws -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     service,
            kSecAttrAccount:     account,
            kSecReturnData:      true,
            kSecMatchLimit:      kSecMatchLimitOne,
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
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        service,
            kSecAttrAccount:        account,
            kSecAttrAccessible:     kSecAttrAccessibleWhenUnlocked,
            kSecValueData:          keyData,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VoiceProfileError.keychainError(status)
        }
    }
}
```

### 3.4 `VoiceProfileRecorder.swift`

```swift
import AVFoundation
import Accelerate
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "VoiceProfileRecorder")

// MARK: - Recording result

struct RecordingResult: Sendable {
    let samples: [Float]            // 24 kHz mono Float32
    let durationSeconds: Float
    let quality: VoiceQualityMetrics
}

actor VoiceProfileRecorder {

    // MARK: - Dependencies

    private var isSessionActive: () -> Bool     // injected; checks AudioCoordinator.isRunning

    // MARK: - Engine

    private var engine: AVAudioEngine?
    private var capturedSamples: [Float] = []
    private let targetSampleRate: Double = 24_000

    // MARK: - Level stream (REQ-VCP-04: ≥ 10 Hz update)

    private let levelContinuation: AsyncStream<Float>.Continuation
    nonisolated let levelStream: AsyncStream<Float>

    // MARK: - Init

    init(isSessionActive: @escaping @Sendable () -> Bool = { false }) {
        self.isSessionActive = isSessionActive
        var cont: AsyncStream<Float>.Continuation!
        levelStream = AsyncStream { cont = $0 }
        levelContinuation = cont
    }

    // MARK: - Public API

    /// Starts recording. Throws if microphone is unavailable or session is active.
    func startRecording() async throws {
        guard !isSessionActive() else {
            throw VoiceProfileRecorderError.sessionConflict   // REQ-VCP-NF-14
        }
        guard await requestMicrophonePermission() else {
            throw VoiceProfileRecorderError.permissionDenied  // REQ-VCP-01/02
        }
        capturedSamples = []
        try setupEngine()
        try engine!.start()
        logger.info("VoiceProfileRecorder: recording started")
    }

    /// Stops recording and returns the result including quality metrics.
    func stopRecording() async throws -> RecordingResult {
        guard let eng = engine else { throw VoiceProfileRecorderError.notRecording }
        eng.stop()
        eng.inputNode.removeTap(onBus: 0)
        engine = nil

        let metrics = computeQuality(samples: capturedSamples)
        let duration = Float(capturedSamples.count) / Float(targetSampleRate)
        logger.info("VoiceProfileRecorder: stopped. \(capturedSamples.count) samples, grade=\(metrics.grade.rawValue)")
        return RecordingResult(samples: capturedSamples, durationSeconds: duration, quality: metrics)
    }

    // MARK: - Private: AVAudioEngine

    private func setupEngine() throws {
        let eng = AVAudioEngine()
        self.engine = eng

        let inputNode = eng.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 24 kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw VoiceProfileRecorderError.engineSetupFailed }

        // SRC converter if native rate differs (e.g. 48 kHz)
        let converter: AVAudioConverter? = inputFormat.sampleRate == targetSampleRate
            ? nil
            : AVAudioConverter(from: inputFormat, to: targetFormat)

        // Install tap — nonisolated context (audio thread)
        // Capture `self` as unowned is unsafe; use a Sendable closure with @Sendable capture
        let cont = levelContinuation
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let pcm: AVAudioPCMBuffer
            if let conv = converter {
                pcm = Self.resample(buffer, converter: conv, targetFormat: targetFormat) ?? buffer
            } else {
                pcm = buffer
            }
            let monoSamples = Self.extractMono(pcm)
            // Post level update at ≥ 10 Hz (tap fires at ~43 Hz for bufferSize 1024 at 44.1 kHz)
            let rms = Self.computeRMS(monoSamples)
            cont.yield(rms)
            // Append to buffer — use Task to hop back to actor
            Task { await self.appendSamples(monoSamples) }
        }
    }

    private func appendSamples(_ new: [Float]) {
        capturedSamples.append(contentsOf: new)
    }

    // MARK: - Private: SRC (nonisolated static — safe on audio thread)

    private static func resample(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return nil }
        var consumed = false
        let status = converter.convert(to: out, error: nil) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : out
    }

    private static func extractMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    // MARK: - Private: Quality Validation (REQ-VCP-12 to REQ-VCP-16)

    private static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -60 }
        var rms: Float = 0
        vDSP_measqv(samples, 1, &rms, vDSP_Length(samples.count))
        let dbfs = rms > 0 ? 10 * log10f(rms) : -60
        return dbfs
    }

    private func computeQuality(samples: [Float]) -> VoiceQualityMetrics {
        guard !samples.isEmpty else {
            return VoiceQualityMetrics(peakRmsDbfs: -60, hasClipping: false,
                                       voicedDurationSeconds: 0, grade: .poor)
        }
        // Peak RMS over all samples
        let peakRms = Self.computeRMS(samples)

        // Clipping: any |sample| ≥ 0.98 in > 0.1% of frames (REQ-VCP-14)
        let clippedCount = samples.filter { abs($0) >= 0.98 }.count
        let hasClipping = Float(clippedCount) / Float(samples.count) > 0.001

        // Voiced duration: frames above -40 dBFS threshold (REQ-VCP-12)
        let voiceThreshold: Float = 0.01  // -40 dBFS ≈ 0.01 RMS
        let chunkSize = 240  // 10ms at 24kHz
        var voicedChunks = 0
        let chunks = samples.count / chunkSize
        for i in 0..<chunks {
            let chunk = Array(samples[(i * chunkSize)..<((i + 1) * chunkSize)])
            var chunkRms: Float = 0
            vDSP_measqv(chunk, 1, &chunkRms, vDSP_Length(chunkSize))
            if chunkRms >= voiceThreshold { voicedChunks += 1 }
        }
        let voicedDuration = Float(voicedChunks * chunkSize) / Float(targetSampleRate)

        // Grade logic
        let grade: VoiceQualityGrade
        if peakRms < -30 || voicedDuration < 8 || hasClipping {
            grade = .poor
        } else if peakRms < -20 || voicedDuration < 20 {
            grade = .fair
        } else {
            grade = .good
        }

        return VoiceQualityMetrics(
            peakRmsDbfs: peakRms,
            hasClipping: hasClipping,
            voicedDurationSeconds: voicedDuration,
            grade: grade
        )
    }

    // MARK: - Private: Permission

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }
}

enum VoiceProfileRecorderError: LocalizedError {
    case permissionDenied
    case sessionConflict
    case engineSetupFailed
    case notRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied:    return "Microphone access denied. Check System Settings > Privacy > Microphone."
        case .sessionConflict:     return "Recording is unavailable while a translation session is active."
        case .engineSetupFailed:   return "Failed to configure the recording engine."
        case .notRecording:        return "No recording is in progress."
        }
    }
}
```

### 3.5 `VoiceProfileManager.swift`

State machine drives all UI transitions (REQ-VCP-01 through REQ-VCP-31).

```swift
import Foundation
import Combine

// MARK: - Recording state machine

enum RecordingState: Equatable, Sendable {
    case idle
    case recording(elapsedSeconds: Float)
    case processing                   // quality check in progress
    case reviewing(RecordingResult)   // transcript entry step
    case saving
    case error(String)
}

@MainActor
final class VoiceProfileManager: ObservableObject {

    // MARK: - Published (UI bindings)

    @Published private(set) var profiles: [VoiceProfileHeader] = []
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var transcript: String = ""
    @Published private(set) var pendingProfileName: String = "My Voice"
    @Published var activeProfileId: UUID?            // REQ-VCP-29

    var activeProfile: VoiceProfileHeader? {
        profiles.first { $0.id == activeProfileId }
    }

    // MARK: - Dependencies (injectable)

    private let store: any VoiceProfileStoring
    private let recorder: VoiceProfileRecorder
    private let defaults: UserDefaults

    private static let activeProfileKey = "tlk.voiceCloning.activeProfileId"

    // MARK: - Elapsed timer

    private var elapsedTask: Task<Void, Never>?
    private var elapsedSeconds: Float = 0

    // MARK: - Init

    init(
        store: any VoiceProfileStoring = VoiceProfileStore(),
        recorder: VoiceProfileRecorder = VoiceProfileRecorder(),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.recorder = recorder
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.activeProfileKey),
           let id = UUID(uuidString: raw) {
            activeProfileId = id
        }
        Task { await loadProfiles() }
    }

    // MARK: - Profile loading (REQ-VCP-20)

    func loadProfiles() async {
        do {
            profiles = try await store.enumerateHeaders()
                .sorted { $0.createdAt > $1.createdAt }
            // Validate active profile still exists (REQ-VCP-30)
            if let id = activeProfileId, !profiles.contains(where: { $0.id == id }) {
                activeProfileId = nil
                defaults.removeObject(forKey: Self.activeProfileKey)
            }
        } catch {
            // Non-fatal; empty list shown
        }
    }

    // MARK: - Recording flow (REQ-VCP-01 to REQ-VCP-07)

    func startRecording() async {
        recordingState = .recording(elapsedSeconds: 0)
        elapsedSeconds = 0
        startElapsedTimer()
        do {
            try await recorder.startRecording()
        } catch {
            stopElapsedTimer()
            recordingState = .error(error.localizedDescription)
        }
    }

    func stopRecording() async {
        stopElapsedTimer()
        recordingState = .processing
        do {
            let result = try await recorder.stopRecording()
            recordingState = .reviewing(result)          // advance to transcript step
        } catch {
            recordingState = .error(error.localizedDescription)
        }
    }

    // MARK: - Transcript & save (REQ-VCP-08 to REQ-VCP-11, REQ-VCP-17/18/19)

    func saveProfile(name: String, transcript: String, result: RecordingResult) async throws {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceProfileValidationError.emptyTranscript  // REQ-VCP-09
        }
        recordingState = .saving
        let id = UUID()
        let header = VoiceProfileHeader(
            id: id,
            name: name.isEmpty ? "My Voice" : name,
            createdAt: .now,
            durationSeconds: result.durationSeconds,
            sampleRate: 24_000,
            sampleCount: result.samples.count,
            quality: result.quality,
            formatVersion: 1
        )
        let profile = VoiceProfile(
            header: header,
            samples: result.samples,
            transcript: transcript
        )
        do {
            try await store.save(profile: profile)
            await loadProfiles()
            recordingState = .idle
        } catch {
            recordingState = .error(error.localizedDescription)
            throw error
        }
    }

    func discardAndReRecord() {
        recordingState = .idle
        transcript = ""
    }

    // MARK: - Management (REQ-VCP-22 to REQ-VCP-28)

    func delete(id: UUID) async throws {
        try await store.delete(id: id)
        if activeProfileId == id {
            setActiveProfile(nil)              // REQ-VCP-26
        }
        await loadProfiles()
    }

    func rename(id: UUID, newName: String) async throws {
        try await store.updateName(newName, for: id)
        await loadProfiles()
    }

    // MARK: - Active profile (REQ-VCP-28 to REQ-VCP-31)

    func setActiveProfile(_ id: UUID?) {
        activeProfileId = id
        if let id {
            defaults.set(id.uuidString, forKey: Self.activeProfileKey)
        } else {
            defaults.removeObject(forKey: Self.activeProfileKey)
        }
    }

    // MARK: - Private: elapsed timer

    private func startElapsedTimer() {
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.elapsedSeconds += 0.1
                self.recordingState = .recording(elapsedSeconds: self.elapsedSeconds)
                // Auto-stop at 30 s (REQ-VCP-05)
                if self.elapsedSeconds >= 30 {
                    await self.stopRecording()
                    return
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }
}

enum VoiceProfileValidationError: LocalizedError {
    case emptyTranscript
    var errorDescription: String? { "A transcript is required for voice cloning quality." }
}
```

---

## 4. UI Design

### 4.1 `VoiceRecordingView.swift` (Capture step)

```
┌─────────────────────────────────────────────┐
│  Record Your Voice                     ✕    │
│─────────────────────────────────────────────│
│  Speak naturally for up to 30 seconds.      │
│  A transcript of what you say is required.  │
│                                             │
│  ████████████░░░░░░░░░░░░  18.4 s / 30 s   │ ← progress bar
│                                             │
│  ┌─────────────────────────────────────┐   │
│  │  〜〜〜〜〜〜〜〜〜〜〜〜〜〜〜   │   │ ← WaveformView (level stream)
│  └─────────────────────────────────────┘   │
│                                             │
│  ● GOOD   (level indicator badge)          │
│                                             │
│          [ Stop Recording ]                 │
└─────────────────────────────────────────────┘
```

`WaveformView`: scrolling 1-second window of RMS values drawn as bars, subscribes to `recorder.levelStream` (already an `AsyncStream<Float>` accessible `nonisolated`).

Quality badge colours: green = `.good`, amber = `.fair`, red = `.poor`.

### 4.2 `VoiceTranscriptView.swift` (Review step)

```
┌─────────────────────────────────────────────┐
│  Review & Save                         ✕    │
│─────────────────────────────────────────────│
│  Profile name: [My Voice            ]       │
│                                             │
│  What did you say? (required)               │
│  ┌─────────────────────────────────────┐   │
│  │  Hello, my name is...               │   │ ← TextEditor
│  │                                     │   │
│  └─────────────────────────────────────┘   │
│  142 / 2000 characters                      │
│                                             │
│  Duration: 28.5 s  ●GOOD  Peak: -18 dBFS   │ ← quality row
│                                             │
│  [ Re-record ]          [ Save Profile ]    │
└─────────────────────────────────────────────┘
```

"Save Profile" disabled when transcript is empty (REQ-VCP-09).

Quality warning banners (amber/red) appear between the waveform preview and the text field when `.fair` or `.poor`.

### 4.3 `VoiceProfileListView.swift`

```
Voice Profiles                       [+ Add]

┌─────────────────────────────────────────────┐
│  ✓ My Voice      Mar 12  28s  ● GOOD       │ ← active profile (checkmark)
│    Work Voice    Mar 11  30s  ● FAIR       │
└─────────────────────────────────────────────┘
```

Swipe-to-delete with confirmation alert (REQ-VCP-26). Tap row → `VoiceProfileDetailView`.

Empty state: SF Symbol `waveform.badge.mic`, "Record your first profile" button → starts recording flow.

### 4.4 `VoiceProfileDetailView.swift`

Shows: name (editable inline), created date, duration, quality metrics grid, transcript excerpt. "Delete" button (destructive, confirmation alert). "Set as Active" / "Remove as Active" toggle button.

---

## 5. TTSEngineSelector Integration

F7.2 will use the active voice profile for conditioning. F7.1 only needs to expose the profile reference:

```swift
// TTSEngineSelector additions (F7.1 scope: read-only wiring)
@Published private(set) var activeVoiceProfile: VoiceProfileHeader?

var voiceCloningAvailable: Bool { activeVoiceProfile != nil }
```

`AudioViewModel` passes `VoiceProfileManager.activeProfile` into `TTSEngineSelector` via a Combine sink or direct call whenever it changes. No synthesis changes in F7.1 — this wiring only gates the UI toggle in F7.3.

---

## 6. Data Flow

```
User taps "Add Profile"
  │
  ├── VoiceProfileManager.startRecording()
  │     └── VoiceProfileRecorder.startRecording()
  │           ├── requestMicrophonePermission()
  │           └── AVAudioEngine.start() → tap installs → Float32 samples stream in
  │
  ├── [30 s elapses or user taps Stop]
  │     └── VoiceProfileRecorder.stopRecording()
  │           ├── engine.stop(); remove tap
  │           └── computeQuality(samples:) → VoiceQualityMetrics
  │                 recordingState = .reviewing(result)
  │
  ├── User enters transcript, taps "Save Profile"
  │     └── VoiceProfileManager.saveProfile(name:transcript:result:)
  │           ├── encodePayload(samples:transcript:) → Data
  │           ├── AES.GCM.seal(payload, using: key) → SealedBox
  │           ├── build .vpf bytes (header + nonce + ciphertext+tag)
  │           └── atomic write to ~/Library/...VoiceProfiles/<UUID>.vpf
  │
  └── VoiceProfileManager.loadProfiles() → profiles list updated in UI

F7.2 reads profile:
  └── VoiceProfileStore.load(id:)
        ├── read .vpf file
        ├── AES.GCM.open(sealedBox, using: key) → plaintext
        └── decodePayload → ([Float], String)
              └── pass to CSM-1B as ref_audio (24kHz PCM) + ref_text
```

---

## 7. Error Handling

| Error | Source | Handling |
|-------|--------|----------|
| Microphone permission denied | `requestMicrophonePermission()` | `recordingState = .error(...)` + alert directing to System Settings |
| Session conflict (AudioCoordinator active) | `startRecording()` | Alert: "Stop the translation session before recording" |
| Engine setup failed | `setupEngine()` | `recordingState = .error(...)` |
| Audio interruption mid-recording | AVAudioSession interruption | Engine stops; `stopRecording()` called; captured samples discarded (REQ-VCP-NF-11) |
| Empty transcript | `saveProfile()` | Validation error shown inline; save blocked (REQ-VCP-09) |
| Keychain error | `KeychainKeyStore.loadOrCreate()` | `VoiceProfileError.keychainError` propagated → alert (REQ-VCP-19) |
| Write failed | `VoiceProfileStore.save()` | Tmp file removed; alert shown; `recordingState = .error(...)` |
| Corrupt `.vpf` on load | `enumerateHeaders()` | File silently skipped; logged (REQ-VCP-NF-12) |
| Decryption failed | `VoiceProfileStore.load()` | `VoiceProfileError.corruptFile` thrown to caller |
| Active profile file deleted externally | `loadProfiles()` | Active profile reset to nil; silent log (REQ-VCP-30) |

---

## 8. Testing Strategy

All test structs use `@Suite @MainActor` (established pattern). `VoiceProfileStoreTests` uses a temporary directory URL injected via `VoiceProfileStore(storageURL:)`.

### `VoiceProfileStoreTests.swift`

| Test | Verifies |
|------|----------|
| `saveAndLoadRoundTrip` | Save → load → samples and transcript match exactly |
| `headerOnlyEnumeration` | `enumerateHeaders()` does not decrypt; payload not in memory |
| `corruptFileSkipped` | File with random bytes: enumeration succeeds for other files |
| `decryptionFailsGracefully` | Tampered ciphertext → `corruptFile` error |
| `renamePreservesPayload` | Rename → load → same samples and transcript |
| `secureDeleteRemovesFile` | After delete, no `.vpf` file at expected path |
| `activeProfileResetOnMissingFile` | Store saved UUID that has no file → manager resets activeProfileId |
| `keychainUnavailableThrows` | Mock Keychain throws → `VoiceProfileError.keychainError` |

### `VoiceProfileRecorderTests.swift`

| Test | Verifies |
|------|----------|
| `qualityGoodSamples` | RMS −18 dBFS, no clipping, 25 s voiced → grade `.good` |
| `qualityFairLowLevel` | RMS −25 dBFS → grade `.fair` |
| `qualityPoorClipping` | > 0.1% samples ≥ 0.98 → grade `.poor`, `hasClipping = true` |
| `qualityPoorShortVoiced` | < 8 s voiced → grade `.poor` |
| `sessionConflictBlocks` | `isSessionActive = { true }` → `startRecording()` throws `.sessionConflict` |
| `outputFormatIs24kHz` | After `stopRecording()`, result samples count = duration × 24000 |

### `VoiceProfileManagerTests.swift`

| Test | Verifies |
|------|----------|
| `activeProfilePersistedAndRestored` | Set active → simulate launch via new `init` → same UUID restored |
| `activeProfileResetWhenFileGone` | Active UUID not in enumerated headers → `activeProfileId = nil` |
| `deleteResetsActiveProfile` | Delete active profile → `activeProfileId = nil` |
| `saveRequiresTranscript` | `saveProfile(transcript: "")` throws `.emptyTranscript` |
| `stateMachineTransitions` | idle → recording → processing → reviewing → saving → idle |

### `MockVoiceProfileStore.swift`

```swift
actor MockVoiceProfileStore: VoiceProfileStoring {
    var storedProfiles: [UUID: VoiceProfile] = [:]
    var shouldThrowOnSave: Error?
    var shouldThrowOnLoad: Error?

    func enumerateHeaders() async throws -> [VoiceProfileHeader] {
        storedProfiles.values.map(\.header).sorted { $0.createdAt > $1.createdAt }
    }
    func save(profile: VoiceProfile) async throws {
        if let e = shouldThrowOnSave { throw e }
        storedProfiles[profile.header.id] = profile
    }
    func load(id: UUID) async throws -> VoiceProfile {
        if let e = shouldThrowOnLoad { throw e }
        guard let p = storedProfiles[id] else { throw VoiceProfileError.corruptFile }
        return p
    }
    func delete(id: UUID) async throws { storedProfiles.removeValue(forKey: id) }
    func updateName(_ name: String, for id: UUID) async throws {
        storedProfiles[id]?.header.name = name
    }
}
```

---

## 9. Open Questions (resolve at implementation start)

| # | Question | Impact |
|---|----------|--------|
| OQ-1 | Does macOS 15 `AVAudioEngine` support `installTap` at a requested 24 kHz format, or must we tap at the device's native rate and SRC? | Whether `VoiceProfileRecorder.setupEngine()` needs the SRC path unconditionally |
| OQ-2 | Does `AVCaptureDevice.requestAccess(for: .audio)` fire the callback on main thread or arbitrary thread? | `requestMicrophonePermission()` thread safety |
| OQ-3 | Is `SecItemAdd` thread-safe when called from an actor? Or does it need a `DispatchQueue.main` dispatch? | `KeychainKeyStore` concurrency safety |
| OQ-4 | Does CryptoKit `AES.GCM.SealedBox` append the tag to `ciphertext` or expose it separately in all macOS 15 API versions? | `parseFile` extraction of nonce / ciphertext / tag byte layout |
| OQ-5 | Should `VoiceProfileRecorder.levelStream` drive `WaveformView` directly via `AsyncStream.forEach` in a `Task`, or use a Combine bridge? | UI update approach in `VoiceRecordingView` |

---

## 10. File Creation Order (dependency-safe)

1. `VoiceProfile.swift` — no deps
2. `VoiceProfileStore.swift` — depends on `VoiceProfile`, `CryptoKit`
3. `VoiceProfileRecorder.swift` — depends on `VoiceProfile`, `AVFoundation`, `Accelerate`
4. `VoiceProfileManager.swift` — depends on `VoiceProfileStore`, `VoiceProfileRecorder`
5. `MockVoiceProfileStore.swift` (test target) — depends on `VoiceProfileStore` protocol
6. `VoiceProfileStoreTests.swift` — depends on `VoiceProfileStore`
7. `VoiceProfileRecorderTests.swift` — depends on `VoiceProfileRecorder`
8. `VoiceProfileManagerTests.swift` — depends on `VoiceProfileManager`, `MockVoiceProfileStore`
9. `VoiceRecordingView.swift` — depends on `VoiceProfileManager`
10. `VoiceTranscriptView.swift` — depends on `VoiceProfileManager`
11. `VoiceProfileDetailView.swift` — depends on `VoiceProfileManager`
12. `VoiceProfileListView.swift` — depends on all views above
13. Modify `AudioViewModel.swift` — wire `VoiceProfileManager`
14. Modify `TTSEngineSelector.swift` — add `activeVoiceProfile` + `voiceCloningAvailable`
15. Modify `ContentView.swift` — add "Voice Profiles" settings row
