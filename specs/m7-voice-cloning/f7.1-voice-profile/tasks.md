# F7.1 — Voice Profile Training: Task Breakdown

> **Feature**: F7.1 — Voice Profile Training
> **Milestone**: M7 — Voice Cloning
> **Status**: DRAFT
> **Depends on**: design.md (approved)
> **Date**: 2026-03-12

---

## Overview

9 tasks in dependency order. T0 is a spike (resolve open questions from design.md § 9) and must complete before any implementation. Each subsequent task follows a TDD cycle (RED → GREEN → REFACTOR).

```
T0 (spike) ──▶ T1 (data model) ──▶ T2 (store + tests) ──▶ T4 (manager + tests)
                                          │                        │
                                          ▼                        ▼
                                    T3 (recorder + tests)    T5 (recording UI)
                                                               T6 (profile UI)
                                                               T7 (wiring)
                                                               T8 (integration)
```

---

## T0 — Spike: Resolve Open Questions

**Covers**: OQ-1 through OQ-5 from design.md § 9

### Steps

1. **OQ-1: AVAudioEngine `installTap` at 24 kHz** — Write a throwaway playground or test that creates an `AVAudioEngine`, calls `inputNode.outputFormat(forBus: 0)`, and tries `installTap(onBus:bufferSize:format:block:)` with a 24 kHz format. Determine:
   - Does macOS allow a tap at a non-native sample rate?
   - Or must we tap at the device's native rate (usually 48 kHz) and SRC down?
   - Document the finding. Update `VoiceProfileRecorder.setupEngine()` design if needed (the SRC fallback path is already designed).

2. **OQ-2: `AVCaptureDevice.requestAccess(for: .audio)` callback thread** — Check Apple docs or test empirically. Determine if the completion handler fires on main thread or arbitrary queue. If arbitrary: confirm `withCheckedContinuation` bridge is thread-safe (it is — continuation resume is safe from any thread).

3. **OQ-3: `SecItemAdd` thread safety from an actor** — Verify Security framework docs. Keychain APIs are thread-safe (confirmed in Security framework headers). Document that calling from an actor's isolated context is fine.

4. **OQ-4: CryptoKit `AES.GCM.SealedBox` layout** — Write a test:
   ```swift
   let key = SymmetricKey(size: .bits256)
   let plaintext = Data("test".utf8)
   let sealed = try AES.GCM.seal(plaintext, using: key)
   // Verify: sealed.nonce (12 bytes), sealed.ciphertext (N bytes), sealed.tag (16 bytes)
   // Are they separate properties, or is tag appended to ciphertext?
   ```
   Document the exact byte layout for `parseFile()`.

5. **OQ-5: Level stream UI approach** — Decide between `AsyncStream.forEach` in a `Task` vs Combine bridge. Given established project patterns (we use `AsyncStream` for `isSpeakingStream` and observe via `Task`), use the same `Task`-based approach. No Combine bridge needed.

6. **Create directory structure**: `mkdir -p TranslateCall/Core/VoiceCloning` and `TranslateCall/Features/VoiceCloning`.

### OQ Answers (to be resolved)

- **OQ-1**: (pending)
- **OQ-2**: (pending)
- **OQ-3**: (pending)
- **OQ-4**: (pending)
- **OQ-5**: Use `Task`-based `AsyncStream` observation (matches project pattern).

### Acceptance

- All 5 OQs answered with concrete findings.
- Directory structure created: `Core/VoiceCloning/`, `Features/VoiceCloning/`.
- Design.md updated if any OQ answer requires a change.

---

## T1 — Data Model + Errors

**Covers**: REQ-VCP-12 (quality metrics), REQ-VCP-16 (quality stored), REQ-VCP-17 (profile structure)

**Files to create**:
- `Core/VoiceCloning/VoiceProfile.swift` (NEW)

### Steps

1. **`VoiceQualityGrade` enum**:
   ```swift
   enum VoiceQualityGrade: String, Codable, Sendable {
       case good   // RMS ≥ -20 dBFS, no clipping, voiced ≥ 20 s
       case fair   // RMS ≥ -30 dBFS, no clipping, voiced ≥ 10 s
       case poor   // RMS < -30 dBFS OR clipping OR voiced < 10 s
   }
   ```

2. **`VoiceQualityMetrics` struct**:
   ```swift
   struct VoiceQualityMetrics: Codable, Sendable, Equatable {
       let peakRmsDbfs: Float
       let hasClipping: Bool
       let voicedDurationSeconds: Float
       let grade: VoiceQualityGrade
   }
   ```

3. **`VoiceProfileHeader` struct** — `Codable, Sendable, Identifiable`:
   ```swift
   struct VoiceProfileHeader: Codable, Sendable, Identifiable {
       let id: UUID
       var name: String
       let createdAt: Date
       let durationSeconds: Float
       let sampleRate: Int             // always 24000
       let sampleCount: Int
       let quality: VoiceQualityMetrics
       let formatVersion: Int          // = 1
   }
   ```
   - Use `JSONEncoder` with `.iso8601` date strategy for `createdAt`.

4. **`VoiceProfile` struct**:
   ```swift
   struct VoiceProfile: Sendable {
       let header: VoiceProfileHeader
       var samples: [Float]?
       var transcript: String?
       var isDecrypted: Bool { samples != nil }
   }
   ```

