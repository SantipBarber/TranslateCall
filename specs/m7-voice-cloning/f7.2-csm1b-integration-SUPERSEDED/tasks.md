# F7.2 — CSM-1B Voice Cloning Integration: Task Breakdown

> **Feature**: F7.2 — CSM-1B Voice Cloning Integration
> **Milestone**: M7 — Voice Cloning
> **Status**: DRAFT
> **Depends on**: design.md (approved)
> **Date**: 2026-03-13

---

## Overview

10 tasks in dependency order. T0 is a spike (verify csm-mlx setup + benchmark on hardware). Each subsequent task follows a TDD cycle (RED → GREEN → REFACTOR).

```
T0 (spike) ──▶ T1 (config + protocol) ──▶ T2 (Python server + setup)
                                                    │
                                              T3 (HTTP client + tests)
                                                    │
                                              T4 (process manager)
                                                    │
                                              T5 (model manager + tests)
                                                    │
                                              T6 (speech service + tests)
                                                    │
                                              T7 (TTSEngine + selector + tests)
                                                    │
                                              T8 (UI wiring)
                                                    │
                                              T9 (integration tests + cleanup)
```

---

## T0 — Spike: Verify csm-mlx Setup + Benchmark

**Goal**: Confirm the Python microservice approach works end-to-end on the dev machine before writing production code.

### Steps

1. **Install csm-mlx in a test venv**:
   ```bash
   python3 -m venv /tmp/csm-test-venv
   /tmp/csm-test-venv/bin/pip install "csm-mlx @ git+https://github.com/senstella/csm-mlx" flask
   ```
   Document: Python version, install time, disk usage.

2. **Run a standalone test**:
   ```python
   from csm_mlx import CSM, csm_1b, generate, Segment
   from huggingface_hub import hf_hub_download
   from mlx import nn
   import mlx.core as mx
   import numpy as np
   import time

   csm = CSM(csm_1b())
   weight = hf_hub_download(repo_id="senstella/csm-1b-mlx", filename="ckpt.safetensors")
   csm.load_weights(weight)
   nn.quantize(csm, bits=8)

   # Generate without context (baseline)
   start = time.time()
   audio = generate(csm, text="Hello, how are you today?", speaker=0, context=[], max_audio_length_ms=5000)
   print(f"No-context inference: {time.time()-start:.1f}s, {len(np.asarray(audio))} samples")

   # Generate with context (voice cloning)
   # Use a 10s reference audio file
   ref_audio = mx.array(np.random.randn(240000).astype(np.float32))  # synthetic 10s
   context = [Segment(speaker=0, text="This is a test reference audio.", audio=ref_audio)]
   start = time.time()
   audio = generate(csm, text="Hello, how are you today?", speaker=0, context=context, max_audio_length_ms=5000)
   print(f"With-context inference: {time.time()-start:.1f}s, {len(np.asarray(audio))} samples")
   ```
   Record: inference time, output sample count, memory usage (Activity Monitor).

3. **Test the Flask server** — write a minimal `csm_server.py` (from design.md § 2.8), start it, and call `/synthesize` with `curl`:
   ```bash
   curl -X POST http://127.0.0.1:21935/synthesize \
     -H "Content-Type: application/json" \
     -d '{"text":"Hello","context_audio_b64":"...","context_transcript":"Test","max_audio_length_ms":5000}'
   ```
   Verify: JSON response with `audio_b64`, `sample_rate`, `inference_ms`.

4. **Benchmark summary**: Fill in the table:
   | Metric | Value |
   |--------|-------|
   | Python version | (e.g., 3.12.x) |
   | csm-mlx install time | |
   | Model download time | |
   | Disk usage (venv + model) | |
   | No-context inference (5-word sentence) | |
   | With-context inference (5-word + 10s ref) | |
   | Peak memory (Activity Monitor) | |
   | Server startup time (until /health OK) | |

5. **Decide**: If inference > 6 s or memory > 12 GB, consider 4-bit quantization or flag as risk.

### Acceptance

- csm-mlx installs and runs on the dev machine.
- Flask server starts and responds to `/synthesize`.
- Benchmark table filled.
- Decision on quantization bits confirmed (8 or 4).

---

## T1 — Data Model: CSMConfiguration + CSMError + CSMInferring

**Covers**: REQ-CSM-NF-11, REQ-CSM-NF-12

**Files to create**:
- `Core/VoiceCloning/CSMConfiguration.swift` (NEW)
- `Core/VoiceCloning/CSMInferring.swift` (NEW)

### Steps

1. **`CSMConfiguration` struct**:
   ```swift
   struct CSMConfiguration: Sendable {
       let port: UInt16
       let host: String
       let maxAudioLengthMs: Int
       let temperature: Float
       let topK: Int
       let quantizeBits: Int

       nonisolated(unsafe) static let `default` = CSMConfiguration(
           port: 21935,
           host: "127.0.0.1",
           maxAudioLengthMs: 10_000,
           temperature: 0.8,
           topK: 50,
           quantizeBits: 8
       )

       var baseURL: URL { URL(string: "http://\(host):\(port)")! }
       static let pythonEnvKey = "tlk.csm.pythonEnvPath"
       static let voiceCloningEnabledKey = "tlk.voiceCloning.enabled"
   }
   ```

2. **`CSMError` enum** — `LocalizedError`:
   ```swift
   enum CSMError: LocalizedError {
       case serverNotRunning
       case inferenceTimeout
       case invalidResponse
       case downloadFailed(String)
       case pythonNotFound
       case environmentSetupFailed(String)

       var errorDescription: String? { /* switch — all cases */ }
   }
   ```

