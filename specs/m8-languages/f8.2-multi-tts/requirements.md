# F8.2 — Multi-Engine TTS Fallback

## Overview

Extend the TTS subsystem to provide speech synthesis for languages not covered by AVSpeechSynthesizer (e.g., Ukrainian), using cloud-based (Edge TTS) or on-device (Piper) fallback engines.

## Motivation

- AVSpeechSynthesizer has no voices for several languages (Ukrainian `uk`, and others)
- When TTS has no voice, the pipeline is silently broken — translation appears as text but no audio plays
- Users need audio output in ALL languages the app claims to support
- Two complementary approaches: Edge TTS (cloud, high quality, many languages) and Piper (on-device, lower quality, privacy-preserving)

## Functional Requirements

### FR-8.2.1 — Edge TTS Service (Cloud Fallback)

**REQ-T-01**: `EdgeTTSService` SHALL conform to the existing `SynthesisService` protocol (actor-based, `isSpeakingStream`, `speak(text:locale:)`, `stopSpeaking()`, `deactivate()`).

**REQ-T-02**: `EdgeTTSService` SHALL use Microsoft Edge TTS (free, no API key required) to synthesize speech via WebSocket streaming.

**REQ-T-03**: `EdgeTTSService` SHALL support at minimum 100+ languages/locales, including Ukrainian (`uk-UA-PolinaNeural`, `uk-UA-OstapNeural`).

**REQ-T-04**: `EdgeTTSService` SHALL stream audio chunks as they arrive (low-latency streaming synthesis, not batch).

**REQ-T-05**: `EdgeTTSService` SHALL convert received audio (MP3 or raw PCM) to the output device's format via AVAudioConverter and play through AVAudioPlayerNode, consistent with existing TTS services.

**REQ-T-06**: `EdgeTTSService` SHALL gracefully handle network unavailability: IF the network is unreachable **THEN** `speak()` SHALL fail silently (log warning) and the pipeline SHALL continue.

**REQ-T-07**: `EdgeTTSService` SHALL expose a list of available voices per locale so the user can select preferred voice (e.g., male/female).

**REQ-T-08**: `EdgeTTSService` SHALL record `TTSMetrics` (engine: `.edgeTTS`, synthesisLatencyMs, textLength, locale).

### FR-8.2.2 — Piper TTS Service (On-Device Fallback) — OPTIONAL

**REQ-T-10**: `PiperTTSService` SHALL conform to `SynthesisService`.

**REQ-T-11**: `PiperTTSService` SHALL use Piper TTS (ONNX-based, on-device) for fully offline synthesis.

**REQ-T-12**: `PiperTTSService` SHALL support languages available in Piper's voice catalog (40+), including Ukrainian.

**REQ-T-13**: IF both Edge TTS and Piper are available for a locale **THEN** Edge TTS SHALL be preferred (higher quality) unless the user explicitly selects on-device mode.

**REQ-T-14**: `PiperModelManager` SHALL manage model download and caching, consistent with existing model manager patterns.

> Note: Piper integration is OPTIONAL for M8. Edge TTS alone satisfies the core requirement. Piper can be added as a follow-up if offline TTS for unsupported languages is needed.

### FR-8.2.3 — TTSEngine Extension

**REQ-T-20**: `TTSEngine` enum SHALL add an `.edgeTTS` case (and optionally `.piper`).

**REQ-T-21**: `TTSEngine.edgeTTS.supports(locale:)` SHALL return `true` for all locales with available Edge TTS voices.

**REQ-T-22**: `TTSEngineSelector` selection logic SHALL be updated to:
1. **Voice Clone** (Qwen3-TTS) — if enabled, available, locale supported, profile selected
2. **Kokoro** — if preferred, available, English locale
3. **AVSpeech** — if the locale has an installed AVSpeech voice
4. **Edge TTS** — if AVSpeech has no voice for the locale AND network is available
5. **(Future) Piper** — if Edge TTS unavailable (offline) AND Piper model downloaded

**REQ-T-23**: The fallback chain SHALL be automatic — the user does NOT need to manually select Edge TTS. When AVSpeech has no voice, Edge TTS is used transparently.

**REQ-T-24**: The user SHALL be able to override the automatic selection and force a specific engine per language in settings (future, not required for M8 MVP).

### FR-8.2.4 — Voice Availability Detection

**REQ-T-30**: `TTSEngineSelector` SHALL detect whether AVSpeechSynthesizer has a voice for the current target locale.

**REQ-T-31**: IF no AVSpeech voice exists **THEN** the selector SHALL automatically route to Edge TTS.

**REQ-T-32**: The UI SHALL indicate when Edge TTS is in use (e.g., "Cloud TTS" badge or icon) so the user knows audio is being processed via network.

**REQ-T-33**: IF the user is offline AND no AVSpeech voice AND no Piper model exists **THEN** the UI SHALL display a warning that TTS is unavailable for the current language.

### FR-8.2.5 — UI Integration

**REQ-T-40**: The TTS engine indicator in the main window SHALL show the active engine name (AVSpeech / Kokoro / Voice Clone / Edge TTS).

**REQ-T-41**: WHEN Edge TTS is active **THEN** a small cloud icon or "Cloud" label SHALL be visible to indicate network dependency.

**REQ-T-42**: The TTS metrics view SHALL include Edge TTS metrics (network latency, synthesis latency, total latency).

**REQ-T-43**: A voice selector SHALL allow the user to choose among available Edge TTS voices for the current locale (male/female/neural variants).

## Non-Functional Requirements

**NFR-T-01**: Edge TTS synthesis latency (network round-trip + decoding) SHALL be < 2 seconds for a typical sentence on a broadband connection.

**NFR-T-02**: Edge TTS SHALL NOT require API keys, subscriptions, or user accounts.

**NFR-T-03**: Edge TTS audio quality SHALL be subjectively comparable to or better than AVSpeech premium voices.

**NFR-T-04**: `EdgeTTSService` SHALL be an `actor` (consistent with all existing services).

**NFR-T-05**: Edge TTS SHALL use streaming playback — audio SHALL begin playing before the full response is received.

**NFR-T-06**: Privacy: Edge TTS sends text to Microsoft's servers. The app SHALL disclose this to the user when Edge TTS is first used (one-time consent dialog).

**NFR-T-07**: All new code SHALL compile with zero warnings.

## Dependencies

- **Edge TTS library**: Evaluate `edge-tts` protocol implementation in Swift (WebSocket to `speech.platform.bing.com`). May need a custom Swift implementation or a thin C/Python bridge. Decision deferred to design phase.
- Existing: `SynthesisService` protocol, `TTSEngineSelector`, `TTSMetricsCollector`, `AudioCoordinator` factory pattern.

## Acceptance Criteria

- [ ] AC-T-01: Edge TTS synthesizes Ukrainian speech (uk-UA-PolinaNeural) with natural-sounding quality
- [ ] AC-T-02: Edge TTS works for at least 20 languages not well-served by AVSpeech
- [ ] AC-T-03: Automatic fallback from AVSpeech → Edge TTS is transparent to the user
- [ ] AC-T-04: Streaming playback starts within 1 second of speak() call on broadband
- [ ] AC-T-05: Graceful degradation when offline (warning shown, pipeline continues without TTS)
- [ ] AC-T-06: Privacy consent dialog shown on first Edge TTS use
- [ ] AC-T-07: TTSMetrics collected and displayed for Edge TTS
- [ ] AC-T-08: 15+ unit tests covering EdgeTTSService, voice availability detection, and selector changes