5. **`VoiceProfileError` enum** — `LocalizedError`:
   ```swift
   enum VoiceProfileError: LocalizedError {
       case payloadMissing
       case corruptFile
       case keychainError(OSStatus)
       case encryptionFailed
   }
   ```

6. **`VoiceProfileRecorderError` enum** — `LocalizedError`:
   ```swift
   enum VoiceProfileRecorderError: LocalizedError {
       case permissionDenied
       case sessionConflict
       case engineSetupFailed
       case notRecording
   }
   ```

7. **`VoiceProfileValidationError` enum**:
   ```swift
   enum VoiceProfileValidationError: LocalizedError {
       case emptyTranscript
   }
   ```

### Tests

```swift
// TranslateCallTests/VoiceProfileTests.swift
@Suite @MainActor struct VoiceProfileTests {

    @Test func qualityGradeRawValues() {
        #expect(VoiceQualityGrade(rawValue: "good") == .good)
        #expect(VoiceQualityGrade(rawValue: "fair") == .fair)
        #expect(VoiceQualityGrade(rawValue: "poor") == .poor)
    }

    @Test func headerCodableRoundTrip() throws {
        let header = VoiceProfileHeader(
            id: UUID(),
            name: "Test Voice",
            createdAt: Date(),
            durationSeconds: 28.5,
            sampleRate: 24000,
            sampleCount: 684000,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -18.3,
                hasClipping: false,
                voicedDurationSeconds: 25.1,
                grade: .good
            ),
            formatVersion: 1
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(header)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VoiceProfileHeader.self, from: data)
        #expect(decoded.id == header.id)
        #expect(decoded.name == header.name)
        #expect(decoded.sampleRate == 24000)
        #expect(decoded.quality.grade == .good)
    }

    @Test func profileIsDecryptedWhenSamplesPresent() {
        let header = makeHeader()
        var profile = VoiceProfile(header: header, samples: nil, transcript: nil)
        #expect(!profile.isDecrypted)
        profile.samples = [0.1, 0.2]
        #expect(profile.isDecrypted)
    }

    @Test func errorDescriptionsNonEmpty() {
        let errors: [any LocalizedError] = [
            VoiceProfileError.payloadMissing,
            VoiceProfileError.corruptFile,
            VoiceProfileError.keychainError(-25293),
            VoiceProfileError.encryptionFailed,
            VoiceProfileRecorderError.permissionDenied,
            VoiceProfileRecorderError.sessionConflict,
            VoiceProfileValidationError.emptyTranscript,
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    // MARK: - Helper

    private func makeHeader(grade: VoiceQualityGrade = .good) -> VoiceProfileHeader {
        VoiceProfileHeader(
            id: UUID(),
            name: "Test",
            createdAt: .now,
            durationSeconds: 28.5,
            sampleRate: 24000,
            sampleCount: 684000,
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
```

**Acceptance**: 4 tests pass. All types compile with `Sendable` conformance under strict concurrency.

---

## T2 — `VoiceProfileStore` + `KeychainKeyStore` + Tests

**Covers**: REQ-VCP-17 through REQ-VCP-21, REQ-VCP-25, REQ-VCP-26, REQ-VCP-NF-05 through REQ-VCP-NF-09, REQ-VCP-NF-12, REQ-VCP-NF-13

**Files to create**:
- `Core/VoiceCloning/VoiceProfileStore.swift` (NEW) — includes `VoiceProfileStoring` protocol, `VoiceProfileStore` actor, `KeychainKeyStore` helper

**Files to create (test target)**:
- `TranslateCallTests/Mocks/MockVoiceProfileStore.swift` (NEW)
- `TranslateCallTests/VoiceProfileStoreTests.swift` (NEW)

### Steps

1. **`VoiceProfileStoring` protocol**:
   ```swift
   protocol VoiceProfileStoring: Actor {
       func enumerateHeaders() async throws -> [VoiceProfileHeader]
       func save(profile: VoiceProfile) async throws
       func load(id: UUID) async throws -> VoiceProfile
       func delete(id: UUID) async throws
       func updateName(_ name: String, for id: UUID) async throws
   }
   ```

2. **`KeychainKeyStore` enum** (internal helper, same file):
   - `static func loadOrCreate() throws -> SymmetricKey`
   - `private static func load() -> SymmetricKey?` — `SecItemCopyMatching`
   - `private static func store(_ key: SymmetricKey) throws` — `SecItemAdd`
   - Service: `"com.spbarber.TranslateCall.voiceProfiles"`, account: `"aes256EncryptionKey"`
   - `kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked`

3. **`VoiceProfileStore` actor**:
   - `init(storageURL: URL = Self.defaultStorageURL)` — injectable for tests (REQ-VCP-NF-13)
   - `static var defaultStorageURL` → `~/Library/Application Support/TranslateCall/VoiceProfiles/`
   - **`enumerateHeaders()`**: create directory if needed; list `*.vpf` files; for each, `readHeader()` (REQ-VCP-20). `compactMap` with try/catch — skip corrupt files (REQ-VCP-NF-12).
   - **`save(profile:)`**:
     1. Guard `samples` and `transcript` non-nil, else throw `.payloadMissing`
     2. `encodePayload(samples:transcript:)` → binary `Data`
     3. `AES.GCM.seal(payload, using: key)` → `SealedBox`
     4. Encode header as JSON
     5. Build file: `[4B headerLen][header JSON][12B nonce][ciphertext][16B tag]`
     6. Write via temp file + atomic move (REQ-VCP-19: no partial files)
   - **`load(id:)`**: read file → `readHeader()` + `parseFile()` → decrypt → `decodePayload()` → return `VoiceProfile` with samples + transcript populated
   - **`delete(id:)`**: overwrite with zeros → `FileManager.removeItem` (REQ-VCP-NF-09 secure delete)
   - **`updateName(_:for:)`**: read file, re-encode header with new name, preserve nonce+ciphertext+tag unchanged (REQ-VCP-25: no re-encryption)
   - Private helpers: `readHeader(from:)`, `parseFile(data:key:)`, `encodePayload()`, `decodePayload()`