3. **`CSMInferring` protocol**:
   ```swift
   protocol CSMInferring: Actor {
       func synthesize(
           text: String,
           contextAudio: [Float],
           contextTranscript: String
       ) async throws -> [Float]
   }
   ```

### Tests

```swift
// TranslateCallTests/CSMConfigurationTests.swift
@Suite @MainActor struct CSMConfigurationTests {

    @Test func defaultValues() {
        let config = CSMConfiguration.default
        #expect(config.port == 21935)
        #expect(config.host == "127.0.0.1")
        #expect(config.maxAudioLengthMs == 10_000)
        #expect(config.temperature == 0.8)
        #expect(config.topK == 50)
        #expect(config.quantizeBits == 8)
    }

    @Test func baseURLFormatted() {
        let config = CSMConfiguration.default
        #expect(config.baseURL.absoluteString == "http://127.0.0.1:21935")
    }

    @Test func errorDescriptionsNonEmpty() {
        let errors: [CSMError] = [
            .serverNotRunning,
            .inferenceTimeout,
            .invalidResponse,
            .downloadFailed("test"),
            .pythonNotFound,
            .environmentSetupFailed("test"),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}
```

**Acceptance**: 3 tests pass. All types compile with `Sendable` conformance.

---

## T2 — Python Server + Setup Script

**Covers**: REQ-CSM-01, REQ-CSM-02, REQ-CSM-NF-05, REQ-CSM-NF-07

**Files to create**:
- `TranslateCall/Resources/CSM/csm_server.py` (NEW)
- `TranslateCall/Resources/CSM/setup_csm_env.sh` (NEW)

### Steps

1. **`csm_server.py`** — Flask server (from design.md § 2.8):
   - `GET /health` → `{"status": "ok", "model_loaded": true/false}`
   - `POST /synthesize` → accepts JSON with `text`, `context_audio_b64`, `context_transcript`, `max_audio_length_ms`, `temperature`, `top_k`; returns JSON with `audio_b64`, `sample_rate`, `duration_ms`, `inference_ms`
   - `POST /unload` → unloads model, clears GPU cache
   - CLI args: `--port`, `--host`, `--quantize`
   - `host` default: `127.0.0.1` (localhost only — REQ-CSM-NF-07)
   - Error handling: wrap `generate()` in try/except; return HTTP 500 with error JSON on failure
   - Threaded=False (single-threaded — CSM is not thread-safe)

2. **`setup_csm_env.sh`** (from design.md § 2.9):
   - Creates venv at `<install_dir>/venv/`
   - Installs `csm-mlx` + `flask`
   - Pinned to a specific commit (from T0 spike results)
   - `set -euo pipefail` for error handling
   - Reports Python version and install status

3. **Add both files to the Xcode project** — they should be in `Resources/CSM/` and included in the app bundle via `PBXFileSystemSynchronizedRootGroup`.

### Tests

No automated tests for Python code in the Swift test target. Verified manually in T0.

**Acceptance**:
- `csm_server.py` starts, responds to `/health`, processes `/synthesize`, handles errors gracefully.
- `setup_csm_env.sh` creates a working venv with csm-mlx.
- Both files are in the Xcode project bundle.

---

## T3 — `CSMClient` — HTTP Inference Client + Tests

**Covers**: REQ-CSM-09, REQ-CSM-11, REQ-CSM-15, REQ-CSM-NF-05

**Files to create**:
- `Core/VoiceCloning/CSMClient.swift` (NEW)
- `TranslateCallTests/CSMClientTests.swift` (NEW)

### Steps

1. **`CSMClient` actor** conforming to `CSMInferring`:
   ```swift
   actor CSMClient: CSMInferring {
       private let config: CSMConfiguration
       private let session: URLSession

       init(config: CSMConfiguration = .default) {
           self.config = config
           let sessionConfig = URLSessionConfiguration.default
           sessionConfig.timeoutIntervalForRequest = 15
           self.session = URLSession(configuration: sessionConfig)
       }

       func synthesize(
           text: String,
           contextAudio: [Float],
           contextTranscript: String
       ) async throws -> [Float] {
           let url = config.baseURL.appendingPathComponent("synthesize")

           // Encode context audio as base64 Float32 LE
           let audioData = contextAudio.withUnsafeBufferPointer { ptr in
               Data(buffer: ptr)
           }
           let audioB64 = audioData.base64EncodedString()

           // Build request body
           let body: [String: Any] = [
               "text": text,
               "context_audio_b64": audioB64,
               "context_transcript": contextTranscript,
               "max_audio_length_ms": config.maxAudioLengthMs,
               "temperature": config.temperature,
               "top_k": config.topK,
           ]

           var request = URLRequest(url: url)
           request.httpMethod = "POST"
           request.setValue("application/json", forHTTPHeaderField: "Content-Type")
           request.httpBody = try JSONSerialization.data(withJSONObject: body)

           let (data, response) = try await session.data(for: request)
           guard let httpResponse = response as? HTTPURLResponse,
                 httpResponse.statusCode == 200 else {
               throw CSMError.serverNotRunning
           }

           // Parse response
           guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                 let audioB64Response = json["audio_b64"] as? String,
                 let audioBytes = Data(base64Encoded: audioB64Response) else {
               throw CSMError.invalidResponse
           }

           // Decode Float32 LE array
           let floatCount = audioBytes.count / MemoryLayout<Float>.size
           let samples = audioBytes.withUnsafeBytes { ptr in
               Array(ptr.bindMemory(to: Float.self).prefix(floatCount))
           }
           return samples
       }

       func healthCheck() async -> Bool {
           let url = config.baseURL.appendingPathComponent("health")
           guard let (data, response) = try? await session.data(from: url),
                 let httpResponse = response as? HTTPURLResponse,
                 httpResponse.statusCode == 200,
                 let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                 let modelLoaded = json["model_loaded"] as? Bool else {
               return false
           }
           return modelLoaded
       }

       func requestUnload() async {
           let url = config.baseURL.appendingPathComponent("unload")
           var request = URLRequest(url: url)
           request.httpMethod = "POST"
           _ = try? await session.data(for: request)
       }
   }
   ```

