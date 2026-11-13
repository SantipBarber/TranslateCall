# M9 clause split and look-ahead synthesis — Requirements

> Status: APPROVED (2026-11-13).
> Inputs: backlog QS-5, bench run `build/bench/runs/2026-11-13T07-59-07Z-670b3ba`, the offline probe of 2026-11-13 (memory `qs5-latency-bench-2026-11-13`).

## Overview

The Best profile meets the 1.5 s gate with little margin (en>es p50 1359 ms, p90 1581 ms, run 2026-11-13). The stages add up to the total (vad 399 + stt 141 + translate 532 + first audio 285 = 1357 ms), so translation sits on the critical path, and it is the largest stage.

Measured on 2026-11-13:
- The translation bridge adds nothing: a direct `TranslationSession` call on the 200 bench sentences returns the same text 200/200 and is not faster (548 vs 510 ms p50). Apple Translation costs about **187 ms + 17.8 ms per word** (en>es). Sentences of 30+ words take ~820 ms; they make the p90.
- Splitting sentences of ≥ 12 words at the first `,` `;` `:` (≥ 5 words before, ≥ 4 after) splits 42 % (en>es) and 55 % (es>en) of the bench sentences. The first part is translated **256 ms (en>es) and 286 ms (es>en) sooner** (p50 358 vs 614 ms). chrF++ of the joined parts: 64.9 → 63.8 (en>es), 63.7 → 61.9 (es>en).

The goal: the other side starts hearing a long sentence ~250–290 ms sooner. The first part is translated and spoken while the rest is still being translated.

## Decisions taken (2026-11-13)

| ID | Decision |
|----|----------|
| CS-1 | Split when the sentence is delivered (approach A): the translation hands its parts over one by one, and each part is spoken as soon as it is translated. The transcript keeps one entry per sentence. Not in the translation service (B, which returns one text), and not in the voice detector (C, which changes recognition and cuts sentences). The user: "Adelante". |
| CS-2 | Split rule = the one measured offline: `,` `;` `:`, sentence ≥ 12 words, ≥ 5 words before the cut, ≥ 4 after. |
| CS-3 | Both directions, every profile (translation is the same in all of them). |
| CS-4 | A setting turns it off; the bench uses it to measure with and without. |
| CS-5 | **Look-ahead synthesis ships in this feature** (user: "B, hay que arriesgar"). Today the TTS synthesizes the next utterance only after the current one has finished playing, so the two parts would be ~285 ms apart (the next first-audio latency). The next utterance is synthesized while the current one is still playing, so its audio follows without a gap. It applies to every utterance, not only to split parts, and to every engine. |

## Functional Requirements

### FR-CS.1 — Splitting

**REQ-CS-01**: A sentence SHALL be split in two at the first `,` `;` or `:` that leaves at least **5 words** before it and at least **4 words** after it, when the sentence has at least **12 words**. Otherwise it SHALL be translated whole, as today.

**REQ-CS-02**: The punctuation mark SHALL stay at the end of the first part. Joining the two source parts with one space SHALL give back the original sentence (whitespace normalised).

**REQ-CS-03**: A sentence SHALL be split at most once (two parts).

**REQ-CS-04**: Words SHALL be counted as whitespace-separated tokens. A mark inside a token (`3,5`, `10:30`, a URL) SHALL NOT split: only a mark at the end of a token counts.

### FR-CS.2 — Translating and speaking the parts

**REQ-CS-10**: Both parts SHALL be sent to translation together, the first part first, as soon as the sentence would be translated today: at the tentative result (early processing, FR-QS.5) or at delivery for a final result.

**REQ-CS-11**: When the sentence is delivered, the first part SHALL be spoken as soon as its translation is ready, without waiting for the second. The second part SHALL be spoken when its translation is ready and the first has been handed to TTS.

**REQ-CS-12**: The transcript SHALL show one entry per sentence: the whole original text, and the translation of the parts joined with one space. The translation MAY appear in two steps (first part, then the whole).

**REQ-CS-13**: Every check that applies to a sentence today SHALL apply to the whole sentence once, before anything is translated or spoken: empty text, Pause (REQ-UI-50), mute turn, echo of their translation (Q6). A dropped sentence SHALL cancel both translations.