4. **`MockVoiceProfileStore`** (test target):
   ```swift
   actor MockVoiceProfileStore: VoiceProfileStoring {
       var storedProfiles: [UUID: VoiceProfile] = [:]
       var shouldThrowOnSave: Error?
       var shouldThrowOnLoad: Error?
       // implement protocol methods with in-memory storage
   }
   ```

5. **Payload binary format** (from design.md § 1.3):
   ```
   [4B LE uint32: sampleCount S]
   [S × 4 bytes: Float32 LE PCM]
   [4B LE uint32: transcriptByteLen T]
   [T bytes: UTF-8 transcript]
   ```

6. **JSON encoder/decoder** — use `.iso8601` date strategy for `VoiceProfileHeader`.

### Tests

```swift
// TranslateCallTests/VoiceProfileStoreTests.swift
@Suite @MainActor struct VoiceProfileStoreTests {

    /// Each test uses a unique temp directory
    func makeStore() throws -> (VoiceProfileStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceProfileStoreTests-\(UUID())")
        return (VoiceProfileStore(storageURL: dir), dir)
    }

    func makeProfile(
        name: String = "Test",
        samples: [Float] = Array(repeating: 0.5, count: 24000),
        transcript: String = "Hello world"
    ) -> VoiceProfile {
        let header = VoiceProfileHeader(
            id: UUID(), name: name, createdAt: .now,
            durationSeconds: Float(samples.count) / 24000,
            sampleRate: 24000, sampleCount: samples.count,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -18.0, hasClipping: false,
                voicedDurationSeconds: 1.0, grade: .good
            ),
            formatVersion: 1
        )
        return VoiceProfile(header: header, samples: samples, transcript: transcript)
    }

    @Test func saveAndLoadRoundTrip() async throws {
        let (store, _) = try makeStore()
        let original = makeProfile(samples: [0.1, 0.5, -0.3, 0.8], transcript: "Testing one two three")
        try await store.save(profile: original)
        let loaded = try await store.load(id: original.header.id)
        #expect(loaded.samples == original.samples)
        #expect(loaded.transcript == original.transcript)
        #expect(loaded.header.name == "Test")
        #expect(loaded.header.sampleRate == 24000)
    }

    @Test func headerOnlyEnumeration() async throws {
        let (store, _) = try makeStore()
        try await store.save(profile: makeProfile(name: "A"))
        try await store.save(profile: makeProfile(name: "B"))
        let headers = try await store.enumerateHeaders()
        #expect(headers.count == 2)
        // Headers should not contain decrypted samples
        // (VoiceProfileHeader has no samples field — enforced by struct design)
    }

    @Test func corruptFileSkipped() async throws {
        let (store, dir) = try makeStore()
        try await store.save(profile: makeProfile(name: "Good"))
        // Write a corrupt file
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let corruptURL = dir.appendingPathComponent("\(UUID()).vpf")
        try Data("not a valid vpf".utf8).write(to: corruptURL)
        let headers = try await store.enumerateHeaders()
        #expect(headers.count == 1)
        #expect(headers[0].name == "Good")
    }

    @Test func decryptionFailsOnTamperedCiphertext() async throws {
        let (store, dir) = try makeStore()
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
        let (store, _) = try makeStore()
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
        let (store, dir) = try makeStore()
        let profile = makeProfile()
        try await store.save(profile: profile)
        try await store.delete(id: profile.header.id)
        let fileURL = dir.appendingPathComponent("\(profile.header.id).vpf")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func saveWithoutPayloadThrows() async throws {
        let (store, _) = try makeStore()
        let header = VoiceProfileHeader(
            id: UUID(), name: "Empty", createdAt: .now,
            durationSeconds: 0, sampleRate: 24000, sampleCount: 0,
            quality: VoiceQualityMetrics(peakRmsDbfs: -60, hasClipping: false,
                                         voicedDurationSeconds: 0, grade: .poor),
            formatVersion: 1
        )
        let incomplete = VoiceProfile(header: header, samples: nil, transcript: nil)
        do {
            try await store.save(profile: incomplete)
            Issue.record("Expected payloadMissing error")
        } catch is VoiceProfileError {
            // Expected
        }
    }

    @Test func outputFormatIs24kHzFloat32() async throws {
        let (store, _) = try makeStore()
        let samples: [Float] = (0..<48000).map { Float(sin(Double($0) / 100.0)) }
        let profile = makeProfile(samples: samples, transcript: "Sine wave")
        try await store.save(profile: profile)
        let loaded = try await store.load(id: profile.header.id)
        #expect(loaded.header.sampleRate == 24000)
        #expect(loaded.samples?.count == 48000)
    }
}
```