2. **Audio encoding helper** — extracted as a static method for testability:
   ```swift
   static func encodeAudioBase64(_ samples: [Float]) -> String {
       samples.withUnsafeBufferPointer { ptr in
           Data(buffer: ptr).base64EncodedString()
       }
   }

   static func decodeAudioBase64(_ base64: String) throws -> [Float] {
       guard let data = Data(base64Encoded: base64) else {
           throw CSMError.invalidResponse
       }
       let count = data.count / MemoryLayout<Float>.size
       return data.withUnsafeBytes { ptr in
           Array(ptr.bindMemory(to: Float.self).prefix(count))
       }
   }
   ```

### Tests

```swift
// TranslateCallTests/CSMClientTests.swift
@Suite @MainActor struct CSMClientTests {

    @Test func encodeDecodeAudioRoundTrip() throws {
        let original: [Float] = [0.1, -0.5, 0.99, 0.0, -0.001]
        let encoded = CSMClient.encodeAudioBase64(original)
        let decoded = try CSMClient.decodeAudioBase64(encoded)
        #expect(decoded.count == original.count)
        for (orig, dec) in zip(original, decoded) {
            #expect(abs(orig - dec) < 1e-6)
        }
    }

    @Test func decodeInvalidBase64Throws() {
        do {
            _ = try CSMClient.decodeAudioBase64("not-valid-base64!!!")
            Issue.record("Expected invalidResponse error")
        } catch is CSMError {
            // Expected
        } catch {
            Issue.record("Expected CSMError, got \(error)")
        }
    }

    @Test func emptyAudioEncodesEmpty() throws {
        let encoded = CSMClient.encodeAudioBase64([])
        let decoded = try CSMClient.decodeAudioBase64(encoded)
        #expect(decoded.isEmpty)
    }

    @Test func largeAudioRoundTrip() throws {
        // 30s at 24kHz = 720,000 samples
        let original = (0..<720_000).map { Float(sin(Double($0) / 100.0)) }
        let encoded = CSMClient.encodeAudioBase64(original)
        let decoded = try CSMClient.decodeAudioBase64(encoded)
        #expect(decoded.count == 720_000)
        #expect(abs(decoded[0] - original[0]) < 1e-6)
        #expect(abs(decoded[719_999] - original[719_999]) < 1e-6)
    }
}
```

**Acceptance**: 4 tests pass. Base64 audio encoding/decoding preserves Float32 precision.

---

## T4 — `CSMProcessManager` — Python Subprocess Lifecycle

**Covers**: REQ-CSM-04, REQ-CSM-07, REQ-CSM-NF-07, REQ-CSM-NF-10

**Files to create**:
- `Core/VoiceCloning/CSMProcessManager.swift` (NEW)

### Steps

