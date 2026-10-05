# F8.5.3 — Half-duplex + VAD — Requirements

> Status: DRAFT — pending user review (2026-10-05)
> Backlog: `specs/m8.5-stabilization/backlog.md` (items A6, A7, A13, A14, A15, T3, T4 VAD part). T2 moved out (see Out of Scope).

## Overview

TranslateCall must feel like simultaneous interpretation: **every pause the speaker makes closes a sentence, the sentence is translated and spoken at once, and no sentence is ever lost.** Headphones are the primary and recommended setup; using speakers is an opt-in mode that keeps echo out of the outgoing pipeline. Today half-duplex suppression drops sentences silently in both directions and still leaks echo, the TTS queue drops the oldest sentence, Silero VAD is never used, and the silence wait (0.75 s, not configurable) is both slow and unvalidated.

## Motivation (code reading 2026-10-04/05)

| ID | Defect | Effect for the user |
|----|--------|---------------------|
| A6 | Suppression is checked when the *transcription* arrives (`handle*Translation` guards). `HalfDuplexManager` lifts it 300 ms after TTS ends, but the echo is still in the VAD buffer (it waits 0.75 s of silence) and in STT. | With speakers, the remote side's translation is picked up by the mic and translated back. |
| A13 | `outgoingCaptureSuppressed` drops the user's sentences while incoming TTS speaks (a backlog can last many seconds); `incomingCaptureSuppressed` drops remote sentences while outgoing TTS speaks. Neither is reported. | Sentences silently vanish in both directions. |
| — | `incomingCaptureSuppressed` protects against nothing: SCStream captures only the call app, which does not play the user's own voice back. | Pure loss, no benefit. |
| — | `TTSPlaybackService` keeps at most 3 pending utterances and drops the oldest (F8.5.2 D-3). | Fast speakers lose sentences. |
| A7 | `AppContainer` builds `EnergyVADService()` for both directions; `SileroVADService` (async init) and `VADServiceFactory` are dead code. | Noise (keyboard, fan) triggers segments; speech/noise boundaries are poor. |
| T3 | `VADConfiguration` is passed to FluidAudio unchecked; its `precondition`/`assert`s crash on inconsistent values. | A bad value crashes the app (Debug) or misbehaves. |
| T4 / A15 | `minSilenceDuration` is a fixed 0.75 s. | ~700 ms of dead time before each translation; the user cannot tune how long a pause "sends". |
| A14 | One person cannot hear the translated voice end to end without a procedure. | Manual testing is blocked or ad hoc. |

## Decisions taken (brainstorming 2026-10-04/05)

| ID | Decision |
|----|----------|
| D-1 | **Goals:** (1) no sentence is ever lost silently; (2) a sentence is closed by the speaker's pause and translated at once, like simultaneous interpretation. Users are told to pause clearly to "send". Splitting long speech at pauses is intended behaviour (A15 is resolved by tuning, not by merging). |
| D-2 | **Headphones are the default and recommended setup** (may be stated as a requirement in the usage guide). A manual **"I use speakers"** mode (`ListeningMode.speakers`, off by default) enables echo protection. Automatic headphone detection and acoustic echo cancellation are deferred. |
| D-3 | **Echo protection = mic gate before the VAD** (approach 1). In speakers mode, while incoming TTS plays and for a 300 ms tail, mic buffers are replaced with silence of the same length. Echo never reaches VAD/STT. Speech overlapping the incoming translation is not captured; the UI shows "mic paused" instead of dropping anything silently. |
| D-4 | **No direction is ever suppressed at the translation stage.** `HalfDuplexManager`, `outgoingCaptureSuppressed`, `incomingCaptureSuppressed` and both drop guards are removed. The one-shot "mute turn" (user action) stays. |
| D-5 | **TTS queue never drops** (supersedes F8.5.2 D-3/REQ-T-12): safety threshold of 20 pending with a notice; when more than one sentence is pending the worker **coalesces** them into one utterance (≤ ~400 characters each) to recover delay. |
| D-6 | **Pause to translate:** default 0.6 s, user-adjustable 0.4–1.2 s ("Pausa para traducir"), applied at the next session start. |
| D-7 | **Silero is the default VAD**, Energy only as fallback when the model cannot load. The active engine is shown in the UI. |
| D-8 | **Solo testing (A14)** needs no new code: app mic picker = headset mic, system output = speakers, Monitor on, speakers mode on. Documented in the usage guide. An in-app output picker goes to the backlog if this proves awkward. |
| D-9 | T2 (Whisper `small` / threshold for Ukrainian) moves out of F8.5.3 to its own task after F8.5.4. |