**Acceptance**: 7 tests pass. Save/load round-trip preserves exact Float32 samples and UTF-8 transcript. Corrupt files are skipped without crash.

---

## T3 — `VoiceProfileRecorder` + Tests

**Covers**: REQ-VCP-01 through REQ-VCP-07, REQ-VCP-12 through REQ-VCP-16, REQ-VCP-NF-03, REQ-VCP-NF-10, REQ-VCP-NF-11, REQ-VCP-NF-14

**Files to create**:
- `Core/VoiceCloning/VoiceProfileRecorder.swift` (NEW)
- `TranslateCallTests/VoiceProfileRecorderTests.swift` (NEW)

### Steps

1. **`RecordingResult` struct**:
   ```swift
   struct RecordingResult: Sendable {
       let samples: [Float]           // 24 kHz mono Float32
       let durationSeconds: Float
       let quality: VoiceQualityMetrics
   }
   ```

2. **`VoiceProfileRecorder` actor**:
   - `init(isSessionActive: @escaping @Sendable () -> Bool = { false })` — injected guard for AudioCoordinator conflict (REQ-VCP-NF-14)
   - `nonisolated let levelStream: AsyncStream<Float>` + private continuation — level updates at ≥ 10 Hz (REQ-VCP-04, REQ-VCP-NF-03)
   - **`startRecording() async throws`**:
     1. Guard `!isSessionActive()` → throw `.sessionConflict`
     2. `requestMicrophonePermission()` → throw `.permissionDenied` if denied
     3. Reset `capturedSamples = []`
     4. Create `AVAudioEngine`, configure tap (see step 3 below), `engine.start()`
   - **`stopRecording() async throws -> RecordingResult`**:
     1. `engine.stop(); inputNode.removeTap(onBus: 0); engine = nil`
     2. `computeQuality(samples:)` → `VoiceQualityMetrics`
     3. Return `RecordingResult`

3. **Audio tap + SRC**:
   - Get `inputNode.outputFormat(forBus: 0)` — this is the device's native format
   - If native rate == 24000: tap directly, no converter
   - If native rate != 24000 (typical: 44100 or 48000):
     - Create `AVAudioConverter(from: nativeFormat, to: targetFormat24kHz)`
     - In tap block: `resample(buffer, converter:, targetFormat:)` → then `extractMono()` → `appendSamples()`
   - Tap closure is `@Sendable` (audio thread) — use `Task { await self.appendSamples(mono) }` to hop back to actor
   - The `resample()` and `extractMono()` and `computeRMS()` helpers are `private static` (nonisolated, safe on audio thread)
   - Based on OQ-1 resolution: if tapping at non-native rate is supported, skip the converter

4. **Quality computation** — `private func computeQuality(samples:) -> VoiceQualityMetrics`:
   - **Peak RMS**: `vDSP_measqv()` → `10 * log10f(rms)` dBFS (matches `EnergyVADService` pattern)
   - **Clipping**: count samples where `abs(sample) >= 0.98`; if `count / total > 0.001` → `hasClipping = true`
   - **Voiced duration**: chunk into 10 ms windows (240 samples at 24 kHz); count chunks with RMS ≥ −40 dBFS threshold (0.01 linear)
   - **Grade logic**:
     - `.poor`: peakRms < −30 OR hasClipping OR voicedDuration < 8 s
     - `.fair`: peakRms < −20 OR voicedDuration < 20 s (and not `.poor`)
     - `.good`: otherwise

5. **Permission request**: `AVCaptureDevice.requestAccess(for: .audio)` bridged with `withCheckedContinuation` (same pattern as `SFSpeechRecognizer.requestAuthorization` in F2.2)

### Tests

```swift
// TranslateCallTests/VoiceProfileRecorderTests.swift
@Suite @MainActor struct VoiceProfileRecorderTests {

    // Quality computation is the testable core — no real audio hardware needed.
    // We test via a helper that exposes computeQuality or by creating synthetic RecordingResults.

    @Test func qualityGoodForStrongSignal() {
        // Simulate: loud, clean, 25s of voiced content at 24 kHz
        let sampleCount = 25 * 24000
        let samples = (0..<sampleCount).map { _ in Float.random(in: -0.5...0.5) }
        let metrics = VoiceProfileRecorder.computeQualityStatic(samples: samples, sampleRate: 24000)
        #expect(metrics.grade == .good)
        #expect(!metrics.hasClipping)
        #expect(metrics.voicedDurationSeconds >= 20)
    }

    @Test func qualityFairForLowLevel() {
        // Simulate: quiet signal (−25 dBFS ≈ amplitude ±0.056)
        let sampleCount = 25 * 24000
        let samples = (0..<sampleCount).map { _ in Float.random(in: -0.056...0.056) }
        let metrics = VoiceProfileRecorder.computeQualityStatic(samples: samples, sampleRate: 24000)
        #expect(metrics.grade == .fair || metrics.grade == .poor)
        #expect(metrics.peakRmsDbfs < -20)
    }

    @Test func qualityPoorForClipping() {
        // Simulate: 1% of samples are clipped (≥ 0.98)
        var samples = (0..<24000).map { _ in Float.random(in: -0.3...0.3) }
        for i in stride(from: 0, to: 240, by: 1) { samples[i] = 0.99 } // 1% > 0.1% threshold
        let metrics = VoiceProfileRecorder.computeQualityStatic(samples: samples, sampleRate: 24000)
        #expect(metrics.hasClipping)
        #expect(metrics.grade == .poor)
    }

    @Test func qualityPoorForShortVoiced() {
        // 3 seconds of speech + 27 seconds of silence (near-zero amplitude)
        let speechSamples = (0..<(3 * 24000)).map { _ in Float.random(in: -0.4...0.4) }
        let silenceSamples = [Float](repeating: 0.0001, count: 27 * 24000)
        let samples = speechSamples + silenceSamples
        let metrics = VoiceProfileRecorder.computeQualityStatic(samples: samples, sampleRate: 24000)
        #expect(metrics.voicedDurationSeconds < 8)
        #expect(metrics.grade == .poor)
    }

    @Test func sessionConflictBlocks() async throws {
        let recorder = VoiceProfileRecorder(isSessionActive: { true })
        do {
            try await recorder.startRecording()
            Issue.record("Expected sessionConflict error")
        } catch is VoiceProfileRecorderError {
            // Expected: .sessionConflict
        }
    }

    @Test func emptySamplesReturnPoorGrade() {
        let metrics = VoiceProfileRecorder.computeQualityStatic(samples: [], sampleRate: 24000)
        #expect(metrics.grade == .poor)
        #expect(metrics.peakRmsDbfs <= -60)
    }
}
```

