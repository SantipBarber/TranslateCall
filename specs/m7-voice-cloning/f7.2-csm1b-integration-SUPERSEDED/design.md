# F7.2 — CSM-1B Voice Cloning Integration: Technical Design

> **Feature**: F7.2 — CSM-1B Voice Cloning Integration
> **Milestone**: M7 — Voice Cloning
> **Status**: DRAFT
> **Author**: SDD Process
> **Date**: 2026-03-13
> **Depends on**: requirements.md (approved), F7.1 (COMPLETED), F6.2 (COMPLETED)

---

## 1. Architecture Decision: Local Python Microservice

### 1.1 Decision

**Approach A: Local Python microservice** using `csm-mlx`.

### 1.2 Rationale

| Factor | Python Microservice (A) | Native Swift (B) |
|--------|------------------------|-------------------|
| Readiness | csm-mlx is proven, maintained | CSM not in mlx-audio-swift; would require porting ~2k LoC of Llama + decoder |
| Time to ship | ~1 week integration | ~4–6 weeks porting + debugging |
| Maintenance | Upstream fixes via `pip upgrade` | We own all bugs |
| IPC overhead | ~5–20 ms (localhost HTTP) | Zero |
| Python dependency | Yes — bundled venv | None |
| Risk | Low — API is stable | High — untested architecture port |

The IPC overhead (~5–20 ms) is negligible compared to inference time (~1–3 s). If `mlx-audio-swift` adds CSM support in the future, we can migrate to native Swift behind the same `CSMInferring` protocol without changing the rest of the codebase.

### 1.3 Component Overview

```
┌──────────────────────────────────────────────────────────┐
│  Swift App (TranslateCall)                               │
│                                                          │
│  TTSEngineSelector ──▶ CSMSpeechService (actor)          │
│                           │                              │
│                           ├── CSMModelManager (actor)    │
│                           │     ├── CSMProcessManager    │
│                           │     └── state machine        │
│                           │                              │
│                           ├── CSMClient (actor)          │
│                           │     └── HTTP → localhost      │
│                           │                              │
│                           └── makePCMBuffer() → player   │
│                                                          │
└────────────────────┬─────────────────────────────────────┘
                     │ HTTP (127.0.0.1:21935)
                     ▼
┌──────────────────────────────────────────────────────────┐
│  Python Subprocess (csm-mlx)                             │
│                                                          │
│  Flask/FastAPI server                                    │
│    POST /synthesize  { text, context_audio, transcript } │
│    GET  /health                                          │
│    POST /unload                                          │
│                                                          │
│  CSM model (MLX, 8-bit quantized ~4.5 GB)               │
│  Mimi codec (encodes reference audio)                    │
└──────────────────────────────────────────────────────────┘
```

---

## 2. New Components

### 2.1 File Inventory

| File | Type | Location |
|------|------|----------|
| `CSMInferring.swift` | Protocol | `Core/VoiceCloning/` |
| `CSMClient.swift` | Actor (HTTP client) | `Core/VoiceCloning/` |
| `CSMModelManager.swift` | Actor (lifecycle) | `Core/VoiceCloning/` |
| `CSMProcessManager.swift` | Class (subprocess) | `Core/VoiceCloning/` |
| `CSMSpeechService.swift` | Actor (SynthesisService) | `Core/VoiceCloning/` |
| `CSMConfiguration.swift` | Struct (config) | `Core/VoiceCloning/` |
| `csm_server.py` | Python server | `Resources/CSM/` |
| `setup_csm_env.sh` | Shell script | `Resources/CSM/` |

| File | Type | Action |
|------|------|--------|
| `TTSEngine.swift` | Enum | MODIFY — add `.csm` case |
| `TTSEngineSelector.swift` | Class | MODIFY — add CSM routing + voice cloning toggle |
| `ContentView.swift` | View | MODIFY — add CSM download sheet, cloning toggle |
| `VoiceProfileManager.swift` | Class | MODIFY — minor: notify on active profile change |

### 2.2 `CSMInferring` Protocol

