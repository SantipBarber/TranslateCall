# F8.5.2 — TTS Playback — Technical Design

> Status: DRAFT — pending user review (2026-10-04)
> Requirements: `requirements.md` (same folder)

## 1. Overview

Today each engine (AVSpeech, Kokoro, Qwen, Edge) re-implements queueing, device output, sample-rate conversion and "am I speaking", and each copy is broken in a different way (A3, A9, A9b, A12). This feature splits the work in two:

- **synthesis**: text → PCM, one small `UtteranceSynthesizer` per engine;
- **playback**: one `TTSPlaybackService` per direction. It holds the bounded queue, generation-based cancellation, output to the device, truthful `isSpeaking`, the per-utterance fallback and events.

The coordinator keeps seeing `SynthesisService`.

```
AudioCoordinator ──speak(text)──► TTSPlaybackService (actor, SynthesisService)
                                   │ queue (≤3 pending) → worker (1 in flight)
                                   │ generation, watchdog, breaker, events, metrics
                                   ├─ primary:  UtteranceSynthesizer ─┐
                                   ├─ fallback: UtteranceSynthesizer ─┤ AsyncThrowingStream<AVAudioPCMBuffer>
                                   └─ output:   AudioOutputting (TTSOutput) ◄─ schedule(buffer) → played-back signal
                                                                         └─► AVAudioEngine → BlackHole / speakers

UtteranceSynthesizers: AVSpeech (write) · Kokoro (KokoroModelManager) · Qwen (MLXInferenceGate) · Edge (EdgeTTSWebSocket ▸ EdgeTransport ▸ Starscream)
VoicePreviewService ──► MLXInferenceGate (same process-wide gate)
```

## 2. Files

```
TranslateCall/Core/TTS/UtteranceSynthesizer.swift        NEW  protocol + TTSEvent, TTSSkipReason
TranslateCall/Core/TTS/TTSPlaybackService.swift          NEW  the SynthesisService implementation
TranslateCall/Core/TTS/TTSOutput.swift                   NEW  AudioOutputting protocol + AVAudioEngine output
TranslateCall/Core/TTS/AVSpeechUtteranceSynthesizer.swift NEW (from AVSpeechService)
TranslateCall/Core/TTS/KokoroUtteranceSynthesizer.swift  NEW (from KokoroSpeechService)
TranslateCall/Core/TTS/EdgeUtteranceSynthesizer.swift    NEW (from EdgeTTSService) + MP3 decode
TranslateCall/Core/TTS/EdgeTTSWebSocket.swift            CHANGED  EdgeTransport, real connection state, timeouts
TranslateCall/Core/VoiceCloning/MLXInferenceGate.swift   NEW
TranslateCall/Core/VoiceCloning/QwenUtteranceSynthesizer.swift NEW (from QwenCloneSpeechService)
TranslateCall/Core/VoiceCloning/QwenCloneModelManager.swift CHANGED  gate-only access
TranslateCall/Core/VoiceCloning/VoicePreviewService.swift CHANGED  uses the gate
TranslateCall/Core/TTS/TTSEngineSelector.swift           CHANGED  builds TTSPlaybackService(primary:fallback:output:)
TranslateCall/Core/Audio/AudioCoordinator(+Pipeline).swift CHANGED  no pre-emptive stopSpeaking; TTS events → notice
TranslateCall/Features/…                                 CHANGED  notice line; preview disabled while capturing
DELETED: AVSpeechService.swift, KokoroSpeechService.swift, QwenCloneSpeechService.swift, EdgeTTSService.swift
TranslateCallTests/…                                     fakes (FakeSynthesizer, FakeOutput, FakeEdgeTransport, TestClock), unit + integration suites
.opengrep/rules/*.yml                                    severity promotions (REQ-T-51)
```

`SynthesisConfiguration` and `STSError` stay in `SynthesisService.swift`. The tests of the deleted services migrate to the new suites. They test the same behaviours, now through `TTSPlaybackService` with fakes.

## 3. Components

### 3.1 `UtteranceSynthesizer`

```swift
nonisolated protocol UtteranceSynthesizer: Sendable {
    var engine: TTSEngine { get }
    func canSpeak(_ locale: Locale) -> Bool
    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
}
```

- The stream must honour cancellation. When the consumer stops iterating, `onTermination` cancels the producing work, or for MLX, abandons it.
- **AVSpeech:**
  - `write(utterance) { buffer in continuation.yield(pcm) }` yields synchronously from the callback.
  - The stream finishes on the end marker (a zero-length buffer), or on `didFinish`/`didCancel` through the delegate bridge.
  - `canSpeak` means a voice exists for the language (the current `bestVoice` logic).
  - The `AVSpeechSynthesizer` instance is owned by the synthesizer object.