**Implementation note**: To make quality computation testable without audio hardware, expose it as `static func computeQualityStatic(samples:sampleRate:) -> VoiceQualityMetrics` (internal access). The instance method `computeQuality()` delegates to this static method. This avoids needing to mock `AVAudioEngine`.

**Acceptance**: 6 tests pass. No real audio hardware required.

---

## T4 — `VoiceProfileManager` + Tests

**Covers**: REQ-VCP-01, REQ-VCP-05 through REQ-VCP-11, REQ-VCP-18 through REQ-VCP-31

**Files to create**:
- `Core/VoiceCloning/VoiceProfileManager.swift` (NEW)
- `TranslateCallTests/VoiceProfileManagerTests.swift` (NEW)

### Steps

1. **`RecordingState` enum**:
   ```swift
   enum RecordingState: Sendable {
       case idle
       case recording(elapsedSeconds: Float)
       case processing
       case reviewing(RecordingResult)
       case saving
       case error(String)
   }
   ```
   - Note: `RecordingResult` must be `Sendable` (it already is — `[Float]` + `VoiceQualityMetrics`).
   - `RecordingState` cannot conform to `Equatable` directly (`.reviewing` holds a struct). Add an `isIdle`, `isRecording`, `isReviewing` etc. computed helpers for UI bindings.

2. **`VoiceProfileManager`** — `@MainActor final class ObservableObject`:
   - `@Published private(set) var profiles: [VoiceProfileHeader]`
   - `@Published private(set) var recordingState: RecordingState`
   - `@Published var activeProfileId: UUID?`
   - `var activeProfile: VoiceProfileHeader? { profiles.first { $0.id == activeProfileId } }`
   - Dependencies: `store: any VoiceProfileStoring`, `recorder: VoiceProfileRecorder`, `defaults: UserDefaults`
   - `init(store:recorder:defaults:)` — load active profile UUID from `defaults["tlk.voiceCloning.activeProfileId"]`; `Task { await loadProfiles() }`

3. **Recording flow**:
   - `func startRecording() async` — set state `.recording(0)`; start elapsed timer; call `recorder.startRecording()`; on error → `.error(msg)`
   - `func stopRecording() async` — stop timer; set `.processing`; call `recorder.stopRecording()`; set `.reviewing(result)` or `.error`
   - Elapsed timer: `Task` that increments every 100 ms; auto-stops at 30 s (REQ-VCP-05)

4. **Save flow**:
   - `func saveProfile(name:transcript:result:) async throws`:
     1. Guard transcript non-empty → throw `VoiceProfileValidationError.emptyTranscript`
     2. Build `VoiceProfileHeader` + `VoiceProfile`
     3. `try await store.save(profile:)`
     4. `await loadProfiles()`
     5. Set state `.idle`

5. **Management**:
   - `func delete(id:) async throws` — delegate to store; if active, reset `activeProfileId`
   - `func rename(id:newName:) async throws` — delegate to store
   - `func setActiveProfile(_ id: UUID?)` — persist to `UserDefaults`
   - `func discardAndReRecord()` — reset to `.idle`

6. **Profile loading**:
   - `func loadProfiles() async` — `store.enumerateHeaders()` sorted by `createdAt` descending
   - Validate active profile UUID still exists; if not, reset (REQ-VCP-30)

### Tests

