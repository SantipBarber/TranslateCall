# F8.1 — whisper.cpp STT Integration

## Overview

Replace/complement Apple Speech and Parakeet with whisper.cpp for multi-language STT supporting 99+ languages with consistent quality and fully on-device inference on Apple Silicon.

## Motivation

- Apple Speech quality varies significantly across languages and requires network for best results
- Parakeet only supports English
- whisper.cpp (via whisper.cpp's CoreML/Metal backend) provides consistent, high-quality STT across 99+ languages, fully on-device
- Ukrainian (key user goal) is well-supported by Whisper but poorly served by Apple Speech

## Functional Requirements

### FR-8.1.1 — WhisperSpeechService

**WHEN** the user selects the Whisper STT engine **THEN** the system SHALL use whisper.cpp for speech recognition.

**REQ-W-01**: `WhisperSpeechService` SHALL conform to the existing `SpeechRecognizerService` protocol (actor-based, `transcriptionStream`, `activate(stream:)`, `deactivate()`, `setLocale()`).

**REQ-W-02**: `WhisperSpeechService` SHALL accept `SpeechSegment` buffers (16 kHz mono Float32) from VAD and emit `TranscriptionResult` with text, confidence, locale, capturedAt, and audioDuration.

**REQ-W-03**: `WhisperSpeechService` SHALL support at minimum the 99 languages supported by Whisper large-v3.

**REQ-W-04**: `WhisperSpeechService` SHALL run inference entirely on-device using Apple Silicon GPU/ANE acceleration (Metal or CoreML backend).

**REQ-W-05**: `WhisperSpeechService` SHALL truncate or chunk segments exceeding the model's maximum input length (30 seconds at 16 kHz = 480,000 samples), consistent with ParakeetSpeechService's truncation pattern.

**REQ-W-06**: `WhisperSpeechService` SHALL record `STTMetrics` (engine: `.whisper`, latencyMs, segmentDurationMs, confidence, textLength) consistent with existing services.

### FR-8.1.2 — WhisperModelManager

**REQ-W-10**: `WhisperModelManager` SHALL be a singleton actor managing model download, caching, and loading, consistent with `ParakeetModelManager` and `KokoroModelManager` patterns.

**REQ-W-11**: `WhisperModelManager` SHALL support multiple model sizes with clear size/quality/speed tradeoffs:
- `tiny` (~75 MB) — fastest, lowest quality
- `base` (~150 MB) — balanced for real-time
- `small` (~500 MB) — good quality, moderate latency
- `medium` (~1.5 GB) — high quality (default)
- `large-v3` (~3 GB) — highest quality, highest latency

**REQ-W-12**: WHEN the selected model is not downloaded **THEN** `WhisperModelManager` SHALL download it from HuggingFace Hub with observable progress (consistent with existing model managers).

**REQ-W-13**: `WhisperModelManager` SHALL use task coalescing — concurrent calls to `ensureReady()` SHALL share a single download/load operation.

**REQ-W-14**: `WhisperModelManager` SHALL expose observable state: `isReady`, `isDownloading`, `downloadProgress`, `currentModelSize`, `error`.

### FR-8.1.3 — STTEngine Extension

**REQ-W-20**: `STTEngine` enum SHALL add a `.whisper` case.

**REQ-W-21**: `STTEngine.whisper.supports(locale:)` SHALL return `true` for all locales whose language code maps to a Whisper-supported language.

**REQ-W-22**: `STTEngineSelector` SHALL be updated to support `.whisper`:
- **Outgoing**: Use Whisper if preferred AND available AND locale is supported; else fall back to Apple Speech.
- **Incoming**: Use Whisper if preferred AND available AND locale is supported; else fall back to Apple Speech.
- Unlike Parakeet (English-only), Whisper can serve BOTH directions for most languages.

**REQ-W-23**: `STTEngineSelector` SHALL expose `whisperAvailable: Bool` and `isWhisperDownloading: Bool` for UI binding.

### FR-8.1.4 — WhisperConfiguration

**REQ-W-30**: `WhisperConfiguration` SHALL be a `Sendable` struct with:
- `modelSize: WhisperModelSize` — selected model variant (default: `.medium`)
- `language: String?` — BCP-47 language code, or `nil` for auto-detect
- `translateToEnglish: Bool = false` — Whisper's built-in translation mode (not used in our pipeline, but exposed for future use)
- `beamSize: Int = 5` — beam search width
- `noSpeechThreshold: Float = 0.6` — probability threshold for no-speech detection

**REQ-W-31**: `WhisperConfiguration` SHALL have a `nonisolated static let default` with sensible defaults.

### FR-8.1.5 — UI Integration

**REQ-W-40**: The STT engine picker in `LanguagePairView` SHALL include a "Whisper" option alongside "Apple Speech" and "Parakeet".

**REQ-W-41**: WHEN Whisper is selected but the model is not downloaded **THEN** the UI SHALL show a download sheet with model size selection and progress indicator.

**REQ-W-42**: WHEN Whisper is active **THEN** the STT metrics view SHALL display Whisper-specific metrics (model size, inference time).

**REQ-W-43**: IF Whisper is preferred but unavailable (not downloaded) **THEN** the UI SHALL show an "Using fallback" badge, consistent with existing Parakeet/Kokoro fallback indicators.

### FR-8.1.6 — Model Size Picker

**REQ-W-50**: A `WhisperModelSizeView` SHALL allow the user to select the model size before downloading.

**REQ-W-51**: The picker SHALL display for each size: name, download size, estimated quality level, and estimated latency.

**REQ-W-52**: WHEN the user changes model size after download **THEN** the system SHALL offer to download the new size (the old model may be retained or deleted per user preference).

## Non-Functional Requirements

**NFR-W-01**: Whisper inference latency SHALL be < 3 seconds for a 5-second audio segment on M1 Mac with the `base` model.

**NFR-W-02**: Whisper SHALL NOT require network access after initial model download.

**NFR-W-03**: Memory usage SHALL be bounded: model manager SHALL unload the model when the engine is deselected (consistent with `unloadParakeetModel()` / `unloadKokoroModel()`).

**NFR-W-04**: `WhisperSpeechService` SHALL be an `actor` (consistent with all existing services under `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`).

**NFR-W-05**: All new code SHALL compile with zero warnings under the project's existing build settings.

## Dependencies

- **whisper.cpp Swift binding**: Evaluate `whisper.swiftui` (official example), `WhisperKit` (Argmax), or direct C API bridging via SPM. Decision deferred to design phase.
- Existing: `SpeechRecognizerService` protocol, `STTEngineSelector`, `STTMetricsCollector`, `AudioCoordinator` factory pattern.

## Acceptance Criteria

- [ ] AC-W-01: WhisperSpeechService transcribes English with quality comparable to Parakeet
- [ ] AC-W-02: WhisperSpeechService transcribes Ukrainian with > 80% word accuracy on standard test sentences
- [ ] AC-W-03: Model download, progress, and cancellation work correctly
- [ ] AC-W-04: STTEngineSelector routes to Whisper for all supported locales when preferred
- [ ] AC-W-05: Fallback to Apple Speech works when Whisper model is not downloaded
- [ ] AC-W-06: Metrics are collected and displayed in STTMetricsView
- [ ] AC-W-07: No latency regression for English when using Whisper `base` model vs Apple Speech
- [ ] AC-W-08: 20+ unit tests covering WhisperSpeechService, WhisperModelManager, and STTEngineSelector changes