**REQ-CS-14**: If Pause comes after the first part was handed to TTS, the second part SHALL be shown but not spoken (today's rule for a sentence paused while translating). The UI-B1 guard (stop the TTS if Pause landed during `speak`) SHALL apply to each part.

**REQ-CS-15**: Stop, a retract, or teardown SHALL cancel both translations; nothing of the sentence SHALL be spoken afterwards (today's rules, for both parts).

**REQ-CS-16**: If the first part's translation fails, the sentence SHALL be skipped as today (notice, nothing spoken, the second translation cancelled). If only the second part fails, the first part SHALL stay spoken and shown; the transcript entry SHALL show the first part's translation and be marked as partly skipped. The usual notice SHALL be shown.

**REQ-CS-17**: The incoming direction SHALL hand every spoken part to the self-echo guard (Q6). An echo of the whole translation SHALL still be recognised as one.

**REQ-CS-18**: The "Translating" indicator SHALL stay on until the last part of the sentence is translated (or the sentence is dropped).

### FR-CS.5 — Look-ahead synthesis (TTSPlaybackService)

**REQ-CS-50**: When an utterance's synthesis has finished (its stream ended) and its audio is still playing, `TTSPlaybackService` SHALL start synthesizing the next queued utterance at once, scheduling its buffers on the output behind the current audio. An utterance that arrives while the current one is still playing SHALL start at once in the same way.

**REQ-CS-51**: At most **one** utterance SHALL be synthesizing at a time (process-wide MLX rule, REQ-QS-06, unchanged), and at most one utterance SHALL be synthesized ahead of the one playing. While one is playing and another synthesized ahead, later sentences wait in the queue and are coalesced as today (REQ-Q-02).

**REQ-CS-52**: Each utterance SHALL keep today's outcome rules: its own watchdog on synthesis, its own wait for its last buffer (bounded by its audio length + `playbackGrace`), its own skip event, metrics and fallback. A failure of the utterance ahead with no audio SHALL fall back as today, while the current one keeps playing.

**REQ-CS-53**: `stopSpeaking` SHALL stop and forget both the playing utterance and the one synthesized ahead, at once (today's rule for one).

**REQ-CS-54**: If the output stalls or fails while an utterance plays, the utterance synthesized ahead (whose buffers were stopped with it) SHALL be reported skipped (`outputUnavailable`) too; nothing of it SHALL be scheduled afterwards.

**REQ-CS-55**: `isSpeakingStream` SHALL stay `true` from the first buffer of the first utterance until the last queued audio has been heard, with no `false` in between when an utterance ahead was already scheduled (the mic echo gate relies on it).

**REQ-CS-56**: The playback service SHALL measure the **handoff gap** of each utterance that follows another one still playing: the time its first buffer is scheduled minus the time the audio scheduled before it ends, 0 if it was scheduled in time. The trace SHALL carry it (detail `handoffGapMs`) on the first audio event of that utterance or part, when it started while the previous audio was playing.

### FR-CS.3 — Setting

**REQ-CS-20**: A conversation setting SHALL turn the split on or off. Default: **on**. It SHALL be read when a session starts.

**REQ-CS-21**: The bench SHALL take the setting from its environment (on by default), and SHALL record it in the run's metadata.

### FR-CS.4 — Trace and bench

**REQ-CS-30**: For a split sentence, the trace's `translated` event SHALL mark the moment the **first** part is ready (it is the start of the critical path to the first audio). Its detail SHALL say how many parts the sentence had.

**REQ-CS-31**: The trace SHALL also record when the whole translation is ready, with the full joined text. Quality metrics (chrF++, COMET) SHALL use the full text.

**REQ-CS-32**: `ttsFirstBuffer` SHALL stay the first audio of the sentence (its first part), and `ttsEnd` the end of its last part's synthesis. The handoff gap of the second part (REQ-CS-56) SHALL be reported per line (p50, p90).

## Non-functional Requirements

**REQ-CS-40 (acceptance)**: On `just bench full best`, split on vs off, run back to back on the same build, Mac idle (peers warned):
- en>es p50 and p90 total SHALL both be lower with the split on;
- pipeline chrF++ SHALL NOT drop by more than **2 points** in any line;
- the handoff gap between the two parts of a split sentence (REQ-CS-56) SHALL have p50 ≤ **50 ms** and p90 ≤ **150 ms** with the voice clone, and a listening check of at least 10 split sentences in the bench WAVs SHALL find no audible cut;
- `just scenario all` SHALL pass as on main (echo, pause, voice pitch), since look-ahead changes the TTS timing every scenario relies on.

**REQ-CS-41**: Unit tests SHALL cover the split rule (REQ-CS-01…04), the delivery rules (REQ-CS-11…18) and the look-ahead rules (REQ-CS-50…56) with the existing mocks and `TestClock`.

## Non-goals

- Splitting more than once, or at other marks (`—`, `(`, CJK punctuation `，` `、`).
- Splitting by meaning (a parser or a model).
- Changing STT or the voice detector.
- Synthesizing more than one utterance ahead, or two at the same time.
- A control for the setting in the Settings window (see design §8).

## Anti-goals

- A cut that sounds like a broken sentence: a silence between the two parts that does not sound like a comma pause, or the second part dropped without the user seeing why.
- A quality loss larger than the measured one (> 2 chrF++ points).