- **Kokoro:**
  - `ensureReady` → `synthesizeSamples` → one 24 kHz mono Float32 buffer.
  - `canSpeak` means English and `kokoroAvailable`; the selector already checks this.
- **Qwen:**
  - `gate.run(wait:inference:) { client.synthesize(...) }` → one buffer at `client.sampleRate`.
  - Profile loading as today.
- **Edge:**
  - `EdgeTTSWebSocket.synthesize` streams MP3 chunks. They are collected until `turn.end`, then decoded once to PCM with `AVAudioConverter`, using an in-memory `AVAudioCompressedBuffer` or an `AudioFileStream` parse. If in-memory MP3 decoding proves impractical, a temporary file under `FileManager.temporaryDirectory`, deleted after decoding, is acceptable; record it in tasks.
  - `canSpeak` means `EdgeTTSVoiceCatalog.defaultVoice(for:) != nil`.

### 3.2 `TTSOutput` and `AudioOutputting`

```swift
protocol AudioOutputting: AnyObject, Sendable {
    /// Schedules a buffer; the returned handle completes when it has been played back (.dataPlayedBack)
    /// or fails with CancellationError if stop() is called first.
    func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle
    func stop()          // cancels everything scheduled
    func shutdown()      // stop + engine.stop
}
```

- `TTSOutput` owns `AVAudioEngine`, `AVAudioPlayerNode` and `AVAudioMixerNode`, and sets the output `CurrentDevice`. This is the only HAL property it writes; the F8.5.1 lesson rules out format writes.
- The player is connected with the hardware output format. Each buffer is converted to that format with one cached `AVAudioConverter` per input format. This covers Kokoro and Qwen at 24 kHz, AVSpeech at its native rate and Edge at 24 kHz.
- `PlaybackHandle` wraps a continuation that is resumed exactly once: played, cancelled or engine stopped.
- On `AVAudioEngineConfigurationChange` it restarts the engine on the same device. If the restart fails, `schedule` throws `outputUnavailable`.

### 3.3 `TTSPlaybackService`

```swift
actor TTSPlaybackService: SynthesisService {
    nonisolated let isSpeakingStream: AsyncStream<Bool>      // makeStream, .bufferingNewest(8)
    nonisolated let events: AsyncStream<TTSEvent>             // makeStream, .bufferingNewest(16)
    init(primary: any UtteranceSynthesizer, fallback: (any UtteranceSynthesizer)?,
         output: any AudioOutputting, limits: TTSPlaybackLimits = .default, clock: any Clock<Duration> = ContinuousClock())
}
struct TTSPlaybackLimits { maxPending = 3; utteranceWatchdog = 30 s; breakerThreshold = 3; breakerCooldown = 30 s }
```

**Worker loop.** There is one `Task`, started on the first `speak` and finished by `deactivate`. It is woken by an internal signal stream. For each utterance:

1. Capture `gen`. If idle, emit `isSpeaking(true)`.
2. **Choose the synthesizer**:
   - the primary, if it `canSpeak` and the breaker is closed;
   - otherwise the fallback, if it `canSpeak`;
   - otherwise skip with `.noVoice`.
3. Run the attempt under the watchdog:
   - Iterate the stream, and on each buffer: `guard gen == generation`, then `output.schedule(buffer)` and `monitor?.process(buffer)`. Keep the last handle.
   - On a throw before the first buffer, record a breaker failure. If a fallback exists and `canSpeak`, emit `.fellBack(from:to:)` and run the attempt again with the fallback. Otherwise skip with `.primaryFailed`.
   - On a throw after the first buffer, skip with `.interrupted`.
   - When the stream finishes, record a breaker success (primary only) and `await lastHandle`.
4. Record metrics. If the queue is empty, emit `isSpeaking(false)`.

**`stopSpeaking()`:**
- `generation &+= 1`;
- clear the queue;
- cancel the current attempt's task, which cancels the stream iteration and so the producer;
- `output.stop()`;
- emit `isSpeaking(false)` if speaking.

**`deactivate()`:** `stopSpeaking()`, `output.shutdown()`, finish both streams, end the worker.

**Watchdog.** The attempt runs in a child task raced against `clock.sleep(for: utteranceWatchdog)`. On expiry the child is cancelled, the utterance is skipped with `.timeout` and `isSpeaking` follows step 4.

### 3.4 `EdgeTTSWebSocket` and `EdgeTransport`

```swift
protocol EdgeTransport: AnyObject, Sendable {
    var events: AsyncStream<WebSocketEvent> { get }   // per connection
    func connect(request: URLRequest)
    func write(string: String)
    func disconnect()
}
```