1. **`CSMProcessManager` class** — `Sendable` (all mutable state accessed only from `CSMModelManager`'s actor context):

   ```swift
   final class CSMProcessManager: Sendable {
       nonisolated(unsafe) private var process: Process?
       nonisolated(unsafe) private var restartCount: Int = 0
       private let config: CSMConfiguration
       private let maxRestarts: Int = 3

       init(config: CSMConfiguration = .default)

       /// Start the Python subprocess.
       /// - Locates python3 in the venv at ~/Library/Application Support/TranslateCall/Models/CSM1B/venv/bin/python3
       /// - Falls back to system python3 if venv not present (pre-download phase)
       /// - Runs: python3 <bundle_path>/csm_server.py --port <port> --host <host> --quantize <bits>
       /// - Captures stdout/stderr via Pipe for logging
       /// - Waits for /health to return 200 (polls every 500ms, up to 30s)
       /// - Throws CSMError.serverNotRunning if health check fails after 30s
       func start() async throws

       /// Graceful shutdown: SIGTERM → wait 5s → SIGKILL if still running.
       func stop()

       /// Check if process is alive AND /health responds with model_loaded: true.
       func isHealthy() async -> Bool

       /// stop() + start(). Increments restartCount. Throws if > maxRestarts.
       func restart() async throws

       /// Reset restart counter (called when user explicitly re-enables cloning).
       func resetRestartCount()
   }
   ```

2. **Script path resolution**: The `csm_server.py` is bundled in the app. Use `Bundle.main.path(forResource: "csm_server", ofType: "py", inDirectory: "CSM")` or compute from the bundle's resource path.

3. **Process termination handler**:
   ```swift
   process.terminationHandler = { [weak self] proc in
       guard proc.terminationReason != .exit || proc.terminationStatus != 0 else { return }
       // Unexpected crash — attempt restart
       Task { try? await self?.restart() }
   }
   ```

4. **Health polling loop**:
   ```swift
   private func waitForHealth(timeout: Duration = .seconds(30)) async throws {
       let client = CSMClient(config: config)
       let deadline = ContinuousClock.now + timeout
       while ContinuousClock.now < deadline {
           if await client.healthCheck() { return }
           try await Task.sleep(for: .milliseconds(500))
       }
       throw CSMError.serverNotRunning
   }
   ```

### Tests

No direct unit tests for `CSMProcessManager` — it manages real OS processes. Tested via integration in T9. The health check logic is tested indirectly via `CSMClient.healthCheck()`.

**Acceptance**: Process starts, health check passes, SIGTERM stops it cleanly. Verified manually.

---

## T5 — `CSMModelManager` — State Machine + Tests

**Covers**: REQ-CSM-01 through REQ-CSM-08, REQ-CSM-NF-01, REQ-CSM-NF-12

**Files to create**:
- `Core/VoiceCloning/CSMModelManager.swift` (NEW)
- `TranslateCallTests/CSMModelManagerTests.swift` (NEW)

### Steps

1. **`CSMModelManager` actor** — mirrors `KokoroModelManager`:

   ```swift
   actor CSMModelManager {

       enum ModelState: Sendable, Equatable {
           case idle
           case downloading
           case loading
           case ready
           case failed(String)

           static func == (lhs: ModelState, rhs: ModelState) -> Bool {
               switch (lhs, rhs) {
               case (.idle, .idle), (.downloading, .downloading),
                    (.loading, .loading), (.ready, .ready):
                   return true
               case (.failed(let a), .failed(let b)):
                   return a == b
               default:
                   return false
               }
           }
       }

       static let shared = CSMModelManager()

       private(set) var state: ModelState = .idle
       private var loadTask: Task<Void, Error>?
       nonisolated let stateStream: AsyncStream<ModelState>
       private let stateContinuation: AsyncStream<ModelState>.Continuation

       private let config: CSMConfiguration
       private let processManager: CSMProcessManager
       private let client: any CSMInferring

       // Factory for test injection
       typealias ClientFactory = @Sendable (CSMConfiguration) -> any CSMInferring

       init(
           config: CSMConfiguration = .default,
           clientFactory: ClientFactory? = nil
       ) {
           self.config = config
           if let factory = clientFactory {
               self.client = factory(config)
           } else {
               self.client = CSMClient(config: config)
           }
           self.processManager = CSMProcessManager(config: config)
           var cont: AsyncStream<ModelState>.Continuation!
           stateStream = AsyncStream { cont = $0 }
           stateContinuation = cont
       }
   ```

2. **`ensureReady()`** — task coalescing:
   ```swift
   func ensureReady() async throws {
       switch state {
       case .ready:
           return
       case .loading, .downloading:
           guard let task = loadTask else { return try await startSetup() }
           return try await task.value
       case .idle, .failed:
           return try await startSetup()
       }
   }

   private func startSetup() async throws {
       let task = Task<Void, Error> {
           // 1. Download if needed
           if !isModelCached() {
               transition(to: .downloading)
               try await downloadEnvironment()
           }
           // 2. Start process
           transition(to: .loading)
           try await processManager.start()
           transition(to: .ready)
       }
       loadTask = task
       do {
           try await task.value
       } catch {
           transition(to: .failed(error.localizedDescription))
           throw error
       }
   }
   ```

3. **`getClient()`**:
   ```swift
   func getClient() throws -> any CSMInferring {
       guard case .ready = state else { throw CSMError.serverNotRunning }
       return client
   }
   ```

4. **`unload()`**:
   ```swift
   func unload() {
       loadTask?.cancel()
       loadTask = nil
       processManager.stop()
       transition(to: .idle)
   }
   ```

5. **`isModelCached()`**:
   ```swift
   nonisolated func isModelCached() -> Bool {
       let venvPath = Self.installDirectory.appendingPathComponent("venv/bin/python3").path
       return FileManager.default.fileExists(atPath: venvPath)
   }

   nonisolated static var installDirectory: URL {
       FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
           .appendingPathComponent("TranslateCall/Models/CSM1B")
   }
   ```

6. **`downloadEnvironment()`** — runs `setup_csm_env.sh` as a subprocess:
   ```swift
   private func downloadEnvironment() async throws {
       guard let scriptPath = Bundle.main.path(
           forResource: "setup_csm_env", ofType: "sh", inDirectory: "CSM"
       ) else {
           throw CSMError.downloadFailed("setup_csm_env.sh not found in bundle")
       }

       let process = Process()
       process.executableURL = URL(fileURLWithPath: "/bin/bash")
       process.arguments = [scriptPath, Self.installDirectory.path]

       let pipe = Pipe()
       process.standardOutput = pipe
       process.standardError = pipe

       try process.run()
       process.waitUntilExit()

       guard process.terminationStatus == 0 else {
           let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
           throw CSMError.environmentSetupFailed(output)
       }
   }
   ```

### Tests

```swift
// TranslateCallTests/CSMModelManagerTests.swift
@Suite @MainActor struct CSMModelManagerTests {

    func makeManager(
        mockClient: MockCSMInferrer = MockCSMInferrer()
    ) -> CSMModelManager {
        CSMModelManager(clientFactory: { _ in mockClient })
    }

    @Test func initialStateIsIdle() async {
        let manager = makeManager()
        let state = await manager.state
        #expect(state == .idle)
    }

    @Test func getClientThrowsWhenNotReady() async {
        let manager = makeManager()
        do {
            _ = try await manager.getClient()
            Issue.record("Expected serverNotRunning error")
        } catch is CSMError {
            // Expected
        } catch {
            Issue.record("Expected CSMError, got \(error)")
        }
    }

    @Test func unloadTransitionsToIdle() async {
        let manager = makeManager()
        await manager.unload()
        let state = await manager.state
        #expect(state == .idle)
    }

    @Test func stateStreamEmitsTransitions() async {
        let manager = makeManager()
        var states: [CSMModelManager.ModelState] = []

        let collectTask = Task {
            for await state in manager.stateStream {
                states.append(state)
                if states.count >= 1 { break }
            }
        }

        await manager.unload()  // emits .idle
        try? await Task.sleep(for: .milliseconds(100))
        collectTask.cancel()

        #expect(states.contains(.idle))
    }

    @Test func isModelCachedReturnsFalseForFreshInstall() async {
        let manager = makeManager()
        // Default install directory won't have a venv in test environment
        let cached = manager.isModelCached()
        #expect(!cached)
    }
}
```

**Acceptance**: 5 tests pass. State machine transitions verified. Task coalescing works.

---

## T6 — `CSMSpeechService` — SynthesisService Conformance + Tests

**Covers**: REQ-CSM-09 through REQ-CSM-15, REQ-CSM-24, REQ-CSM-25, REQ-CSM-26, REQ-CSM-NF-06

**Files to create**:
- `Core/VoiceCloning/CSMSpeechService.swift` (NEW)
- `TranslateCallTests/Mocks/MockCSMInferrer.swift` (NEW)
- `TranslateCallTests/CSMSpeechServiceTests.swift` (NEW)

### Steps

1. **`MockCSMInferrer`** (test target):
   ```swift
   actor MockCSMInferrer: CSMInferring {
       var stubSamples: [Float] = Array(repeating: 0.1, count: 24000)
       var stubError: Error?
       var callCount = 0
       var lastText: String?
       var lastContextAudioCount: Int?
       var delay: Duration?

       func synthesize(
           text: String,
           contextAudio: [Float],
           contextTranscript: String
       ) async throws -> [Float] {
           callCount += 1
           lastText = text
           lastContextAudioCount = contextAudio.count
           if let delay { try await Task.sleep(for: delay) }
           if let error = stubError { throw error }
           return stubSamples
       }

       func setStubError(_ error: Error?) { stubError = error }
       func setDelay(_ delay: Duration?) { self.delay = delay }
       func setStubSamples(_ samples: [Float]) { stubSamples = samples }
   }
   ```

2. **`CSMSpeechService` actor**:
   ```swift
   actor CSMSpeechService: SynthesisService {

       nonisolated let isSpeakingStream: AsyncStream<Bool>
       private let speakingContinuation: AsyncStream<Bool>.Continuation

       nonisolated(unsafe) private let engine = AVAudioEngine()
       nonisolated(unsafe) private let playerNode = AVAudioPlayerNode()

       private let inferrer: any CSMInferring
       private let profileStore: any VoiceProfileStoring
       private let activeProfileId: UUID

       private var isSpeaking = false
       private var pendingTexts: [(text: String, locale: Locale)] = []
       private var inferenceTask: Task<Void, Never>?

       init(
           outputDeviceID: AudioDeviceID?,
           activeProfileId: UUID,
           profileStore: any VoiceProfileStoring = VoiceProfileStore(),
           inferrer: any CSMInferring
       ) throws {
           self.activeProfileId = activeProfileId
           self.profileStore = profileStore
           self.inferrer = inferrer

           var cont: AsyncStream<Bool>.Continuation!
           isSpeakingStream = AsyncStream { cont = $0 }
           speakingContinuation = cont

           try setupAudioEngineNonisolated(outputDeviceID: outputDeviceID)
       }

       // Convenience init using CSMModelManager
       init(
           outputDeviceID: AudioDeviceID?,
           activeProfileId: UUID,
           profileStore: any VoiceProfileStoring = VoiceProfileStore(),
           modelManager: CSMModelManager = .shared
       ) throws {
           // This init resolves the client from the model manager synchronously
           // (only called when modelManager.state == .ready)
           let client = try modelManager.getClientSync()
           try self.init(
               outputDeviceID: outputDeviceID,
               activeProfileId: activeProfileId,
               profileStore: profileStore,
               inferrer: client
           )
       }
   ```

   Note: The primary `init` takes `any CSMInferring` directly for testability. The convenience `init` resolves via `CSMModelManager`.

3. **`speak(text:locale:)`** — text truncation at 200 chars (REQ-CSM-15):
   ```swift
   func speak(text: String, locale: Locale) async {
       guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
       pendingTexts.append((text, locale))
       if !isSpeaking { await processNext() }
   }
   ```

4. **`processNext()`** — with timeout (REQ-CSM-25):
   ```swift
   private func processNext() async {
       guard !pendingTexts.isEmpty else { setSpeaking(false); return }
       let (text, locale) = pendingTexts.removeFirst()
       setSpeaking(true)

       let startDate = Date()

       // Truncate at 200 chars (last word boundary)
       let inputText: String
       if text.count > 200 {
           let truncated = String(text.prefix(200))
           inputText = truncated.components(separatedBy: " ").dropLast().joined(separator: " ")
       } else {
           inputText = text
       }

       do {
           // Load profile (decrypt on demand)
           let profile = try await profileStore.load(id: activeProfileId)
           guard let samples = profile.samples, let transcript = profile.transcript else {
               throw VoiceProfileError.payloadMissing
           }

           // Inference with 10-second timeout
           let audio = try await withThrowingTaskGroup(of: [Float].self) { group in
               group.addTask { [inferrer] in
                   try await inferrer.synthesize(
                       text: inputText,
                       contextAudio: samples,
                       contextTranscript: transcript
                   )
               }
               group.addTask {
                   try await Task.sleep(for: .seconds(10))
                   throw CSMError.inferenceTimeout
               }
               let result = try await group.next()!
               group.cancelAll()
               return result
           }
           // profile goes out of scope here — samples deallocated (REQ-CSM-NF-06)

           let latencyMs = Int(Date().timeIntervalSince(startDate) * 1000)

           if let buffer = makePCMBuffer(from: audio) {
               scheduleBuffer(buffer)
           } else {
               setSpeaking(false)
           }

           Task {
               await TTSMetricsCollector.shared.record(
                   TTSMetrics(
                       engine: .csm,
                       synthesisLatencyMs: latencyMs,
                       textLength: text.count,
                       locale: locale,
                       timestamp: .now
                   )
               )
           }
       } catch {
           setSpeaking(false)
           await processNext()
       }
   }
   ```

5. **`stopSpeaking()` + `deactivate()`** — same pattern as KokoroSpeechService.

6. **`makePCMBuffer(from:)`, `scheduleBuffer(_:)`, `setupAudioEngineNonisolated(outputDeviceID:)`, `routeToDevice(_:)`, `setSpeaking(_:)`** — identical to KokoroSpeechService. Copy the implementations verbatim.

### Tests

```swift
// TranslateCallTests/CSMSpeechServiceTests.swift
@Suite @MainActor struct CSMSpeechServiceTests {

    private func makeService(
        mockInferrer: MockCSMInferrer = MockCSMInferrer(),
        mockStore: MockVoiceProfileStore = MockVoiceProfileStore()
    ) async throws -> (CSMSpeechService, MockCSMInferrer, MockVoiceProfileStore) {
        let profile = makeTestProfile()
        await mockStore.forceStore(profile)
        let service = try CSMSpeechService(
            outputDeviceID: nil,
            activeProfileId: profile.header.id,
            profileStore: mockStore,
            inferrer: mockInferrer
        )
        return (service, mockInferrer, mockStore)
    }

    @Test func speakCallsInferrerWithProfileContext() async throws {
        let (service, inferrer, _) = try await makeService()
        await service.speak(text: "Hello world", locale: Locale(identifier: "en-US"))
        try await Task.sleep(for: .milliseconds(200))
        let count = await inferrer.callCount
        #expect(count == 1)
        let lastText = await inferrer.lastText
        #expect(lastText == "Hello world")
        let contextCount = await inferrer.lastContextAudioCount
        #expect(contextCount == 24000) // 1s test profile
    }

    @Test func textTruncatedAt200Chars() async throws {
        let (service, inferrer, _) = try await makeService()
        let longText = String(repeating: "word ", count: 60) // 300 chars
        await service.speak(text: longText, locale: Locale(identifier: "en-US"))
        try await Task.sleep(for: .milliseconds(200))
        let lastText = await inferrer.lastText
        #expect((lastText?.count ?? 0) <= 200)
    }

    @Test func emptyTextIgnored() async throws {
        let (service, inferrer, _) = try await makeService()
        await service.speak(text: "   ", locale: Locale(identifier: "en-US"))
        try await Task.sleep(for: .milliseconds(100))
        let count = await inferrer.callCount
        #expect(count == 0)
    }

    @Test func stopClearsQueue() async throws {
        let mockInferrer = MockCSMInferrer()
        await mockInferrer.setDelay(.seconds(5)) // slow inference
        let (service, _, _) = try await makeService(mockInferrer: mockInferrer)
        await service.speak(text: "First", locale: Locale(identifier: "en-US"))
        await service.speak(text: "Second", locale: Locale(identifier: "en-US"))
        await service.stopSpeaking()
        let pending = await service.pendingTexts
        #expect(pending.isEmpty)
    }

    @Test func inferenceErrorContinuesQueue() async throws {
        let mockInferrer = MockCSMInferrer()
        await mockInferrer.setStubError(CSMError.serverNotRunning)
        let (service, _, _) = try await makeService(mockInferrer: mockInferrer)
        await service.speak(text: "Hello", locale: Locale(identifier: "en-US"))
        try await Task.sleep(for: .milliseconds(200))
        // Should not crash — error caught, speaking set to false
        // (no way to observe isSpeaking directly, but no crash = pass)
    }

    @Test func conformsToSynthesisServiceProtocol() async throws {
        let (service, _, _) = try await makeService()
        let _: any SynthesisService = service
        // Compile-time check
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
        return VoiceProfile(header: header,
                            samples: Array(repeating: 0.5, count: 24000),
                            transcript: "Hello test")
    }
}
```

**Acceptance**: 6 tests pass. `CSMSpeechService` conforms to `SynthesisService`. Text truncation works. Timeout and error recovery verified.

---

## T7 — `TTSEngine.csm` + `TTSEngineSelector` Modifications + Tests

**Covers**: REQ-CSM-16 through REQ-CSM-20, REQ-CSM-NF-04

**Files to modify**:
- `Core/TTS/TTSEngine.swift` (MODIFY)
- `Core/TTS/TTSEngineSelector.swift` (MODIFY)

**Files to create**:
- `TranslateCallTests/TTSEngineSelectorCSMTests.swift` (NEW)

### Steps

1. **`TTSEngine.swift`** — add `.csm` case:
   ```swift
   case csm

   // Update displayName switch:
   case .csm: return "Voice Clone"

   // Update supports(locale:) switch:
   case .csm: return locale.isEnglish
   ```

2. **`TTSEngineSelector.swift`** — add CSM state and routing (from design.md § 3.2):
   - Add published properties: `csmAvailable`, `voiceCloningEnabled`, `isCSMDownloading`, `activeVoiceProfileId`
   - Add computed: `voiceCloningActive`
   - Add `csmFactory` injectable closure
   - Add `profileStore: any VoiceProfileStoring` dependency
   - Modify `makeOutgoingService` — CSM priority 1, then Kokoro, then AVSpeech
   - Add `enableVoiceCloning()`, `disableVoiceCloning()`
   - Add `observeCSMModelManager()`
   - Add `observeVoiceProfileManager(_:)` with Combine sink
   - Add `private var cancellables: Set<AnyCancellable>`
   - Restore `voiceCloningEnabled` from UserDefaults in `init`

3. **UserDefaults keys**:
   - `"tlk.voiceCloning.enabled"` — Bool

### Tests

```swift
// TranslateCallTests/TTSEngineSelectorCSMTests.swift
@Suite @MainActor struct TTSEngineSelectorCSMTests {

    @Test func csmEngineDisplayName() {
        #expect(TTSEngine.csm.displayName == "Voice Clone")
    }

    @Test func csmSupportsEnglishOnly() {
        #expect(TTSEngine.csm.supports(locale: Locale(identifier: "en-US")))
        #expect(TTSEngine.csm.supports(locale: Locale(identifier: "en-GB")))
        #expect(!TTSEngine.csm.supports(locale: Locale(identifier: "es-ES")))
        #expect(!TTSEngine.csm.supports(locale: Locale(identifier: "ja-JP")))
    }

    @Test func voiceCloningActiveRequiresAllThreeConditions() {
        let selector = TTSEngineSelector(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        // All false initially
        #expect(!selector.voiceCloningActive)

        // Enable cloning but no CSM and no profile
        selector.voiceCloningEnabled = true
        #expect(!selector.voiceCloningActive)

        // Add CSM available
        selector.setCsmAvailableForTesting(true)
        #expect(!selector.voiceCloningActive) // still no profile

        // Add profile
        selector.activeVoiceProfileId = UUID()
        #expect(selector.voiceCloningActive)
    }

    @Test func makeOutgoingReturnsCSMWhenCloningActive() throws {
        let suite = UUID().uuidString
        let selector = TTSEngineSelector(defaults: UserDefaults(suiteName: suite)!)
        selector.voiceCloningEnabled = true
        selector.setCsmAvailableForTesting(true)
        let profileId = UUID()
        selector.activeVoiceProfileId = profileId

        var csmFactoryCalled = false
        selector.csmFactory = { _, _, _ in
            csmFactoryCalled = true
            return MockSynthesisService()
        }

        _ = try selector.makeOutgoingService(
            for: Locale(identifier: "en-US"),
            deviceID: nil
        )
        #expect(csmFactoryCalled)
    }

    @Test func makeOutgoingFallsBackForNonEnglish() throws {
        let suite = UUID().uuidString
        let selector = TTSEngineSelector(defaults: UserDefaults(suiteName: suite)!)
        selector.voiceCloningEnabled = true
        selector.setCsmAvailableForTesting(true)
        selector.activeVoiceProfileId = UUID()

        var avSpeechCalled = false
        selector.avSpeechFactory = { _ in
            avSpeechCalled = true
            return MockSynthesisService()
        }
        selector.csmFactory = { _, _, _ in
            Issue.record("CSM should not be called for Spanish")
            return MockSynthesisService()
        }

        _ = try selector.makeOutgoingService(
            for: Locale(identifier: "es-ES"),
            deviceID: nil
        )
        #expect(avSpeechCalled)
    }

    @Test func makeOutgoingUsesKokoroWhenCloningDisabled() throws {
        let suite = UUID().uuidString
        let selector = TTSEngineSelector(defaults: UserDefaults(suiteName: suite)!)
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        // Cloning explicitly disabled
        selector.voiceCloningEnabled = false

        var kokoroCalled = false
        selector.kokoroFactory = { _, _ in
            kokoroCalled = true
            return MockSynthesisService()
        }

        _ = try selector.makeOutgoingService(
            for: Locale(identifier: "en-US"),
            deviceID: nil
        )
        #expect(kokoroCalled)
    }
}
```

Note: `TTSEngineSelector` needs `setCsmAvailableForTesting(_:)` and public `voiceCloningEnabled` setter (or internal for testing). Follow the same pattern as `setKokoroAvailableForTesting`.

**Acceptance**: 5 tests pass. Engine priority chain verified: CSM > Kokoro > AVSpeech.

---

## T8 — UI Wiring: ContentView + AudioViewModel

**Covers**: REQ-CSM-20, REQ-CSM-21, REQ-CSM-22

**Files to modify**:
- `Features/ContentView.swift` (MODIFY)
- `Features/Main/AudioViewModel.swift` (MODIFY — wire profile manager → TTSEngineSelector)

### Steps

1. **`ContentView.swift`**:
   - Add `@State private var showCSMDownload: Bool = false`
   - Add `csmDownloadSheet` computed view (from design.md § 8.1)
   - Add `.sheet(isPresented: $showCSMDownload)` with the download sheet
   - Add `.onChange(of: viewModel.ttsEngineSelector.isCSMDownloading)` to show/hide
   - Update `voiceProfileRow` — show "Cloning ON" badge when `voiceCloningActive` (design.md § 8.2)

2. **`AudioViewModel.swift`**:
   - Wire `voiceProfileManager.$activeProfileId` → `ttsEngineSelector.activeVoiceProfileId` via Combine sink
   - Ensure `ttsEngineSelector.observeVoiceProfileManager(voiceProfileManager)` is called in init
   - Pass `profileStore` to `TTSEngineSelector` so it can forward to `csmFactory`

3. **Window height**: Increase frame height if needed to accommodate the cloning badge (likely stays at 680).

4. **Previews**: Update `ContentView` previews to include the new state.

### Tests

No new automated tests — UI verified manually. Existing `AudioViewModel` tests must still pass.

### Acceptance (manual)

- CSM download sheet appears when voice cloning is first enabled
- "Cloning ON" badge shows when CSM is available + profile active
- Voice profile changes update the TTSEngineSelector state
- Cancel button on download sheet disables voice cloning

---

## T9 — Integration Tests + Cleanup

**Covers**: AC-01 through AC-12

### Steps

1. **Automated AC checks** (covered by T1–T7 tests):

   | AC | Covered By |
   |----|-----------|
   | AC-01 | Manual: download verified in T0 spike |
   | AC-02 | `CSMSpeechServiceTests.speakCallsInferrerWithProfileContext` |
   | AC-03 | `TTSEngineSelectorCSMTests.makeOutgoingFallsBackForNonEnglish` + `makeOutgoingUsesKokoroWhenCloningDisabled` |
   | AC-04 | `TTSEngineSelectorCSMTests.makeOutgoingFallsBackForNonEnglish` |
   | AC-05 | `CSMSpeechServiceTests.speakCallsInferrerWithProfileContext` (verifies store.load called) |
   | AC-06 | `CSMModelManagerTests.unloadTransitionsToIdle` |
   | AC-07 | Needs timeout test — see below |
   | AC-08 | `CSMSpeechServiceTests.textTruncatedAt200Chars` |
   | AC-09 | Manual: verify Kokoro state after CSM load |
   | AC-10 | `CSMSpeechServiceTests.conformsToSynthesisServiceProtocol` |
   | AC-11 | `CSMSpeechServiceTests.speakCallsInferrerWithProfileContext` (metrics recorded) |
   | AC-12 | Manual benchmark on hardware |

2. **AC-07 timeout test** (if not already covered):
   ```swift
   @Test func inferenceTimeoutFallsBack() async throws {
       let mockInferrer = MockCSMInferrer()
       await mockInferrer.setDelay(.seconds(15)) // exceeds 10s timeout
       let (service, _, _) = try await makeService(mockInferrer: mockInferrer)
       await service.speak(text: "Hello", locale: Locale(identifier: "en-US"))
       try await Task.sleep(for: .seconds(12))
       // Should not hang — timeout cancels after 10s
       // Service recovers (setSpeaking false)
   }
   ```

3. **SwiftLint cleanup**: Run `/opt/homebrew/bin/swiftlint` on all new files:
   - `Core/VoiceCloning/CSM*.swift`
   - `TranslateCallTests/CSM*.swift`
   - Line length ≤ 120
   - No nested types beyond 1 level
   - `nonisolated(unsafe)` comments present

4. **Full test suite regression**:
   ```bash
   xcodebuild test \
     -project TranslateCall.xcodeproj \
     -scheme TranslateCall \
     -destination 'platform=macOS' \
     -only-testing:TranslateCallTests \
     2>&1 | xcpretty
   ```
   Confirm 0 regressions. Known flaky: `sileroVADMaxDuration` (pre-existing).

5. **Manual testing checklist**:
   - [ ] Python 3 available → setup_csm_env.sh creates venv successfully
   - [ ] csm_server.py starts and responds to /health
   - [ ] Enable voice cloning → download sheet appears
   - [ ] Download completes → "Cloning ON" badge visible
   - [ ] Speak English → CSM synthesis produces audio
   - [ ] Speak Spanish → falls back to standard TTS
   - [ ] Disable voice cloning → CSM unloaded, Kokoro reloads
   - [ ] Delete active profile → cloning disabled automatically
   - [ ] Change active profile → next utterance uses new profile
   - [ ] Server crash → auto-restarts (up to 3 times)
   - [ ] 10s inference timeout → falls back gracefully
   - [ ] Quit and relaunch → cloning state restored
   - [ ] Python not installed → clear error message

### Acceptance

- All unit tests pass (T1–T7: ≥ 21 tests).
- SwiftLint: 0 errors, 0 warnings on new files.
- Existing test suite: 0 regressions.
- Manual checklist: all items checked.

---

## Summary Table

| Task | New Files | Modified Files | New Tests | Req Coverage |
|------|-----------|---------------|-----------|-------------|
| T0 | — | — | 0 | OQs |
| T1 | `CSMConfiguration.swift`, `CSMInferring.swift` | — | 3 | NF-11,12 |
| T2 | `csm_server.py`, `setup_csm_env.sh` | — | 0 (manual) | CSM-01,02,NF-05,07 |
| T3 | `CSMClient.swift` | — | 4 | CSM-09,11,15,NF-05 |
| T4 | `CSMProcessManager.swift` | — | 0 (manual) | CSM-04,07,NF-07,10 |
| T5 | `CSMModelManager.swift` | — | 5 | CSM-01–08,NF-01,12 |
| T6 | `CSMSpeechService.swift`, `MockCSMInferrer.swift` | — | 6 | CSM-09–15,24–26,NF-06 |
| T7 | `TTSEngineSelectorCSMTests.swift` | `TTSEngine.swift`, `TTSEngineSelector.swift` | 5 | CSM-16–20,NF-04 |
| T8 | — | `ContentView.swift`, `AudioViewModel.swift` | 0 (manual) | CSM-20–22 |
| T9 | — | — | 1 (timeout) | AC-01–12 |
| **Total** | **8 new** | **4 modified** | **≥ 24** | **All 26 REQs + 12 NF-REQs** |