```swift
// Core/VoiceCloning/CSMInferring.swift

/// Abstraction over CSM-1B inference backend.
/// Production: `CSMClient` (HTTP to Python). Tests: `MockCSMInferrer`.
protocol CSMInferring: Actor {
    /// Synthesize speech conditioned on reference audio.
    /// - Parameters:
    ///   - text: Text to speak (≤ 200 chars)
    ///   - contextAudio: Reference audio samples (Float32, 24 kHz mono)
    ///   - contextTranscript: Transcript of the reference audio
    /// - Returns: Synthesized audio samples (Float32, 24 kHz mono)
    func synthesize(
        text: String,
        contextAudio: [Float],
        contextTranscript: String
    ) async throws -> [Float]
}
```

This protocol decouples `CSMSpeechService` from the HTTP transport, enabling:
- Unit tests with `MockCSMInferrer`
- Future migration to native Swift CSM without changing the service layer

### 2.3 `CSMConfiguration`

```swift
// Core/VoiceCloning/CSMConfiguration.swift

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
}
```

Port `21935` is chosen to avoid conflicts with common services. Bound to `127.0.0.1` only (REQ-CSM-NF-07).

### 2.4 `CSMClient` — HTTP Inference Client

```swift
// Core/VoiceCloning/CSMClient.swift

actor CSMClient: CSMInferring {
    private let config: CSMConfiguration
    private let session: URLSession

    init(config: CSMConfiguration = .default) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 15  // 10s inference + 5s margin
        self.session = URLSession(configuration: sessionConfig)
    }

    func synthesize(
        text: String,
        contextAudio: [Float],
        contextTranscript: String
    ) async throws -> [Float] {
        // 1. Build multipart or JSON request
        // 2. POST to http://127.0.0.1:21935/synthesize
        // 3. Decode response: base64 Float32 array or raw bytes
        // 4. Return [Float] at 24 kHz
    }

    func healthCheck() async -> Bool {
        // GET http://127.0.0.1:21935/health → 200 OK
    }

    func requestUnload() async {
        // POST http://127.0.0.1:21935/unload
    }
}
```

**Request format** (JSON):

```json
POST /synthesize
{
    "text": "Hello, how are you?",
    "context_audio_b64": "<base64-encoded Float32 LE bytes>",
    "context_transcript": "This is my voice reading a sample text.",
    "max_audio_length_ms": 10000,
    "temperature": 0.8,
    "top_k": 50
}
```

**Response format** (JSON):

```json
{
    "audio_b64": "<base64-encoded Float32 LE bytes>",
    "sample_rate": 24000,
    "duration_ms": 1850,
    "inference_ms": 1420
}
```

Using base64 for audio transfer keeps the API JSON-only (no multipart parsing). At 24 kHz × 4 bytes × 10 s = 960 KB raw → ~1.3 MB base64. Acceptable for localhost.

### 2.5 `CSMProcessManager` — Python Subprocess Lifecycle

```swift
// Core/VoiceCloning/CSMProcessManager.swift

/// Manages the CSM Python subprocess lifecycle.
/// NOT an actor — owned and called exclusively by CSMModelManager (actor isolation).
final class CSMProcessManager: Sendable {
    // nonisolated(unsafe): mutated only from CSMModelManager's actor context
    nonisolated(unsafe) private var process: Process?
    private let config: CSMConfiguration

    init(config: CSMConfiguration = .default)

    /// Starts the Python subprocess.
    /// - Finds python3 in bundled venv or PATH
    /// - Runs: python3 Resources/CSM/csm_server.py --port 21935 --host 127.0.0.1 --quantize 8
    /// - Waits for /health to return 200 (up to 30s)
    func start() async throws

    /// Sends SIGTERM, waits up to 5s, then SIGKILL if needed.
    func stop()

    /// Returns true if process is running and /health responds.
    func isHealthy() async -> Bool

    /// Restarts the process (stop + start).
    func restart() async throws
}
```

**Process management details**:
- `Process.executableURL` = path to `python3` in the bundled virtual environment
- `Process.arguments` = `[scriptPath, "--port", "21935", "--host", "127.0.0.1", "--quantize", "8"]`
- `Process.standardOutput` / `standardError` → `Pipe` for log capture
- Health check loop: poll `/health` every 500 ms up to 30 s during startup
- `Process.terminationHandler` triggers automatic restart (up to 3 retries per session, per REQ-CSM-NF-10)

### 2.6 `CSMModelManager` — State Machine

Mirrors `KokoroModelManager` exactly:

