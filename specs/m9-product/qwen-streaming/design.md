# M9 voice-clone streaming and early end-of-turn — Design

> Status: DRAFT (2026-10-31). Implements `requirements.md` (REQ-QS-xx).

## 1. Where the time goes today

```
end of speech ──VAD/STT/MT ~1.1 s──▶ TTSPlaybackService.speak
   └─ QwenUtteranceSynthesizer.synthesize
        └─ GatedQwenInferrer → QwenCloneModelManager.synthesize → MLXInferenceGate.run(inference: 10 s)
             └─ QwenCloneClient.synthesize → model.generate(...)    ← whole sentence: 5.3–7.9 s (31 s ref)
        └─ one AVAudioPCMBuffer → scheduled
```

After the change:

```
   └─ QwenUtteranceSynthesizer.synthesize                         (stream of buffers)
        └─ GatedQwenInferrer.synthesizeStream → QwenCloneModelManager.synthesizeStream
             └─ MLXInferenceGate.runStream(firstElement: 3 s)     (gate held until the model's stream ends)
                  └─ QwenCloneClient.synthesizeStream → model.generateStream(..., streamingInterval: 0.32)
        └─ one buffer per chunk, scheduled as it arrives            ← first chunk 0.84 s (31 s ref), ~0.33 s (5–10 s ref)
```

`TTSPlaybackService` already schedules every buffer as it arrives and only waits for the last one to play (`consume` / `drainPlayback`), so it needs no structural change.

## 2. File layout

| File | Change |
|---|---|
| `Core/VoiceCloning/QwenCloneConfiguration.swift` | `streamingInterval: Double = 0.32`, `firstChunkTimeoutSeconds: Double = 3`. `inferenceTimeoutSeconds` (10) stays, used only by the non-streaming path (preview). Reference-length constants (§7). |
| `Core/VoiceCloning/QwenCloneInferring.swift` | Adds `synthesizeStream(...) -> AsyncThrowingStream<[Float], Error>`. `synthesize` stays (preview). |
| `Core/VoiceCloning/QwenCloneClient.swift` | Implements `synthesizeStream` over `model.generateStream`. |
| `Core/VoiceCloning/MLXInferenceGate+Stream.swift` (new) | `runStream` (§3). Kept apart: `MLXInferenceGate.swift` holds the one-shot path. |
| `Core/VoiceCloning/QwenCloneModelManager.swift` | `synthesizeStream` through the gate; `GatedQwenInferrer.synthesizeStream`; optional warm-up (§8). |
| `Core/VoiceCloning/QwenUtteranceSynthesizer.swift` | Streams buffers; per-sentence stats and log line (§5). |
| `Core/VoiceCloning/GuidedReadingTexts.swift` (new) | The reading texts, one per supported language (§7). |
| `Core/VoiceCloning/VoiceProfileRecorder.swift` | Auto-stop limit as a parameter; quality grade by mode (§7.3). |
| `Core/VoiceCloning/VoiceProfileManager.swift` | Starts a guided or free recording; the guided text pre-fills the transcript. |
| `Features/VoiceCloning/VoiceRecordingView.swift`, `VoiceTranscriptView.swift` | Guided mode UI (§7.2). |
| `Features/Settings/VoicesSettingsView.swift` (or `VoiceProfileListView.swift`) | Long-voice hint (REQ-QS-15). |
| `TranslateCallTests/Mocks/MockQwenCloneInferrer.swift` | Scriptable chunk stream (delays, errors). |
| `TranslateCallTests/Integration/QwenCloneProbeTests.swift` | Committed, still gated by `TC_QWEN_PROBE=1`; extended for the measure-first gate (§9). |
| `Core/VAD/VADService.swift`, `SileroVADService.swift`, `EnergyVADService.swift` | Tentative segments and boundary events (§10.2). |
| `Core/STT/SpeechRecognizerService.swift` + the three engines | `segmentID` / `kind` passed through (§10.3). |
| `Core/Audio/TurnCommitter.swift` (new), `AudioCoordinator+Pipeline.swift` | Hold, commit, retract (§10.4). |
| `Core/Audio/ConversationSettings.swift` | Default pause 0.4 s, only in phase 4 (§10.5). |
| `TranslateCallTests/Bench/…` | Clone stats and gaps in the report (§6). Includes commit `db6c038` (bench builds in Release), not yet on main. |

## 3. The gate, streaming (REQ-QS-03, 06, 07, 08)