```swift
// TranslateCallTests/VoiceProfileManagerTests.swift
@Suite @MainActor struct VoiceProfileManagerTests {

    func makeManager(
        suite: String = UUID().uuidString,
        mockStore: MockVoiceProfileStore = MockVoiceProfileStore()
    ) -> (VoiceProfileManager, MockVoiceProfileStore) {
        let defaults = UserDefaults(suiteName: suite)!
        let recorder = VoiceProfileRecorder(isSessionActive: { false })
        let manager = VoiceProfileManager(store: mockStore, recorder: recorder, defaults: defaults)
        return (manager, mockStore)
    }

    @Test func activeProfilePersistedAndRestored() async throws {
        let suite = UUID().uuidString
        let mockStore = MockVoiceProfileStore()
        let profile = makeTestProfile()
        await mockStore.forceStore(profile)
        let (manager1, _) = makeManager(suite: suite, mockStore: mockStore)
        // Wait for initial loadProfiles
        try await Task.sleep(for: .milliseconds(100))
        manager1.setActiveProfile(profile.header.id)
        // Simulate relaunch
        let (manager2, _) = makeManager(suite: suite, mockStore: mockStore)
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager2.activeProfileId == profile.header.id)
    }

    @Test func activeProfileResetWhenFileMissing() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let missingId = UUID()
        defaults.set(missingId.uuidString, forKey: "tlk.voiceCloning.activeProfileId")
        let mockStore = MockVoiceProfileStore()
        let recorder = VoiceProfileRecorder(isSessionActive: { false })
        let manager = VoiceProfileManager(store: mockStore, recorder: recorder, defaults: defaults)
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.activeProfileId == nil)
    }

    @Test func deleteResetsActiveProfile() async throws {
        let mockStore = MockVoiceProfileStore()
        let profile = makeTestProfile()
        await mockStore.forceStore(profile)
        let (manager, _) = makeManager(mockStore: mockStore)
        try await Task.sleep(for: .milliseconds(100))
        manager.setActiveProfile(profile.header.id)
        try await manager.delete(id: profile.header.id)
        #expect(manager.activeProfileId == nil)
    }

    @Test func saveRequiresTranscript() async throws {
        let (manager, _) = makeManager()
        let result = RecordingResult(
            samples: [0.1, 0.2, 0.3],
            durationSeconds: 1.0,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -18, hasClipping: false,
                voicedDurationSeconds: 1.0, grade: .good
            )
        )
        do {
            try await manager.saveProfile(name: "Test", transcript: "", result: result)
            Issue.record("Expected emptyTranscript error")
        } catch is VoiceProfileValidationError {
            // Expected
        }
    }

    @Test func saveSucceedsWithValidTranscript() async throws {
        let mockStore = MockVoiceProfileStore()
        let (manager, _) = makeManager(mockStore: mockStore)
        let result = RecordingResult(
            samples: Array(repeating: 0.5, count: 24000),
            durationSeconds: 1.0,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -18, hasClipping: false,
                voicedDurationSeconds: 1.0, grade: .good
            )
        )
        try await manager.saveProfile(name: "My Voice", transcript: "Hello world", result: result)
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.profiles.count == 1)
        #expect(manager.profiles.first?.name == "My Voice")
    }

    @Test func saveFailureReportsError() async throws {
        let mockStore = MockVoiceProfileStore()
        await mockStore.setShouldThrowOnSave(VoiceProfileError.encryptionFailed)
        let (manager, _) = makeManager(mockStore: mockStore)
        let result = RecordingResult(
            samples: [0.1], durationSeconds: 0.01,
            quality: VoiceQualityMetrics(peakRmsDbfs: -18, hasClipping: false,
                                         voicedDurationSeconds: 0.01, grade: .good)
        )
        do {
            try await manager.saveProfile(name: "Test", transcript: "Hi", result: result)
            Issue.record("Expected save to throw")
        } catch is VoiceProfileError {
            // Expected
        }
    }

    // MARK: - Helper

    private func makeTestProfile() -> VoiceProfile {
        let header = VoiceProfileHeader(
            id: UUID(), name: "Test", createdAt: .now,
            durationSeconds: 1.0, sampleRate: 24000, sampleCount: 24000,
            quality: VoiceQualityMetrics(peakRmsDbfs: -18, hasClipping: false,
                                         voicedDurationSeconds: 1.0, grade: .good),
            formatVersion: 1
        )
        return VoiceProfile(header: header, samples: Array(repeating: 0.5, count: 24000),
                            transcript: "Hello")
    }
}
```

`MockVoiceProfileStore` needs a `forceStore(_:)` helper to pre-populate and a `setShouldThrowOnSave(_:)` method.

**Acceptance**: 6 tests pass. State machine transitions verified. Active profile persistence works.

---

## T5 — Recording UI: `VoiceRecordingView` + `VoiceTranscriptView`

**Covers**: REQ-VCP-04 (waveform + countdown), REQ-VCP-06 (manual stop), REQ-VCP-08 through REQ-VCP-11 (transcript entry + review)

**Files to create**:
- `Features/VoiceCloning/VoiceRecordingView.swift` (NEW)
- `Features/VoiceCloning/VoiceTranscriptView.swift` (NEW)

### Steps

1. **`VoiceRecordingView`**:
   - `@EnvironmentObject var profileManager: VoiceProfileManager`
   - Layout (from design.md § 4.1):
     ```
     Title: "Record Your Voice"
     Instruction text
     Progress bar: elapsed / 30 s (derived from recordingState.elapsedSeconds)
     WaveformView (subscribes to recorder.levelStream via Task)
     Quality badge (green/amber/red based on live RMS)
     [Stop Recording] button → calls profileManager.stopRecording()
     ```
   - `WaveformView`: a simple bar-chart scrolling 1-second window. Use `@State var levels: [Float]` updated by a `Task { for await level in recorder.levelStream { … } }`.
   - Alternatively, if `recordingState` carries level data, bind directly.