```swift
// Core/VoiceCloning/CSMModelManager.swift

actor CSMModelManager {

    enum ModelState: Sendable {
        case idle
        case downloading
        case loading        // Python process starting + model loading
        case ready
        case failed(String)
    }

    static let shared = CSMModelManager()

    private(set) var state: ModelState = .idle
    nonisolated let stateStream: AsyncStream<ModelState>

    private let processManager: CSMProcessManager
    private let client: CSMClient
    private var loadTask: Task<Void, Error>?

    // Factory for dependency injection in tests
    typealias ClientFactory = @Sendable (CSMConfiguration) -> any CSMInferring

    init(
        config: CSMConfiguration = .default,
        clientFactory: ClientFactory? = nil
    )

    /// Ensures the CSM server is running and ready.
    /// Concurrent callers share one in-flight load task (coalescing).
    func ensureReady() async throws

    /// Returns the inference client (only valid when state == .ready).
    func getClient() throws -> any CSMInferring

    /// Stops the subprocess and releases memory.
    func unload()

    /// Downloads the Python environment + model weights if not cached.
    func downloadIfNeeded() async throws

    /// Checks if model weights exist at the expected cache path.
    func isModelCached() -> Bool
}
```

**State transitions**:

```
idle ──▶ downloading ──▶ loading ──▶ ready
  │          │              │          │
  │          ▼              ▼          ▼
  └──────── failed ◀───────┘     unload() → idle
```

**Download flow** (`downloadIfNeeded()`):
1. Check if `~/Library/Application Support/TranslateCall/Models/CSM1B/ckpt.safetensors` exists
2. If not: transition to `.downloading`
3. Call `setup_csm_env.sh` which:
   - Creates a Python virtual environment at `~/Library/Application Support/TranslateCall/Models/CSM1B/venv/`
   - `pip install csm-mlx` (includes model download from HuggingFace)
4. On success: transition to `.loading` → start process → `.ready`
5. On failure: transition to `.failed(reason)`

### 2.7 `CSMSpeechService` — SynthesisService Conformance

Mirrors `KokoroSpeechService` closely:

```swift
// Core/VoiceCloning/CSMSpeechService.swift

actor CSMSpeechService: SynthesisService {

    // MARK: - SynthesisService protocol
    nonisolated let isSpeakingStream: AsyncStream<Bool>

    // MARK: - Audio engine (same pattern as KokoroSpeechService)
    nonisolated(unsafe) private let engine: AVAudioEngine
    nonisolated(unsafe) private let playerNode: AVAudioPlayerNode

    // MARK: - Dependencies
    private let modelManager: CSMModelManager
    private let profileStore: any VoiceProfileStoring
    private let activeProfileId: UUID

    // MARK: - Queue
    private var isSpeaking = false
    private var pendingTexts: [(text: String, locale: Locale)] = []

    init(
        outputDeviceID: AudioDeviceID?,
        activeProfileId: UUID,
        profileStore: any VoiceProfileStoring = VoiceProfileStore(),
        modelManager: CSMModelManager = .shared
    ) throws

    // MARK: - SynthesisService

    func speak(text: String, locale: Locale) async {
        // 1. Truncate text at 200 chars (last word boundary)
        // 2. Queue if already speaking
        // 3. processNext()
    }

    func stopSpeaking() async { /* cancel inference, stop player, clear queue */ }
    func deactivate() async { /* stop engine */ }

    // MARK: - Private

    private func processNext() async {
        // 1. Get CSM client from modelManager
        // 2. Load active profile: store.load(id: activeProfileId)
        //    → extract (samples: [Float], transcript: String)
        // 3. Call client.synthesize(text:contextAudio:contextTranscript:)
        //    → with 10-second timeout (Task.sleep race)
        // 4. Convert [Float] 24kHz → AVAudioPCMBuffer via makePCMBuffer()
        //    (REUSE same implementation as KokoroSpeechService)
        // 5. Schedule buffer on playerNode
        // 6. Record TTSMetrics with engine: .csm
        // 7. Zero out / release profile samples from memory
    }

    // makePCMBuffer(from:) — identical to KokoroSpeechService
    // scheduleBuffer(_:) — identical to KokoroSpeechService
    // setupAudioEngineNonisolated(outputDeviceID:) — identical to KokoroSpeechService
}
```

**Profile lifecycle per inference call** (REQ-CSM-10, REQ-CSM-NF-06):