- Production wraps Starscream (`StarscreamTransport`). Tests use `FakeEdgeTransport`.
- `isConnected` is set by `.connected` and cleared by `.disconnected`, `.cancelled`, `.peerClosed` and `.error`. A connection whose event stream has finished counts as disconnected.
- `synthesize(text:voice:) -> AsyncThrowingStream<Data, Error>` yields audio chunks, finishes on `turn.end` and throws on close or error before `turn.end`.
- Timeouts (`EdgeTimeouts`, injectable): `connect` 5 s; the first audio chunk 5 s after the SSML is sent; the whole utterance 20 s.
- The reconnect-once rule lives in `EdgeUtteranceSynthesizer`. If the connection is not connected, or fails before the first chunk, it calls `disconnect()` + `connect()` once and retries. A second failure throws.
- One utterance at a time per socket is guaranteed by the playback worker.

### 3.5 `MLXInferenceGate`

```swift
actor MLXInferenceGate {
    static let shared = MLXInferenceGate()
    func run<T: Sendable>(wait: Duration = .seconds(2), inference: Duration,
                          _ work: @escaping @Sendable () async throws -> T) async throws -> T
}
```

- The gate holds a `busy` flag and a FIFO of waiters.
- **Acquiring:** if busy, the caller suspends as a waiter with a deadline. When the deadline passes, the caller is removed from the queue and gets `QwenCloneError.gateBusy`.
- **Running:** `work` runs in an unstructured `Task` that the gate owns, so cancelling the caller does not cancel MLX. The caller races that task's value against `inference`.
  - On timeout the caller gets `.inferenceTimeout`, but `busy` is only released when the owned task finishes. Its result is discarded.
  - On completion the gate releases `busy` and resumes the next waiter.
- `QwenCloneModelManager` keeps the client private. It exposes `func synthesize(text:referenceAudio:referenceTranscript:language:) async throws -> [Float]`, which goes through `MLXInferenceGate.shared`.
- `getInferrer` and `getInferrerSync` are removed. `QwenUtteranceSynthesizer` and `VoicePreviewService` take a `QwenCloneInferring` built on the manager's gated method. Tests inject a fake gate or fake inferrer.

### 3.6 `TTSEngineSelector`

- `makeOutgoingService` and `makeIncomingService` keep their priority logic.
- They now build `TTSPlaybackService(primary:fallback:output:)`:
  - `output = TTSOutput(deviceID:)`;
  - `fallback = AVSpeechUtteranceSynthesizer()` when the primary is not AVSpeech and `hasSystemVoice(locale)`.
- The existing factory closures used by tests are kept with the new types: `avSpeechFactory`, `kokoroFactory` and `voiceCloneFactory` now return synthesizers.

### 3.7 Coordinator and UI

- `handleOutgoingTranslation` loses `await outgoingTTS?.stopSpeaking()`.
- A notice line is shown under `TranscriptionView` in the main window:
  - The coordinator subscribes to `events` of each `TTSPlaybackService` it gets, through an optional `ttsEvents` accessor (the default `SynthesisService` extension returns nil).
  - It publishes `ttsNotice: String?`, which clears itself after 5 s.
  - The texts:

    | Event | Notice |
    |---|---|
    | `fellBack(edgeTTS, avSpeech)` | "Edge TTS unavailable — used system voice" |
    | `skipped(noVoice)` | "No voice for <lang> — sentence skipped" |
    | `skipped(timeout)` / `skipped(primaryFailed)` | "Speech failed — sentence skipped" |
    | `dropped` | "Speaking behind — skipped an older sentence" |

- `VoicePreviewSection` and `VoiceProfileDetailView` disable their preview buttons while `AudioViewModel.isCapturing || isStarting`, with a help text explaining why.

## 4. Error handling summary

| Situation | Result |
|-----------|--------|
| Edge network down or slow | Timeout (≤ 5 s before audio). The fallback speaks with `.fellBack`, or the utterance is skipped. |
| Edge connection closed while idle | Reconnect once, transparently. |
| 3 consecutive primary failures | 30 s of fallback-only, then the primary is retried. |
| Qwen inference > timeout | The caller falls back. The gate stays closed until MLX returns. |
| Qwen gate busy > 2 s | The caller falls back immediately (`.gateBusy`). |
| Preview during a session | Impossible from the UI; the gate also serialises it anyway. |
| Synthesizer hangs | Watchdog skip at 30 s with `.timeout`. |
| Output device lost | Restart on the same device. If that fails, utterances are skipped with `.outputUnavailable`. |
| `stopSpeaking` mid-anything | Immediate `isSpeaking(false)`. Nothing from the old generation plays. |
| Queue overflow | Oldest pending utterance dropped, with `.utteranceDropped`. |

## 5. Testing

### 5.1 Fakes (test target)