2. **`VoiceTranscriptView`**:
   - `@EnvironmentObject var profileManager: VoiceProfileManager`
   - `let recordingResult: RecordingResult` (passed from `.reviewing(result)` state)
   - Layout (from design.md § 4.2):
     ```
     Title: "Review & Save"
     Profile name text field
     Transcript TextEditor (required, max 2000 chars — REQ-VCP-10)
     Character count label
     Quality row: duration, grade badge, peak RMS
     Warning banners for .fair / .poor grades (REQ-VCP-13, REQ-VCP-14, REQ-VCP-15)
     [Re-record] button → profileManager.discardAndReRecord()
     [Save Profile] button (disabled when transcript empty) → profileManager.saveProfile(…)
     ```
   - Quality warnings:
     - `.poor` + `voicedDuration < 8`: "Insufficient speech detected" — save blocked (REQ-VCP-15); only "Re-record" available
     - `.poor` + `hasClipping`: "Recording contains clipping" — offer re-record
     - `.poor` + low RMS: "Recording level too low" — offer re-record
     - `.fair`: amber banner with suggestion, save allowed

3. **Character count enforcement** (REQ-VCP-10): Use `.onChange(of: transcript)` to truncate to 2000 chars.

### Acceptance (manual)

- Recording view shows live level meter updating at ≥ 10 Hz
- Countdown timer progresses from 0 to 30 seconds
- Stop button ends recording and transitions to review step
- Transcript view shows quality metrics and badges
- Save is blocked when transcript is empty
- Save is blocked when grade is `.poor` with `voicedDuration < 8`
- Character count updates and truncates at 2000

---

## T6 — Profile Management UI: `VoiceProfileListView` + `VoiceProfileDetailView`

**Covers**: REQ-VCP-22 through REQ-VCP-28

**Files to create**:
- `Features/VoiceCloning/VoiceProfileListView.swift` (NEW)
- `Features/VoiceCloning/VoiceProfileDetailView.swift` (NEW)

### Steps

1. **`VoiceProfileListView`**:
   - `@EnvironmentObject var profileManager: VoiceProfileManager`
   - `@State private var showRecording: Bool = false`
   - Layout (from design.md § 4.3):
     ```
     NavigationView or VStack with list:
       ForEach(profileManager.profiles) { header in
         Row: checkmark (if active) + name + date + duration + grade badge
         .swipeActions { Delete with confirmation alert (REQ-VCP-26) }
         Tap → NavigationLink to VoiceProfileDetailView
       }
       .overlay {
         if profileManager.profiles.isEmpty {
           Empty state: SF Symbol waveform.badge.mic + "Record your first profile"
         }
       }
       Toolbar: [+ Add Profile] button → showRecording = true
     ```
   - `.sheet(isPresented: $showRecording)` → recording flow view (state machine switch):
     ```swift
     switch profileManager.recordingState {
     case .idle: Button("Start Recording") { Task { await profileManager.startRecording() } }
     case .recording: VoiceRecordingView()
     case .processing: ProgressView("Analyzing…")
     case .reviewing(let result): VoiceTranscriptView(result: result)
     case .saving: ProgressView("Saving…")
     case .error(let msg): ErrorView(message: msg)
     }
     ```

2. **`VoiceProfileDetailView`**:
   - `let header: VoiceProfileHeader`
   - `@EnvironmentObject var profileManager: VoiceProfileManager`
   - Layout (from design.md § 4.4):
     ```
     Editable name field (inline editing → profileManager.rename on commit)
     Created: [date formatted]
     Duration: [X.X s]
     Quality grid: Peak RMS, Clipping, Voiced duration, Grade
     Transcript excerpt (first 100 chars, non-editable)
     [Set as Active] / [Remove as Active] toggle button
     [Delete Profile] destructive button with confirmation alert
     ```

3. **Delete confirmation** (REQ-VCP-26): `@State private var showDeleteConfirmation = false` + `.confirmationDialog`.

### Acceptance (manual)

- Profile list shows all saved profiles sorted by date
- Empty state appears when no profiles exist
- Swipe-to-delete shows confirmation
- Detail view shows all quality metrics
- Active profile has checkmark; tapping "Set as Active" updates the badge
- Rename persists after exiting detail view

---

## T7 — Integration: `AudioViewModel` + `TTSEngineSelector` + `ContentView`

**Covers**: REQ-VCP-29 through REQ-VCP-31 (active profile wiring), integration into existing UI

**Files to modify**:
- `Features/Main/AudioViewModel.swift` (MODIFY)
- `Core/TTS/TTSEngineSelector.swift` (MODIFY)
- `Features/ContentView.swift` (MODIFY)

### Steps

1. **`AudioViewModel`**:
   - Add `let voiceProfileManager: VoiceProfileManager` property
   - In convenience `init`: create `VoiceProfileManager()` with a `VoiceProfileRecorder(isSessionActive:)` that checks `coordinator.isRunning`
   - Publish as `@Published` or inject as `@EnvironmentObject` into `ContentView`

2. **`TTSEngineSelector`**:
   - Add `@Published private(set) var activeVoiceProfile: VoiceProfileHeader?`
   - Add `var voiceCloningAvailable: Bool { activeVoiceProfile != nil }`
   - In `AudioViewModel` or via Combine: when `voiceProfileManager.activeProfile` changes, update `ttsEngineSelector.activeVoiceProfile`
   - No synthesis changes in F7.1 — this wiring only gates UI in F7.3