```
processNext()
  │
  ├── let profile = try await profileStore.load(id: activeProfileId)
  │     ↓ (decrypted: .samples + .transcript in memory)
  │
  ├── let audio = try await client.synthesize(
  │       text: inputText,
  │       contextAudio: profile.samples!,
  │       contextTranscript: profile.transcript!
  │   )
  │
  └── profile goes out of scope → samples deallocated (ARC)
```

The `VoiceProfile` struct uses value semantics (`[Float]`). Once `profile` exits scope, the samples array is deallocated by ARC. No explicit zeroing needed — Swift's allocator overwrites on next allocation.

**Timeout implementation** (REQ-CSM-25):

```swift
private func processNext() async {
    // ...
    do {
        let audio = try await withThrowingTaskGroup(of: [Float].self) { group in
            group.addTask {
                try await client.synthesize(text: text, contextAudio: samples, contextTranscript: transcript)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw CSMError.inferenceTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        // ... schedule buffer
    } catch {
        // Fallback: mark failed, processNext() will skip
    }
}
```

### 2.8 Python Server — `csm_server.py`

Minimal Flask server wrapping csm-mlx:

```python
# Resources/CSM/csm_server.py

"""
Minimal HTTP server for CSM-1B voice cloning.
Runs on localhost only. Receives text + reference audio,
returns synthesized audio conditioned on the reference.

Usage:
    python csm_server.py --port 21935 --host 127.0.0.1 --quantize 8
"""

from flask import Flask, request, jsonify
from csm_mlx import CSM, csm_1b, generate, Segment
from huggingface_hub import hf_hub_download
from mlx import nn
import mlx.core as mx
import numpy as np
import base64
import struct
import time
import argparse

app = Flask(__name__)
model = None  # Loaded on startup

def load_model(quantize_bits=8):
    global model
    csm = CSM(csm_1b())
    weight = hf_hub_download(
        repo_id="senstella/csm-1b-mlx",
        filename="ckpt.safetensors"
    )
    csm.load_weights(weight)
    if quantize_bits in (4, 8):
        nn.quantize(csm, bits=quantize_bits)
    model = csm

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "model_loaded": model is not None})

@app.route("/synthesize", methods=["POST"])
def synthesize():
    data = request.json
    text = data["text"]
    context_audio_b64 = data["context_audio_b64"]
    context_transcript = data["context_transcript"]
    max_audio_ms = data.get("max_audio_length_ms", 10000)
    temp = data.get("temperature", 0.8)
    top_k = data.get("top_k", 50)

    # Decode Float32 LE audio from base64
    raw_bytes = base64.b64decode(context_audio_b64)
    context_samples = np.frombuffer(raw_bytes, dtype=np.float32)
    context_audio_mx = mx.array(context_samples)

    # Build context segment
    context = [
        Segment(
            speaker=0,
            text=context_transcript,
            audio=context_audio_mx
        )
    ]

    # Generate
    start = time.time()
    sampler = make_sampler(temp=temp, top_k=top_k)
    audio = generate(
        model,
        text=text,
        speaker=0,
        context=context,
        max_audio_length_ms=max_audio_ms,
        sampler=sampler
    )
    inference_ms = int((time.time() - start) * 1000)

    # Encode output as base64 Float32 LE
    audio_np = np.asarray(audio, dtype=np.float32)
    audio_b64 = base64.b64encode(audio_np.tobytes()).decode("ascii")

    duration_ms = int(len(audio_np) / 24000 * 1000)

    return jsonify({
        "audio_b64": audio_b64,
        "sample_rate": 24000,
        "duration_ms": duration_ms,
        "inference_ms": inference_ms
    })

@app.route("/unload", methods=["POST"])
def unload():
    global model
    model = None
    mx.metal.clear_cache()
    return jsonify({"status": "unloaded"})

def make_sampler(temp, top_k):
    from mlx_lm.sample_utils import make_sampler as _make_sampler
    return _make_sampler(temp=temp, top_k=top_k)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=21935)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--quantize", type=int, default=8, choices=[0, 4, 8])
    args = parser.parse_args()

    load_model(quantize_bits=args.quantize if args.quantize > 0 else None)
    app.run(host=args.host, port=args.port, threaded=False)
```

### 2.9 Environment Setup Script — `setup_csm_env.sh`