```swift
extension MLXInferenceGate {
    /// One streaming Qwen inference under the gate. The returned stream yields the model's elements
    /// while the caller listens; the gate stays closed until `work`'s stream has ended, whatever the caller does.
    nonisolated func runStream<Element: Sendable>(
        wait: Duration = .seconds(2),
        firstElement: Duration,
        _ work: @escaping @Sendable () -> AsyncThrowingStream<Element, Error>
    ) -> AsyncThrowingStream<Element, Error>
}
```

Behaviour:
1. The call returns a relay stream at once. A task acquires the gate with the existing `acquire(waitLimit:)` (2 s → `gateBusy`; cancelling the consumer while it waits removes the waiter, as today).
2. A **first-element timer** starts at the call, not at acquisition, so the gate wait counts toward the 3 s (REQ-QS-03 measures from "synthesis starting"). It fires `QwenCloneError.inferenceTimeout` into the relay if no element has been relayed. It is cancelled on the first element.
3. Once the gate is acquired, a **detached pump** calls `work()` and iterates the model stream **to its end**, always. While the relay is attached, it yields each element; once the relay is detached (consumer cancelled, timer fired, consumer finished), it keeps iterating and drops elements. When the model stream ends (normally or by error), the pump finishes the relay (if still attached) and calls `release()`.
4. Detaching is a one-shot flag under a `Mutex`, set by the relay's `onTermination`, the timer, or the pump's end, whichever comes first, like `GateDelivery`'s first-wins rule.
5. The gate exposes `isHeldByAbandonedStream` (true from detach until the pump's `release()`). `QwenCloneModelManager.synthesizeStream` checks it first and fails at once with `QwenCloneError.gateBusyAbandoned`. `TTSPlaybackService` gets that error as a failure with nothing heard, so it falls back; `perform` does not count it toward the breaker (REQ-QS-07a). An abandoned 200-character sentence can hold the gate ~5–8 s (≈12 s of audio at 1.5–1.8× real time), so waiting 2 s and then falling back anyway would only add delay.
6. `waitUntilIdle()` is unchanged: `busy` stays true until the pump's `release()`, so `unload()` never frees the client under a running generation (REQ-QS-08).

Why the pump drains: mlx-audio's `Qwen3TTSModel.generateStream` runs the generation in its own `Task` that is never cancelled and checks no cancellation (verified in mlx-audio-swift 0.1.2, `Qwen3TTS.swift:96-152`). The only reliable "the model is done" signal is the end of its stream. The generation is bounded by mlx-audio's own cap (`min(maxTokens, max(75, textTokens × 6))` codec tokens).

The one-shot `run` stays for the preview.

## 4. Client and manager

`QwenCloneClient.synthesizeStream` builds the same `GenerateParameters` as `synthesize`, calls `model.generateStream(text:voice:refAudio:refText:language:generationParameters:streamingInterval:)` and maps `.audio(chunk)` → `chunk.asArray(Float.self)` (empty chunks dropped). It ignores `.token`; `.info` (token count, tokens/s) is kept for the stats (§5) by passing it through as a side value. The builder chooses how: an enum element `QwenStreamEvent { case audio([Float]); case info(tokens: Int, tokensPerSecond: Double) }` is the suggestion, so the protocol method returns `AsyncThrowingStream<QwenStreamEvent, Error>`.

`QwenCloneModelManager.synthesizeStream` checks `.ready` (else a stream that fails at once with `modelNotReady`) and returns `gate.runStream(firstElement: .seconds(config.firstChunkTimeoutSeconds)) { inferrer.synthesizeStream(...) }`. Only `.audio` elements stop the first-element timer (an `.info` arrives at the end).

## 5. The synthesizer (REQ-QS-01, 04, 05, 22)

`QwenUtteranceSynthesizer.synthesize` keeps its shape (profile load, truncation, language) and then iterates `inferrer.synthesizeStream`:
- each `.audio` → `PCMBufferFactory.mono(..., sampleRate: inferrer.sampleRate)` → `continuation.yield`;
- end of stream with no audio at all → `QwenCloneError.emptyOutput` (fallback, as today);
- an error is passed through. `TTSPlaybackService.perform` already treats "failed with nothing heard" as a fallback and "failed after audio" as interrupted, and opens the breaker only for the former (REQ-QS-05 needs no service change);
- `onTermination` cancels the producer, which drops the relay; the gate keeps draining (§3).

Per-sentence stats, logged once at the end (`category: QwenUtteranceSynthesizer`, `.public` numbers, no text): time to first chunk, total time, audio seconds, tokens/s, gap count and gap seconds. **Gap rule:** with `t₀` the first chunk's arrival, keep `playEnd` (when the audio yielded so far would finish playing if played back to back from `t₀`). A chunk arriving at `t > playEnd` is a gap of `t − playEnd`; then `playEnd = t + chunkSeconds`, else `playEnd += chunkSeconds`. It ignores the output's own scheduling latency, so it slightly under-counts. That is acceptable for a ≤ 5 % budget.

Stats are also offered to tests and the bench through an optional `statsObserver: (@Sendable (QwenSentenceStats) -> Void)?` init parameter (nil in the app).

## 6. Bench (REQ-QS-20, 21)

- Best local must actually speak with the clone (UI-S3). With the stream, the 10 s whole-inference timeout that forced the fallback is gone on this path. The runner already names the voice profile; it adds the profile's reference length (`header.durationSeconds`).
- `BenchPipelineFactory` passes a `statsObserver` to the clone synthesizer. The report adds, per profile/direction, the clone's time to first chunk (p50/p90), sentences with gaps (count and %) and the total gap time. They are informative (not gated by `bench-compare`); NFR-QS-01/02 are checked by reading the report.
- Gated totals: unchanged rules. The first run after this change becomes the new Best local baseline (`just bench-baseline`, with the reason).

## 7. Short reference (FR-QS.2)

### 7.1 Texts

`GuidedReadingTexts.text(for language: String) -> String`, keyed like `QwenCloneConfiguration.supportedLanguageList` ("spanish", …). One text per language, natural and neutral, with the target length (default ~8 s at a calm pace: ~20–24 words for es/en/fr/de/it/pt/ru, ~40–50 characters for zh/ja/ko). Phonetically varied, no numbers, abbreviations or names that people read differently. The text **is** the transcript, so it must be exactly what is shown.

### 7.2 Flow

The "new voice" flow starts on a choice: **"Read a short text (recommended)"** or **"Use my own text"** (today's flow, unchanged).

Guided:
1. Language picker (the 10 Qwen languages), defaulting to the language the user speaks in the current pair if supported, else English. The text is shown large while recording.
2. Recording auto-stops at `guidedMaxSeconds` (15 s); the user can stop earlier.
3. The review screen pre-fills the transcript with the text (editable, REQ-QS-11), name as today.

### 7.3 Recorder

- The 30 s auto-stop becomes a parameter: `freeMaxSeconds = 30`, `guidedMaxSeconds = 15`.
- Quality grade by mode. Free mode keeps today's thresholds (`< 8 s` voiced → poor, `< 20 s` → fair). Guided mode: poor if voiced `< 0.6 × targetSeconds` (the user stopped early or mostly silence), clipping or peak `< −30 dBFS`; fair if peak `< −20 dBFS`; else good. Today's rule would grade every short recording "fair" or "poor" and push users back to long ones.
- The save block in `VoiceTranscriptView` (`isQualityBlocked`: poor and voiced < 8 s) uses the mode's thresholds: guided → poor and voiced < `0.6 × targetSeconds` (REQ-QS-16).
- Silence trimming: leading and trailing silence above 0.3 s is cut before saving, if the recorder does not already do it (check). Silence costs prompt length and so latency.

### 7.4 Long-voice hint (REQ-QS-15)

In the voice's row in Settings › Voices: when `header.durationSeconds > 12`, a secondary line "Long sample: a short recording answers faster" with "Record short sample", which opens the guided flow. The result is saved as a new voice through the existing `save` and made active (`VoiceProfileManager.activeProfileId`); the long voice stays in the list. No store API change. The threshold sits in `QwenCloneConfiguration.longReferenceSeconds = 12`.

## 8. Warm-up (REQ-QS-31)

Only if the gate (§9) shows cold first chunk > 1.5× warm. Then `QwenCloneModelManager.warmUp()` runs one streaming inference with the active profile and a one-word text, drained and discarded, through the gate, right after a session's preload of the clone model. Where to call it is left to the builder, next to the existing warm-up at Start (F8.5.4).

## 9. Measure-first gate (REQ-QS-30)

Before §7 is built:
1. The user records three clips with any recorder (QuickTime or the `rec` command), ~5, ~8 and ~10 s long, in the same room and microphone as the 31 s voice, each reading a draft guided text (Spanish) that Claude supplies. They go into `build/qwen-probe/refs/` as `<seconds>s.wav` + `<seconds>s.txt` (the text read). Today's app cannot save a voice under 8 s voiced (`VoiceTranscriptView.isQualityBlocked`), so the gate does not go through the app and no UI is built before it. The 31 s voice (active profile) is the fourth.
2. The probe (env `TC_QWEN_PROBE=1`) loads the clips (resampled to 24 kHz mono) runs in Release (`build-for-testing` path, as the bench). For each reference it runs 2 Spanish + 2 English sentences, cold and warm. It records first chunk, total, audio seconds and tokens/s, and writes each output as a WAV into `build/qwen-probe/<run>/<seconds>s/`, plus a `summary.md` table.
3. The user listens and picks the shortest length that still sounds like them. The pick sets `GuidedReadingTexts`' target and `guidedMaxSeconds`. If none under 31 s works: stop and present options (keep long voices + streaming only, ~2 s; or another approach).

## 10. Early processing at the end of a turn (FR-QS.5)

### 10.1 Where the time goes

Measured p50 VAD stage 750–940 ms = the 0.6 s pause + up to one 256 ms Silero chunk (FluidAudio's `VadManager.chunkSize` is fixed at 4 096 samples; not tunable). STT 190–250 ms and translation 310–480 ms only start after it. Early processing overlaps them with the pause: in the best case it takes ~0.3 s off, with no change to when an utterance counts as finished.

### 10.2 Segment protocol

`SpeechSegment` gains `id: UInt64` (per VAD instance, increasing) and `kind: .tentative | .final`. The VAD also offers `nonisolated var boundaryEvents: AsyncStream<SegmentBoundary>` with `.commit(id)` and `.retract(id)`.

- **Silero** (`SileroVADService.processChunk`): when triggered and a chunk's probability (`VadStreamResult.probability`) is below the threshold for the first time since the last speech chunk, emit `.tentative` with `utteranceBuffer` so far. On FluidAudio's `.speechEnd`, emit `.commit(id)` for the open tentative instead of a new segment (the silent tail adds no words). If no tentative is open (edge case), emit `.final` as today. A speech chunk while a tentative is open → `.retract(id)`.
- **Energy**: same, with the tentative after `tentativeSilence = 0.2 s` of silence (its granularity is finer).
- **Force-emit** at `maxSpeechDuration` and flush on deactivate: `.final`, as today. An open tentative is retracted first.

The trigger "first silent chunk" is where a semantic turn model would later decide to commit early or hold (Q-7).

### 10.3 STT

`SpeechRecognizerService.activate(stream:)` is unchanged in shape. Each engine recognises every segment, tentative or final, as today. `TranscriptionResult` gains `segmentID` and `kind`. Retracted work is not cancelled inside the engines: a tentative is short and the result is dropped downstream. That keeps the three engines untouched apart from passing the two fields through.

### 10.4 Coordinator

A small `TurnCommitter` (new, `Core/Audio/TurnCommitter.swift`, unit-tested on its own; the `+Pipeline` file is at 398/400 lines), one per direction:
- input: transcription results and boundary events;
- `.final` result → today's path (translate, show, speak);
- `.tentative` result → translate at once and hold `(id, text, translation task)`;
- `.commit(id)` → when the held translation is ready, run today's show + speak with it (mute-turn, pause and `isPaused` checks apply at commit, not at tentative);
- `.retract(id)` → cancel/discard the held entry;
- ordering: a commit may arrive before the transcription or the translation; the committer keeps per-id state and releases in id order, so sentences are never spoken out of order.

The `handleOutgoingTranslation` / `handleIncomingTranslation` bodies split into "translate" and "show and speak" so the committer can call the halves.

### 10.5 Shorter default pause (REQ-QS-46)

`ConversationSettings.defaultPauseSeconds` 0.6 → 0.4, only if the bench says so after §10.2–10.4. A saved value is kept (`pauseSecondsKey` present → used).

### 10.6 Bench

The bench drives the real VAD and coordinator path, so totals reflect early processing without changes. It adds the retract share and end-of-speech → commit time (REQ-QS-23) from the boundary events, through the existing tracing decorators (`Core/Trace/TracingDecorators.swift`).

## 11. Phases

1. **Clone streaming** (§3–6). Bench Best local with the 31 s voice: clone speaks, ~2.3 s.
2. **Measure-first gate** (§9), then **short reference** (§7, §8).
3. **Early processing** (§10.1–10.4, 10.6). Bench Basic + Best.
4. **Shorter pause**, if needed (§10.5). Full bench run for acceptance.

Each phase ends green under `just pr` and is reviewed before the next; one PR for the feature (spec + code), per the workflow.

## 12. Testing

Unit (Swift Testing, test clock as in `MLXInferenceGateTests`):
- gate stream: elements relayed in order; `gateBusy` after the wait limit; first-element timeout (gate wait included) → `inferenceTimeout` while the gate stays busy until the inner stream ends; consumer cancel mid-stream → no more elements, gate busy until inner end, then idle; inner error → relayed, gate released; `waitUntilIdle` waits for a detached pump; a second `runStream` waits its turn; one-shot `run` and `runStream` exclude each other.
- synthesizer: one buffer per chunk at the inferrer's rate; empty chunks skipped; no audio → `emptyOutput`; error before/after the first chunk; cancel stops yielding; gap rule (table-driven with a scripted mock).
- playback service: a clone stream that never yields within 3 s → fallback event and AVSpeech audio; a stream that fails after one buffer → interrupted, no fallback, no breaker count.
- recorder grade by mode; guided text pre-fills the transcript; long-voice hint shown at > 12 s only; every supported language has a guided text.

- VAD: tentative at the first silent chunk; commit on pause; retract on resumed speech; force-emit and flush retract an open tentative; ids increase (Silero with scripted probabilities, Energy with synthetic audio).
- TurnCommitter: commit before/after the translation finishes; retract while translating (nothing shown or spoken); out-of-order completion spoken in id order; mute turn and pause applied at commit; final segments unchanged.

Integration and bench: the probe (gated); `just pr` (Basic gated); a Best local run with the short voice for NFR-QS-01/02.

Manual checklist (user): see requirements "Acceptance".

## 13. Risks

| Risk | Mitigation |
|---|---|
| A stopped or timed-out sentence keeps the gate until its generation ends (up to ~5–8 s for a 200-character sentence). Sentences in that window are spoken by the fallback voice. | REQ-QS-07a: they fall back at once, not after 2 s, and do not trip the breaker. Rare (stop, first-chunk timeout). Logged. A proper fix needs cancellable generation in mlx-audio (upstream PR, out of scope). |
| Streaming decoder starts without reference context: the first chunk may sound off. | Judged by ear in the gate and the manual checklist (NFR-QS-04). |
| Short reference carries less of the voice. | Gate §9: the user picks the length by ear. |
| Release generation is only ~1.5–1.8× real time: a busy Mac (another MLX model, video call CPU) could make gaps. | Gap metric in bench and log; `streamingInterval` is configurable. During a session only one MLX model is loaded (S-7). |
| Debug builds stay below real time → gaps or timeouts in Debug manual tests. | Manual tests and bench in Release. |
| Early processing doubles STT/translation work when users hesitate (retracts). | Apple Translation and STT are cheap per sentence; the retract share is reported (REQ-QS-23). Whisper is the heaviest; watch its numbers. |
| Committing a tentative whose recognition missed the last word (audio cut at the first silent chunk). | The tentative holds all audio up to the first silent chunk; the remaining pause is silence by definition. Checked by WER/cut rate (NFR-QS-05). |
| Guided texts in 10 languages need native-quality wording. | Builder writes them; zh/ja/ko/ru reviewed with an MT back-translation check; the user checks es/en. |

## 14. Claude's calls (not confirmed by the user — check while reading)

1. The short reference comes from a **new guided recording** (read a shown text). Existing recordings are not trimmed automatically; long voices get a hint.
2. Planning defaults **~8 s / 15 s auto-stop**, fixed by the gate.
3. The **3 s** first-chunk limit includes the up-to-2 s gate wait.
4. Gate measurement uses short audio files recorded outside the app (today's app refuses voices under 8 s), so no UI is built before the gate.
5. The probe is **committed** (still opt-in) instead of deleted.
6. NFR p90 **< 2.0 s** and gaps **≤ 5 %**; clone stats informative in the bench, not gated.
7. Long-voice hint threshold **12 s**; guided-mode quality thresholds as in §7.3.
8. Guided text language defaults to the language the user speaks in the current pair.
9. `db6c038` (bench in Release) ships inside this feature's PR.
10. While an abandoned generation holds the gate, new clone sentences fall back at once and do not count toward the breaker (REQ-QS-07a).
11. "Record short sample" on a long voice creates a new voice and makes it active; the long one is kept.
12. The 200-character clone limit (`textTruncationLimit`) stays: the playback service already never coalesces past it (`maxTextLength`), so only a single sentence longer than 200 characters is cut, as today.
13. Early processing: tentative at the first silent Silero chunk (Energy: 0.2 s); commit reuses the tentative's text; the STT engines do not cancel retracted work; transcript shows a sentence only at commit.
14. A new `TurnCommitter` type per direction, so the 398-line pipeline file does not grow.