## Functional Requirements

### FR-8.5.3.1 — Listening mode and mic echo gate

**REQ-H-01**: A `ListeningMode` setting SHALL exist with values `.headphones` (default) and `.speakers`, persisted in `UserDefaults`, editable in the main window during and outside a session.

**REQ-H-02**: A `MicEchoGate` SHALL sit between the outgoing session audio stream and the outgoing VAD. In `.headphones` mode it SHALL forward every buffer unchanged.

**REQ-H-03**: In `.speakers` mode the gate SHALL replace a buffer with zeros of the same format and frame length while incoming TTS is speaking, and until 300 ms (injectable) after incoming TTS stops speaking. Otherwise it SHALL forward the buffer unchanged.

**REQ-H-04**: The gate SHALL never drop, reorder or resize buffers (the VAD keeps a continuous timeline, so an utterance in progress when the gate closes is ended by the VAD's normal silence rule and still emitted).

**REQ-H-05**: A change of `ListeningMode` SHALL take effect from the next buffer. Switching to `.headphones` SHALL reopen the gate immediately.

**REQ-H-06**: The gate SHALL expose whether it is currently muting (`isMicPaused`), and SHALL be reopened when incoming stops mid-session or the session stops.

**REQ-H-07**: The gate's timing SHALL use an injectable clock, so tests do not sleep.

### FR-8.5.3.2 — No suppression

**REQ-H-10**: `handleOutgoingTranslation` SHALL translate and speak every non-empty transcription, regardless of incoming TTS state. The one-shot mute turn (`suppressNextOutgoingTurn`) SHALL keep working.

**REQ-H-11**: `handleIncomingTranslation` SHALL translate and speak every non-empty transcription, regardless of outgoing TTS state (inverts F8.5.2 REQ-T-43's remaining guard).

**REQ-H-12**: `HalfDuplexManager`, `HalfDuplexCoordinating`, `outgoingCaptureSuppressed`, `incomingCaptureSuppressed` and `HalfDuplexState` SHALL be removed.

**REQ-H-13**: A `ConversationState` (`.listening`, `.speaking`, `.micPaused`) SHALL replace `HalfDuplexState` for the status badge and menu bar icon: `.micPaused` when the gate is muting, else `.speaking` when either TTS is speaking, else `.listening`.

### FR-8.5.3.3 — TTS queue without loss

**REQ-Q-01**: `TTSPlaybackService.speak` SHALL never drop a pending utterance. `TTSEvent.utteranceDropped` SHALL be removed.

**REQ-Q-02**: When the worker takes the next utterance and more than one is pending, it SHALL coalesce consecutive pending utterances of the same locale, in order, joined by a single space, into one utterance of at most `maxCoalescedCharacters` (default 400). An utterance that alone exceeds the limit is taken as is.

**REQ-Q-03**: When the pending count reaches `backlogNoticeThreshold` (default 20), the service SHALL emit one `.backlog(pending:)` event; it SHALL emit it again only after the queue has fallen below the threshold and reached it again. The event surfaces in the notice line (F8.5.2 REQ-T-41) as "Traducción con retraso: N frases en cola".

**REQ-Q-04**: A coalesced utterance SHALL behave as one utterance for fallback, skip, watchdog, metrics and `isSpeaking` (F8.5.2 REQ-T-13…23 unchanged).

### FR-8.5.3.4 — VAD

**REQ-V-01**: Both directions SHALL use `SileroVADService` when its model loads, else `EnergyVADService`. The VAD factories in `AudioCoordinator` SHALL become `async`.

**REQ-V-02**: The Silero model SHALL be preloaded at app launch (background, non-blocking) so the first session does not wait for it. If loading fails, the reason SHALL be logged and Energy used for that session; every new session tries Silero again (cheap once the model is cached).

**REQ-V-03**: The active VAD engine SHALL be visible in the main window (e.g. "VAD: Silero" / "VAD: Energía").

**REQ-V-04**: `VADServiceFactory` SHALL be removed.

**REQ-V-05**: A "Pausa para traducir" setting (0.4–1.2 s, step 0.1 s, default 0.6 s) SHALL be persisted and SHALL set `VADConfiguration.minSilenceDuration` for both directions at the next session start. The UI SHALL say it applies to the next session when changed during one.

**REQ-V-06**: `VADConfiguration.validated()` SHALL return a configuration that satisfies every FluidAudio precondition and assertion: all durations ≥ 0, `maxSpeechDuration` > 0, `minSpeechDuration` ≤ `maxSpeechDuration`, `minSilenceDuration` ≤ `maxSpeechDuration`, `speechPadding` ≤ `minSpeechDuration`, `sileroThreshold` in [0, 1]. Out-of-range values are clamped and a warning is logged; it never throws.

**REQ-V-07**: Both VAD services SHALL apply `validated()` to their configuration on init.

### FR-8.5.3.5 — Usage guide

**REQ-U-01**: A usage guide (`docs/usage-guide.md`, in Spanish) SHALL explain: headphones recommended; pause clearly to send a sentence; the "Pausa para traducir" and "Uso altavoces" settings; the solo test procedure (D-8) for both directions.

**REQ-U-02**: The main window SHALL link to the guide and show a one-line hint near the capture button ("Haz una pausa para enviar cada frase").

## Non-Functional Requirements

**NFR-H-01**: With Silero and the configured pause *p*, the segment for a sentence SHALL be emitted no later than *p* + 150 ms after the end of speech (integration test on fixtures).

**NFR-H-02**: A pause shorter than half the configured pause (e.g. 0.3 s with p = 0.6 s) SHALL NOT split a sentence (integration test on fixtures).

**NFR-H-03**: The gate SHALL add no allocation in `.headphones` mode and at most one zeroed buffer per input buffer in `.speakers` mode.

**NFR-H-04**: Unit tests SHALL NOT use real ML models, the network or an audio device (as F8.5.2 NFR-T-03).

## Out of Scope

- Automatic headphone/speaker detection and acoustic echo cancellation (voice processing I/O) → later milestone.
- In-app selector for the listening output device → backlog if the solo procedure is awkward.
- Speeding up TTS while a backlog exists.
- T2 Whisper `small` / confidence threshold for Ukrainian → own task after F8.5.4.
- Translation latency (`invalidate()` per call, A8, T5) → F8.5.4.

## Acceptance Criteria

1. `just pr` passes on the feature branch.
2. Unit tests cover REQ-H-0x/1x, REQ-Q-0x and REQ-V-0x as listed in design.md §5, with fakes and an injectable clock.
3. Integration tier (Mac mini):
   - Silero on fixtures: two sentences separated by 0.7 s → 2 segments; a 0.3 s micro-pause → 1 segment; NFR-H-01 latency bound holds.
   - Simulated echo: a speech fixture through `MicEchoGate` (speakers mode) + Silero with an "incoming speaking" interval yields no segment from that interval; speech before it is emitted.
4. Manual checklist in tasks.md completed (headphones cross-talk with no loss; speakers mode solo test without echo loop and with "mic paused" indicator; pause setting at 0.4/0.6/1.2 s; backlog coalescing with a long monologue; VAD engine shown; re-run of F8.5.2 M1/M6 and F8.5.1 M1–M6 with the solo procedure).
5. Backlog: A6, A7, A13, A14, A15, T3 and T4 (VAD part) marked fixed in F8.5.3 with their pinning tests; T2 re-owned; `AudioCoordinatorTTSTests.incomingDroppedWhileSuppressed` replaced by its inverse.