```bash
#!/bin/bash
# Resources/CSM/setup_csm_env.sh
#
# Creates a Python virtual environment and installs csm-mlx.
# Called by CSMModelManager.downloadIfNeeded().
#
# Usage: setup_csm_env.sh <install_dir>
# Example: setup_csm_env.sh ~/Library/Application\ Support/TranslateCall/Models/CSM1B

set -euo pipefail

INSTALL_DIR="${1:?Usage: setup_csm_env.sh <install_dir>}"
VENV_DIR="$INSTALL_DIR/venv"

# Find python3 (prefer 3.12 for sentencepiece compatibility)
PYTHON=$(command -v python3.12 || command -v python3)
if [ -z "$PYTHON" ]; then
    echo "ERROR: python3 not found" >&2
    exit 1
fi

# Create venv if not present
if [ ! -d "$VENV_DIR" ]; then
    "$PYTHON" -m venv "$VENV_DIR"
fi

# Install dependencies
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet \
    "csm-mlx @ git+https://github.com/senstella/csm-mlx" \
    flask

echo "CSM environment ready at $VENV_DIR"
```

---

## 3. Modified Components

### 3.1 `TTSEngine` — Add `.csm` Case

```swift
enum TTSEngine: String, Codable, Sendable, CaseIterable {
    case avSpeech
    case kokoro
    case csm       // NEW

    var displayName: String {
        switch self {
        case .avSpeech: return "AVSpeech"
        case .kokoro:   return "Kokoro"
        case .csm:      return "Voice Clone"
        }
    }

    func supports(locale: Locale) -> Bool {
        switch self {
        case .avSpeech: return true
        case .kokoro:   return locale.isEnglish
        case .csm:      return locale.isEnglish  // English-only
        }
    }
}
```

### 3.2 `TTSEngineSelector` — CSM Integration

New published state:

```swift
@Published private(set) var csmAvailable: Bool = false
@Published private(set) var voiceCloningEnabled: Bool = false
@Published private(set) var isCSMDownloading: Bool = false
@Published private(set) var activeVoiceProfileId: UUID?
```

New computed property:

```swift
var voiceCloningActive: Bool {
    voiceCloningEnabled && csmAvailable && activeVoiceProfileId != nil
}
```

New factory:

```swift
var csmFactory: (AudioDeviceID?, UUID, any VoiceProfileStoring) throws -> any SynthesisService = {
    deviceID, profileId, store in
    try CSMSpeechService(outputDeviceID: deviceID, activeProfileId: profileId, profileStore: store)
}
```

Modified `makeOutgoingService`:

```swift
func makeOutgoingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> any SynthesisService {
    currentTargetLocale = locale

    // Priority 1: CSM voice cloning (if enabled, available, English, profile active)
    if voiceCloningActive, locale.isEnglish, let profileId = activeVoiceProfileId {
        return try csmFactory(deviceID, profileId, profileStore)
    }

    // Priority 2: Kokoro (if preferred, available, English)
    if preferredEngine == .kokoro, kokoroAvailable, locale.isEnglish {
        let voiceID = defaults.string(forKey: KokoroConfiguration.voiceDefaultsKey) ?? ""
        let config = KokoroConfiguration(voiceIdentifier: voiceID)
        return try kokoroFactory(deviceID, config)
    }

    // Priority 3: AVSpeech (always available)
    return try avSpeechFactory(deviceID)
}
```

**Kokoro unloading when CSM loads** (REQ-CSM-NF-04):

```swift
func enableVoiceCloning() {
    voiceCloningEnabled = true
    defaults.set(true, forKey: "tlk.voiceCloning.enabled")

    // Unload Kokoro to save memory — CSM supersedes it for English
    if kokoroAvailable {
        unloadKokoroModel()
    }

    isCSMDownloading = true
    Task { [weak self] in
        do {
            try await CSMModelManager.shared.ensureReady()
        } catch {
            logger.error("CSM setup failed: \(error)")
        }
        self?.isCSMDownloading = false
    }
}

func disableVoiceCloning() {
    voiceCloningEnabled = false
    defaults.set(false, forKey: "tlk.voiceCloning.enabled")
    Task { await CSMModelManager.shared.unload() }
}
```

CSM state observation (mirrors Kokoro pattern):

