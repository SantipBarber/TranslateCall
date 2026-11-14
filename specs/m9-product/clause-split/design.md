# M9 clause split and look-ahead synthesis — Design

> Status: APPROVED (2026-11-13). Requirements: `requirements.md` in this folder.

## 1. Where the time goes

Bench Best 2026-11-13, en>es, p50 ms: vad 399 · stt 141 · translate 532 · first audio 285 = total 1359. Translation starts at the tentative result (FR-QS.5), but the commit comes before it ends, so the stages run one after the other and every millisecond cut from translation is heard. Apple Translation ≈ 187 ms + 17.8 ms/word. Translating the first clause instead of the whole sentence saves ~250–290 ms on split sentences (42–55 % of the bench).

The second part's translation has time: it is queued in the bridge right after the first (FIFO, `TranslationBridgeModel`), so it is ready ~350–450 ms after the first, while the first part (≥ 5 words, ≥ ~1.5 s of audio) is still playing.

Its audio does not, today: `TTSPlaybackService` runs one utterance at a time and starts synthesizing the next only after the last buffer of the current one has played, which leaves ~285 ms of silence (the next first-audio latency) between the parts — and between any two queued sentences. Look-ahead synthesis (§7a, user's choice CS-5) removes it: Qwen streams at RTF ~0.45–0.6, so an utterance's synthesis ends well before its audio does, and the MLX gate is free from that moment; the next utterance's first chunk (~285 ms) is then scheduled while ~40 % of the current audio is still to play.

## 2. File layout

| File | Change |
|------|--------|
| `Core/Translation/ClauseSplitter.swift` (new) | Pure function: `split(_ text: String) -> [String]` (1 or 2 parts), REQ-CS-01…04. |
| `Core/Translation/SentenceTranslation.swift` (new) | The parts of one sentence and their translation tasks (§3). |
| `Core/Audio/TurnCommitter.swift` | Holds a `SentenceTranslation` instead of `Task<String, Error>` (§4). |
| `Core/Audio/AudioCoordinator+Committer.swift` | Builds it with the splitter (if on). |
| `Core/Audio/AudioCoordinator+Translation.swift` | `deliverOutgoing` / `deliverIncoming` speak part by part (§5). |
| `Core/Audio/AudioCoordinator+Session.swift` | Transcript: partial translation, then the whole; partly skipped (§6). |
| `Core/Audio/ConversationSettings.swift` | `clauseSplit` setting (§8). |
| `Core/Trace/PipelineTracer.swift`, `TraceEvent.swift`, `TracingDecorators.swift` | Parts in the trace, handoff gap (§7). |
| `Core/TTS/TTSPlaybackService.swift`, `TTSPlaybackService+Attempt.swift` | Look-ahead: synthesis and playback drain split (§7a). |
| `TranslateCallTests/Bench/BenchRunner.swift`, `tools/scripts/bench.sh`, `justfile`, `tools/bench/tcbench/analyze.py` | Bench switch and the full text for quality (§7). |

## 3. `SentenceTranslation`

```swift
/// One sentence's translation, in one or two parts (FR-CS.2). The parts are sent to the
/// translator at once, first part first; the bridge serves them in order.
@MainActor
final class SentenceTranslation {
    let source: String                     // the whole sentence
    let parts: [String]                    // source parts, 1 or 2
    let tasks: [Task<String, Error>]       // one per part, started in order
    func cancel()                          // cancels every task
}
```

Built by one factory used by both the committer (tentative) and delivery (final):
`makeTranslation(_ text: String, translate: (String) async throws -> String) -> SentenceTranslation`. With the split off, or a sentence the splitter does not cut, it holds one part: the delivery code then behaves exactly as today. Starting the tasks in order is enough for the bridge to receive them in order (they are created back to back on the main actor; the bridge enqueues in arrival order). The builder confirms that on `TranslationBridgeModel` and, if arrival order is not guaranteed, chains the second task after the first one is enqueued.

## 4. `TurnCommitter`

`Entry.translation` and `inFlight` become `SentenceTranslation?`; `cancel()` replaces `Task.cancel()`. The `Translate` closure stays per text; the committer calls the factory with it. The `Deliver` signature becomes `(String, SentenceTranslation?)`. Nothing else in the committer changes: ordering, retracts and the head-of-line rules are per sentence, as today.

## 5. Delivery

`deliverOutgoing` (incoming is the same, with the self-echo guard):

1. Guards on the whole sentence, unchanged (empty, Pause, mute turn, echo); on drop, `translation?.cancel()` (REQ-CS-13).
2. `let sentence = translation ?? makeTranslation(text, …)`; append the transcript entry; translating flag on, with the session-generation `defer` (UI-B2) — it now covers all parts (REQ-CS-18).
3. For each part `i`, in order:
   - await its task (with the cancellation handler that cancels the whole `sentence`), then `try Task.checkCancellation()`;
   - add it to the joined translation; update the live caption and the transcript entry (§6);
   - if paused: stop speaking parts (the rest is still awaited and shown, REQ-CS-14);
   - otherwise (incoming: `selfEchoGuard.played(part)`), `speak(part)`, then the UI-B1 guard.
4. Errors: a failure on part 0 → today's path (`skipTranscript`, `handleTranslationFailure`, cancel the rest). A failure on part 1 → keep what was spoken, mark the entry partly skipped, `handleTranslationFailure` (notice), REQ-CS-16. A `CancellationError` stays silent, as today.
5. Incoming, after the last part: `selfEchoGuard.played(joined)` too, so an echo the STT hears as one sentence is still caught (REQ-CS-17).

The two parts are two `speak` calls. `TTSPlaybackService` plays them one after the other; if more sentences queue meanwhile, it may coalesce the second part with them, which is fine (the coalescing limit still applies).

## 6. Transcript

`completeTranscript(id, translation:)` may be called twice for one entry: once with the first part, once with the joined text. The view already re-renders on change. A new `partlySkipped` flag (or reuse of `skipped` with the partial translation kept — the builder picks what fits the view model) shows that the end of the sentence was not translated (REQ-CS-16).

## 7. Trace and bench

- `TracingTranslationService.translate` sees parts, whose text does not match the utterance's STT text, so `PipelineTracer.translated(source:result:)` would miss them. The coordinator knows the sentence: the decorator stays as it is for unsplit sentences, and split sentences are reported by the coordinator side through a new tracer call, e.g. `translatedPart(sentence: String, index: Int, count: Int, result: String)` (the builder chooses whether the coordinator calls the tracer directly or the `SentenceTranslation` factory does it through an optional hook; the decorator must not report a part as a whole).
  - Part 0 → `translated` event, detail `parts: "2"`, text = part 0's translation (REQ-CS-30).
  - Last part → new event `translatedAll`, text = the joined translation (REQ-CS-31). Unsplit sentences: no `translatedAll` (analysis falls back to `translated`).
- `speakRequested` and `synthesisStarted` match utterances by their translation text. They must match a part of a split utterance: store the parts' translations per utterance and match the spoken text against the next unspoken part. `ttsFirstBuffer` is set by the first part's first buffer (REQ-CS-32); the second part's attempt must not create a second utterance nor drop it as `tts-no-audio`.
- A split utterance stays open in the tracer until its last part ends: `ttsEnd` is the end of the last spoken part, not of part 0. A part's attempt is matched only against its own utterance's next part, never through the "oldest waiting" fallback of `synthesisStarted` (it would stamp the next sentence's `ttsFirstBuffer` with the wrong time). If part 1 is not spoken (Pause) or fails, the utterance ends at part 0's `ttsEnd`, with detail `partsSpoken: "1"` (Claude's call).
- Second part's first audio: new event `ttsPartBuffer` (detail `part: "1"`, `handoffGapMs`) on the same utterance, since its `ttsFirstBuffer` was already emitted by part 0. Handoff gap: see §7a; reported per line. A report value with its own acceptance gate (REQ-CS-40), not in `compare`.
- `analyze.py`: quality uses `translatedAll.text` when present, else `translated.text`. The `translate` stage stays `translated − sttFinal`. Add `translateAll = translatedAll − sttFinal` to the per-utterance detail for diagnosis (not a gate).
- Bench switch: env `TC_CLAUSE_SPLIT` (`1` default, `0` off), parsed in `BenchEnvironment.parse`, applied to the session's settings, written to run metadata; `just bench` gets a `split="1"` parameter passed through `bench.sh`.

## 7a. Look-ahead synthesis (FR-CS.5)

Today `play(_:)` = `perform` (synthesis attempt, with fallback) **then** `conclude` (wait for the last buffer to play, `drainPlayback`), and the worker loops on that. The change splits the two:

- **Synthesis stays serial in the worker.** The worker takes the next utterance (coalescing as today), runs the attempt(s) exactly as today, and when the attempt's stream has ended hands the utterance to a **drain** step instead of awaiting it. It then takes the next utterance at once — but only if no other utterance is already waiting to drain behind the one playing (REQ-CS-51: one ahead). Otherwise it waits for the playing one's drain to end.
- **Drain** = today's `conclude` for that utterance: wait for its last handle (bounded by its audio length + grace), then outcome, skip event, metrics. Drains run in order, one per utterance, in a small task chained to the previous drain (so outcomes are reported in order).
- **Per-attempt state** (`attemptStartedAt`, `attemptFirstBufferAt`, `attemptBufferCount`, `attemptAudioSeconds`, `attemptLastHandle`, `attemptCountsTowardBreaker`) moves into a value the attempt returns, because two utterances are now alive (one draining, one synthesizing). `conclude` takes that value.
- **Fallback**: unchanged inside `perform`; a primary failure with no audio on the utterance ahead falls back while the current one keeps playing (the output plays buffers in schedule order).
- **Stop**: `generation` bump, `queue.removeAll()`, cancel the attempt, `output.stop()` — as today; the drains see `.stopped`/stale and report nothing (REQ-CS-53).
- **Output failure/stall** during a drain: `output.stop()` also discards the buffers of the utterance ahead; it is reported `outputUnavailable` and its attempt cancelled (REQ-CS-54). The builder picks the mechanism (e.g. bump a local epoch shared by the two).
- **`isSpeaking`**: `setSpeaking(false)` only when the queue is empty, no attempt runs and the last drain has ended (REQ-CS-55).
- **Handoff gap** (REQ-CS-56): the service keeps `scheduledAudioEnd` (the instant the audio scheduled so far finishes: `max(now, scheduledAudioEnd) + buffer seconds` at each schedule). When an utterance's first buffer is scheduled while a previous utterance is still draining, gap = `max(0, now − scheduledAudioEnd)` before the update. It is reported to the tracer with the first buffer (`bufferScheduled(handoffGap:)` or the `bufferObserver` path — builder's choice) and lands as `handoffGapMs` on `ttsFirstBuffer` (whole utterances) or `ttsPartBuffer` (second parts, §7); `analyze.py` reports its p50/p90 per line for the second parts of split sentences (and, informative, for all handoffs).
- **Tracer**: its attempt model is about synthesis (`synthesisStarted` … `synthesisFinished`), which stays serial, so one attempt at a time still holds. `ttsEnd` stays "synthesis finished with audio scheduled".
- **Voice preview** (Settings › Voices) does not use `TTSPlaybackService`: unaffected.

## 8. Setting

`ConversationSettings.clauseSplit: Bool`, key `conversation.clauseSplit`, default `true`, read at session start (like `pauseSeconds`) and passed to the coordinator. No control in Settings in this feature (Claude's call, §11): it is a measurement switch; it can be changed with `defaults write` and gets a toggle later if the user wants one.

## 9. Testing

- `ClauseSplitterTests` (pure): thresholds at the edges (11/12 words, 4/5 before, 3/4 after), first eligible mark wins, `;` and `:`, marks inside tokens (`3,5`, `10:30`, `http://x`), round trip of REQ-CS-02, no split with the setting off.
- Coordinator tests with the existing mocks (`MockTranslationService` held calls, `MockSynthesisService` hold): part 0 spoken while part 1 is held; order of the two `speak` calls; Pause between parts (part 1 shown, not spoken); stop between parts (nothing more spoken, flag rules of UI-B2); part 1 failure (part 0 stays, notice, entry partly skipped); part 0 failure (nothing spoken, part 1 cancelled); mute turn and echo guard on a split sentence (both translations cancelled); incoming echo registration; tentative path through the committer (translation started at the tentative, both parts).
- `TTSPlaybackServiceTests` (look-ahead): the next utterance starts synthesizing when the current stream ends, not when it finishes playing; at most one ahead (a third queued sentence waits and coalesces); stop with one playing and one ahead (both gone, `isSpeaking` false at once); output stall with one ahead (both skipped); fallback on the one ahead; `isSpeaking` stays true across the handoff; handoff gap 0 when in time and > 0 when late.
- `PipelineTracerTests`: a split utterance gets one `translated` (part 0), one `translatedAll`, one `ttsFirstBuffer`, and is not dropped when its second part is synthesised.
- `analyze.py` tests (pytest): quality uses `translatedAll`.
- Acceptance: REQ-CS-40, two back-to-back `just bench full best` runs (split on, then off), peers warned before and after.

## 10. Risks

- **Prosody**: the voice clone says each part as a whole sentence, so the first part may end with a falling tone at the comma. Listen to a few bench WAVs of split sentences; if it sounds wrong, the fallback is to keep the split for translation only and to speak both parts as one call when the second is ready in time (would lose most of the gain: noted, not designed).
- **Clause order between languages**: a comma clause translated alone loses context (e.g. a subordinate clause before the main one). The measured chrF++ loss (−1.1 / −1.8) includes it; REQ-CS-40 guards it.
- **Look-ahead touches the TTS core** that every scenario relies on (echo gate timing via `isSpeaking`, Pause, fallback, breaker). Mitigation: per-rule unit tests on `TTSPlaybackService` with `TestClock` and the fake output, `just scenario all` and the full Best bench as acceptance (REQ-CS-40).
- **Silence left between the parts**: if part 1's translation is late (short first part) or the synthesis is slower than real time (fallback engines, Edge over the network), a gap remains. The handoff gap measures it; acceptance sets p50 ≤ 50 ms, p90 ≤ 150 ms for the clone.
- **Bigger output queue**: up to one extra utterance of audio is scheduled ahead, so `stopSpeaking` discards more; it already stops at once.

## 11. Claude's calls (not confirmed by the user — check while reading)

1. At most one cut, at the first eligible mark (the measured rule); no recursion.
2. No toggle in Settings; only the stored setting and the bench switch.
3. If the second part fails, the first part stays spoken, and the entry shows it as partly skipped.
4. The translating indicator stays on until the last part.
5. The incoming self-echo guard gets each part and the joined text.
6. The trace marks `translated` at the first part (latency) and adds `translatedAll` for quality.
7. A split utterance stays open in the trace until its last part; if part 1 is not spoken it ends at part 0 with `partsSpoken: "1"`.
8. The transcript and live caption show the first part's translation as soon as it is ready, with no "more coming" mark (the second part follows within ~0.5 s).
9. Acceptance compares one run with the split on and one with it off (a full Best run takes ~3 h); no repeat runs for noise. Look-ahead is on in both runs (no switch for it).
10. Look-ahead has no setting: it is always on, for every engine.
11. Handoff gap gate: p50 ≤ 50 ms, p90 ≤ 150 ms (voice clone, second parts of split sentences).