3. **`ContentView`**:
   - Add "Voice Profiles" button/row in the settings area that presents `VoiceProfileListView` as a sheet
   - Inject `voiceProfileManager` as `@EnvironmentObject` into the sheet
   - Show active profile name badge if one is selected (e.g. "Voice: My Voice ✓")

4. **`AudioViewModel.preview()`**: pass a default `VoiceProfileManager()` to avoid breaking previews.

### Tests

- Verify existing `AudioCoordinatorTests` and `AudioViewModelTests` pass without regression.
- If `AudioViewModel` has tests that call `init`, update them to include `voiceProfileManager` parameter.

### Acceptance

- "Voice Profiles" button visible in main UI
- Tapping it opens the profile list sheet
- Active profile name appears as a badge
- All existing tests pass (0 regressions)

---

## T8 — Integration Tests + Cleanup

**Covers**: AC-01 through AC-12

### Steps

1. **Automated AC checks** (already covered by T2–T4 tests):
   | AC | Covered By |
   |----|-----------|
   | AC-01 | `VoiceProfileStoreTests.saveAndLoadRoundTrip` |
   | AC-02 | `VoiceProfileRecorderTests.qualityPoor*` tests |
   | AC-03 | Manual test (save → quit → relaunch → list) |
   | AC-04 | `VoiceProfileManagerTests.activeProfilePersistedAndRestored` |
   | AC-05 | `VoiceProfileStoreTests.deleteRemovesFile` + `VoiceProfileManagerTests.deleteResetsActiveProfile` |
   | AC-06 | `VoiceProfileStoreTests.corruptFileSkipped` |
   | AC-07 | `VoiceProfileManagerTests.saveFailureReportsError` |
   | AC-08 | `VoiceProfileStoreTests.outputFormatIs24kHzFloat32` |
   | AC-09 | `VoiceProfileManagerTests.saveRequiresTranscript` |
   | AC-10 | `VoiceProfileManagerTests.activeProfileResetWhenFileMissing` |
   | AC-11 | `VoiceProfileRecorderTests.sessionConflictBlocks` |
   | AC-12 | Manual test (Privacy dashboard) |

2. **SwiftLint cleanup**: Run `swiftlint` on all new files in `Core/VoiceCloning/` and `Features/VoiceCloning/`. Fix violations:
   - `nonisolated(unsafe)` pattern comments present on all relevant static lets
   - Line length ≤ 120
   - No nested types beyond 1 level (SwiftLint `nesting` rule)
   - Error enum `errorDescription` uses `switch` exhaustively

3. **Full test suite regression**: Run `xcodebuild test` for the main test target:
   ```bash
   xcodebuild test \
     -project TranslateCall.xcodeproj \
     -scheme TranslateCall \
     -destination 'platform=macOS' \
     -only-testing:TranslateCallTests \
     2>&1 | xcpretty
   ```
   Confirm 0 regressions on all prior tests. Known flaky: `sileroVADMaxDuration` (pre-existing).

4. **Manual testing checklist**:
   - [ ] Grant mic permission → recording starts
   - [ ] Deny mic permission → error shown with Settings link
   - [ ] Record 30 s → auto-stops
   - [ ] Record 5 s → manual stop → short duration warning
   - [ ] Quiet recording → low level warning
   - [ ] Enter transcript → save succeeds → profile in list
   - [ ] Empty transcript → save blocked
   - [ ] Re-record button → returns to recording step
   - [ ] Profile list shows all profiles sorted by date
   - [ ] Delete profile → confirmation → removed from list
   - [ ] Rename profile → name updated
   - [ ] Set active → checkmark appears
   - [ ] Delete active → checkmark removed, no crash
   - [ ] Quit + relaunch → profiles and active selection preserved
   - [ ] Start recording during active call → session conflict error
   - [ ] Corrupt `.vpf` manually → other profiles still load

### Acceptance

- All unit tests pass (T1–T4: ≥ 23 tests).
- SwiftLint: 0 errors, 0 warnings on new files.
- Existing test suite: 0 regressions.
- Manual checklist: all items checked.

---

## Summary Table

| Task | New Files | Modified Files | New Tests | Req Coverage |
|------|-----------|---------------|-----------|-------------|
| T0 | — | — | 0 | OQ-1–5 |
| T1 | `VoiceProfile.swift` | — | 4 | VCP-12,16,17 |
| T2 | `VoiceProfileStore.swift`, `MockVoiceProfileStore.swift` | — | 7 | VCP-17–21,25,26,NF-05–09,12,13 |
| T3 | `VoiceProfileRecorder.swift` | — | 6 | VCP-01–07,12–16,NF-03,10,11,14 |
| T4 | `VoiceProfileManager.swift` | — | 6 | VCP-01,05–11,18–31 |
| T5 | `VoiceRecordingView.swift`, `VoiceTranscriptView.swift` | — | 0 (manual) | VCP-04,06,08–11 |
| T6 | `VoiceProfileListView.swift`, `VoiceProfileDetailView.swift` | — | 0 (manual) | VCP-22–28 |
| T7 | — | `AudioViewModel.swift`, `TTSEngineSelector.swift`, `ContentView.swift` | 0 (+existing) | VCP-29–31 |
| T8 | — | — | 0 (AC checks) | AC-01–12 |
| **Total** | **9 new** | **3 modified** | **≥ 23** | **All 31 REQs + 14 NF-REQs** |