```swift
private func observeCSMModelManager() {
    Task { [weak self] in
        for await state in CSMModelManager.shared.stateStream {
            await MainActor.run {
                switch state {
                case .ready:                     self?.csmAvailable = true
                case .failed, .idle, .downloading: self?.csmAvailable = false
                case .loading:                   break
                }
            }
        }
    }
}
```

### 3.3 `VoiceProfileManager` — Profile Change Notification

The existing `setActiveProfile(_:)` already publishes via `@Published var activeProfileId`. `TTSEngineSelector` will observe this via Combine:

```swift
// In TTSEngineSelector.init or a dedicated method
func observeVoiceProfileManager(_ manager: VoiceProfileManager) {
    manager.$activeProfileId
        .receive(on: RunLoop.main)
        .sink { [weak self] id in
            self?.activeVoiceProfileId = id
        }
        .store(in: &cancellables)
}
```

This is wired in `AudioViewModel` where both objects are created.

---

## 4. Data Flow

### 4.1 Synthesis Flow (Happy Path)

```
User speaks → STT → Translation → "Hello, how are you?"
                                        │
                                        ▼
                              TTSEngineSelector.makeOutgoingService()
                                        │
                    voiceCloningActive?──┤
                     YES                │ NO
                      │                 ▼
                      ▼            KokoroSpeech / AVSpeech
                CSMSpeechService
                      │
                      ├── 1. Truncate text ≤ 200 chars
                      │
                      ├── 2. profileStore.load(id: activeProfileId)
                      │      → VoiceProfile { samples: [Float], transcript: String }
                      │      → AES-256-GCM decryption (in-memory, scoped)
                      │
                      ├── 3. client.synthesize(text, contextAudio, contextTranscript)
                      │      → HTTP POST to Python server
                      │      → CSM inference (~1–3 s)
                      │      → [Float] 24 kHz response
                      │
                      ├── 4. makePCMBuffer(from: samples)
                      │      → AVAudioConverter SRC 24 kHz → device rate
                      │
                      ├── 5. scheduleBuffer → AVAudioPlayerNode → output
                      │
                      └── 6. TTSMetricsCollector.record(engine: .csm, latencyMs: ...)
```

### 4.2 Model Lifecycle Flow

```
User taps "Enable Voice Cloning"
    │
    ├── TTSEngineSelector.enableVoiceCloning()
    │       ├── Unload Kokoro (save memory)
    │       └── CSMModelManager.ensureReady()
    │               │
    │               ├── isModelCached()? ──NO──▶ downloadIfNeeded()
    │               │                              │
    │               │                              ├── Run setup_csm_env.sh
    │               │                              ├── pip install csm-mlx
    │               │                              └── Download weights from HF
    │               │
    │               ├── CSMProcessManager.start()
    │               │       ├── Spawn python3 csm_server.py
    │               │       ├── Wait for /health → 200 OK (up to 30 s)
    │               │       └── Model loads into GPU memory
    │               │
    │               └── Transition to .ready
    │
    └── csmAvailable = true → UI updates
```

### 4.3 Fallback Chain

```
CSMSpeechService.processNext()
    │
    ├── try client.synthesize(...)
    │       │
    │       ├── Success → play audio
    │       │
    │       ├── Timeout (10 s) → log, fall through ▼
    │       │
    │       └── Error → log, fall through ▼
    │
    └── Fallback: next utterance will trigger TTSEngineSelector
        to return Kokoro/AVSpeech (CSMSpeechService marks
        csmAvailable = false via CSMModelManager state)
```

---

## 5. Error Handling

### 5.1 Error Types

```swift
enum CSMError: LocalizedError {
    case serverNotRunning
    case inferenceTimeout
    case invalidResponse
    case downloadFailed(String)
    case pythonNotFound
    case environmentSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverNotRunning: return "CSM voice cloning server is not running."
        case .inferenceTimeout: return "Voice cloning inference timed out (>10s)."
        case .invalidResponse: return "Invalid response from CSM server."
        case .downloadFailed(let reason): return "CSM model download failed: \(reason)"
        case .pythonNotFound: return "Python 3 is required for voice cloning but was not found."
        case .environmentSetupFailed(let reason): return "CSM environment setup failed: \(reason)"
        }
    }
}
```

### 5.2 Error Recovery Matrix