- **`FakeSynthesizer`** is scripted per call: a list of buffers with optional delays; a throw before or after N buffers; a stream that never finishes. It records calls and observes cancellation.
- **`FakeOutput`** records scheduled buffers. Each handle completes when the test calls `completeAll()` or `complete(n)`. It counts `stop()` and `shutdown()` calls.
- **`FakeEdgeTransport`** records written strings. The test pushes events: `.connected`, `.binary(header+audio)`, `.text("Path:turn.end")`, `.peerClosed`, `.error`.
- **`TestClock`** is a manual `Clock` with `advance(by:)`, used for the watchdog, the breaker and the Edge and gate timeouts. No fixed sleeps.

### 5.2 Unit tests (pinning)

| Behaviour | REQ |
|---|---|
| FIFO order; cap 3 drops the oldest + `.utteranceDropped`; empty text ignored | T-11, T-12 |
| Buffers scheduled before earlier ones complete; only the last is awaited | T-13 |
| `isSpeaking` true→false only after the last handle completes; no flicker across 2 queued utterances; immediate false on stop | T-14 |
| `stopSpeaking` during synthesis: buffers yielded afterwards are never scheduled; during playback: `output.stop` called | T-15 |
| Watchdog skips a never-ending stream with `.timeout` and isSpeaking returns to false | T-16 |
| The monitor receives every scheduled buffer | T-17 |
| Fallback before the first buffer → `.fellBack`; after the first buffer → `.interrupted`, no fallback call; no voice → `.noVoice` | T-20…22 |
| Breaker: 3 failures → fallback-only; after 30 s (TestClock) the primary is retried | T-23 |
| Edge: connection state from each closing event; reconnect once then throw; each timeout; `extractAudioData` header parsing; `deactivate` disconnects | T-24…27 |
| Gate: max concurrency 1 (counter in work); timeout returns to the caller while the next run waits for the first to finish; `.gateBusy` after the wait limit; the manager exposes no raw client | T-30…32 |
| Selector builds primary/fallback per priority; Edge/Kokoro/Qwen get the AVSpeech fallback only with a system voice | T-22 |
| Coordinator: outgoing does not call `stopSpeaking` before `speak`; TTS events → `ttsNotice` with auto-clear (TestClock or an injectable delay) | T-40, T-41 |

### 5.3 Integration tier

- **`TTSPlaybackIntegrationTests`**:
  - Setup: `TTSPlaybackService(primary: AVSpeech, output: TTSOutput(BlackHole))` speaks an English sentence. `AudioManager` captures from BlackHole with the F8.5.1 `BufferLog`.
  - Assertions:
    - audio arrives;
    - the last loud captured buffer comes before `isSpeaking` turns false, and the gap is ≤ 150 ms (NFR-T-02);
    - the total loud duration is ≥ 80 % of the utterance's expected length, so the tail is not cut (A12).
  - Requires BlackHole, the Microphone permission and an English system voice. All are `requirePrerequisite`; none skip.
- **`EdgeTTSIntegrationTests`**: real Edge "hello", en-US, yields > 0 PCM frames within 10 s. Missing network fails with "network access to Edge TTS (speech.platform.bing.com)".
- No real Kokoro or Qwen model is used in any automated tier.

### 5.4 Manual checklist (tasks.md)

| # | Check |
|---|---|
| M1 | Edge selected, then the network cut mid-call: the next sentence uses the system voice and a notice appears. When the network is back, Edge is used again within 30 s. |
| M2 | Voice clone active in a session: the preview is disabled. Outside a session, 10 rapid preview clicks cause no crash. |
| M3 | A long AVSpeech sentence is not truncated. |
| M4 | Outgoing sentences queue and are not cut, and at most 3 are pending. |
| M5 | A Kokoro English session works, and Stop mid-sentence plays nothing stale. |

### 5.5 Static analysis

- Promote `playernode-isplaying-poll`, `asyncstream-unbounded` and `asyncstream-force-unwrap` to ERROR (README updated).
- Zero `nonisolated-unsafe-justified` findings in `Core/TTS` and `Core/VoiceCloning`.

## 6. Risks

| Risk | Mitigation |
|------|------------|
| In-memory MP3 decoding is awkward with AVFoundation | Use `AudioFileStream` + `AVAudioConverter`, or fall back to a temp file (deleted) and record the choice. The decode is unit-tested with a small committed MP3 fixture captured from the integration run. |
| AVSpeech `write` end-of-utterance signalling varies by macOS version | Finish on the zero-length buffer, on `didFinish` or on `didCancel`, whichever comes first (idempotent finish). The integration test pins the tail. |
| Several `AVAudioEngine`s at once (outgoing TTSOutput, incoming TTSOutput, capture, TTS monitor, preview) | Already the case today. Each targets its own device. Never write HAL format properties. |
| Removing the four services breaks many existing tests | Migrate behaviour tests to the new suites in the same task that deletes each service. The unit-tier count must not drop without a mapping in the commit body. |
| The gate's unstructured task outlives app teardown | It only holds the client, and the process exit ends it. `unload()` waits for the gate to be idle before releasing the model. |