| Scenario | Detection | Recovery | User Impact |
|----------|-----------|----------|-------------|
| Python not installed | `setup_csm_env.sh` exit code | Surface error, suggest installing Python | Cannot use voice cloning |
| Model download fails | HTTP/pip error | Retry button in UI | Temporary; retryable |
| Server crashes mid-inference | Process termination handler | Auto-restart (3 retries) | Brief pause, next utterance OK |
| Inference timeout (>10 s) | Task group race | Cancel, fall back to Kokoro/AVSpeech | One utterance in standard voice |
| Health check fails | GET /health timeout | Restart server | Brief pause |
| Profile decryption fails | `VoiceProfileError` | Fall back to standard TTS | One utterance in standard voice |
| Port already in use | Server bind error | Try port + 1, or surface error | Requires user action if persists |

---

## 6. Memory Management

### 6.1 Memory Budget

| Component | Estimated Memory | When Loaded |
|-----------|-----------------|-------------|
| CSM-1B (8-bit quantized) | ~4.5 GB | Voice cloning active |
| Mimi codec | ~200 MB | Part of CSM |
| Python runtime | ~100 MB | Voice cloning active |
| Voice profile (decrypted) | ~2.8 MB (30s × 24kHz × 4B) | During inference only |
| **Total CSM** | **~4.8 GB** | |
| Kokoro (if loaded) | ~600 MB | Unloaded when CSM loads |
| Parakeet STT | ~400 MB | Independent (STT, not TTS) |

### 6.2 Mutual Exclusion: CSM vs Kokoro (REQ-CSM-NF-04)

When CSM loads → Kokoro unloads. When CSM unloads → Kokoro can reload (if preferred engine is `.kokoro`).

```
enableVoiceCloning()  → KokoroModelManager.shared.unload()
                      → CSMModelManager.shared.ensureReady()

disableVoiceCloning() → CSMModelManager.shared.unload()
                      // Kokoro reloads lazily on next makeOutgoingService() call
```

### 6.3 Minimum Hardware

| RAM | CSM Quantization | Viable? |
|-----|-----------------|---------|
| 8 GB | 8-bit | Marginal — OS + app + CSM ≈ 7–8 GB. May swap. |
| 8 GB | 4-bit | Workable but quality trade-off |
| 16 GB | 8-bit | Comfortable — recommended minimum |
| 32 GB+ | FP16 | Full quality, no constraints |

UI should warn users with 8 GB RAM that voice cloning may be slow.

---

## 7. Testing Strategy

### 7.1 Testable Seams

| Component | Injection Point | Mock |
|-----------|----------------|------|
| `CSMSpeechService` | `CSMInferring` protocol via `CSMModelManager` | `MockCSMInferrer` |
| `CSMModelManager` | `ClientFactory` closure | Returns `MockCSMInferrer` |
| `CSMClient` | `URLSession` (or skip — test via integration) | URLProtocol mock |
| `TTSEngineSelector` | `csmFactory` closure | Returns `MockSynthesisService` |
| `CSMProcessManager` | Not directly tested (integration only) | — |

### 7.2 Unit Test Count Estimate

| Component | Tests |
|-----------|-------|
| `CSMConfiguration` | 2 (defaults, baseURL) |
| `CSMError` | 1 (errorDescription non-empty) |
| `TTSEngine.csm` | 2 (displayName, supports) |
| `CSMModelManager` state machine | 5 (idle→loading→ready, failure, unload, coalescing, re-download) |
| `CSMSpeechService` | 6 (speak, truncation, timeout, stop, queue, profile load) |
| `TTSEngineSelector` CSM routing | 5 (cloning active, cloning disabled, non-English, no profile, fallback) |
| **Total** | **~21** |

### 7.3 `MockCSMInferrer`

```swift
// TranslateCallTests/Mocks/MockCSMInferrer.swift

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
}
```

---

## 8. UI Changes (Minimal in F7.2)

F7.2 focuses on backend integration. UI changes are minimal — the full UX (A/B toggle, preview, per-language tuning) is deferred to F7.3.

### 8.1 ContentView — CSM Download Sheet

Add a `showCSMDownload` state and sheet (mirrors Kokoro download sheet):

```swift
@State private var showCSMDownload: Bool = false

// In body:
.sheet(isPresented: $showCSMDownload) {
    csmDownloadSheet
}
.onChange(of: viewModel.ttsEngineSelector.isCSMDownloading) { _, downloading in
    showCSMDownload = downloading
}

private var csmDownloadSheet: some View {
    VStack(spacing: 16) {
        Text("Setting Up Voice Cloning")
            .font(.headline)
        Text("≈ 2 GB · One-time download\nRequires Python 3. All inference runs on-device.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        ProgressView()
            .scaleEffect(1.2)
        Button("Cancel") {
            viewModel.ttsEngineSelector.disableVoiceCloning()
            showCSMDownload = false
        }
        .buttonStyle(.bordered)
    }
    .padding(32)
    .frame(width: 300)
}
```

### 8.2 Voice Profile Row — Cloning Toggle

Update `voiceProfileRow` in ContentView to include a cloning enable/disable toggle when a profile is active:

```swift
private var voiceProfileRow: some View {
    HStack(spacing: 8) {
        if let activeProfile = voiceProfileManager.activeProfile {
            Image(systemName: "person.wave.2.fill")
                .font(.caption)
                .foregroundStyle(viewModel.ttsEngineSelector.voiceCloningActive ? .green : .orange)
            Text(activeProfile.name)
                .font(.caption)
                .lineLimit(1)

            if viewModel.ttsEngineSelector.csmAvailable {
                Text("Cloning ON")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 4)
                    .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
        } else {
            Image(systemName: "person.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("No voice profile")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Voice Profiles…") { showVoiceProfiles = true }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

The full voice cloning toggle and A/B preview UI is deferred to F7.3.

---

## 9. Open Questions Resolution

| OQ | Question | Resolution |
|----|----------|------------|
| OQ-1 | Python bridge vs native Swift? | **Python bridge** (csm-mlx). See § 1 rationale. |
| OQ-2 | Quantisation? | **8-bit** by default. Best quality/memory trade-off. Configurable via `CSMConfiguration.quantizeBits`. |
| OQ-3 | Streaming inference? | **No** in F7.2. Batch-then-play. Streaming adds complexity; defer to future optimisation. The latency target (≤ 3 s total) is achievable without streaming on M2+. |
| OQ-4 | Mimi codec caching? | **No** in F7.2. The Python server re-encodes on each call. Caching would require modifying csm-mlx internals. Defer to future optimisation if profiling shows it's a bottleneck. |
| OQ-5 | Model version pinning? | Pin to a specific csm-mlx git commit in `setup_csm_env.sh` (e.g., `pip install git+https://...@<commit>`). Update manually when validated. |
| OQ-6 | Concurrent GPU/ANE access? | MLX handles GPU scheduling internally. Parakeet (STT) and CSM (TTS) don't run simultaneously in the pipeline (STT finishes → translate → TTS). No explicit serialisation needed. |

---

## 10. Constraints & Assumptions

1. **Python 3 required**: Users must have Python 3.10+ installed. The app will check and surface a clear error if missing. This is acceptable for a power-user macOS app targeting developers and professionals.

2. **First-use latency**: Initial setup (venv creation + pip install + model download) takes 2–10 minutes depending on network speed. Subsequent launches load in ~15 s (process start + model load).

3. **Port availability**: `127.0.0.1:21935` must be free. If occupied, the system will surface an error. A port-scan fallback could be added later but is out of scope for F7.2.

4. **No sandboxing compatibility**: The Python subprocess approach is incompatible with App Sandbox (macOS). TranslateCall already runs without sandbox (entitlements for BlackHole, ScreenCaptureKit). This is not a new constraint.

5. **Audio format compatibility**: CSM outputs 24 kHz Float32 mono — identical to Kokoro. The existing `makePCMBuffer(from:)` SRC pipeline is reused without changes.

---

## 11. File Creation Order

```
T0: Spike — resolve OQs, verify csm-mlx setup, benchmark
T1: CSMConfiguration + CSMError + CSMInferring protocol
T2: csm_server.py + setup_csm_env.sh (Python side)
T3: CSMClient (HTTP client actor)
T4: CSMProcessManager (subprocess lifecycle)
T5: CSMModelManager (state machine, download, health)
T6: CSMSpeechService (SynthesisService conformance)
T7: TTSEngine.csm + TTSEngineSelector modifications
T8: ContentView + UI wiring
T9: Integration tests + cleanup
```

---

*This document defines **how** the system implements the requirements. The task breakdown with TDD cycles is in `tasks.md`.*
