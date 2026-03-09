# F3.3: One-Way Translation Pipeline — Requirements

**Feature**: End-to-end pipeline: STT result → Translation → TTS synthesis
**Milestone**: M3 — Translation Core
**Status**: DRAFT — awaiting Gate 1 review
**Date**: 2026-03-08
**Author**: Claude + Sergio

---

## 1. Context

After M2, the app has a working speech pipeline: Mic → VAD → STT → `latestTranscription`. It also has a working TTS path: `testTTS()` → `AVSpeechService` → Speaker. The missing link is translation: transcription text must be translated (F3.1) using the configured language pair (F3.2) before being synthesized.

This feature wires the three components together in `AudioViewModel`, replacing the manual `testTTS()` test button with a real automatic pipeline. The result is the first user-visible end-to-end experience of TranslateCall: speak in one language, hear the translation in another.

---

## 2. Definitions

| Term | Definition |
|------|-----------|
| **One-way pipeline** | A single translation direction: source language (spoken) → target language (synthesized) |
| **Translation segment** | A complete transcription result from STT that feeds one translation request |
| **Pipeline state** | The current status of the pipeline: idle / listening / transcribing / translating / speaking |
| **Latency** | Time from end of utterance (VAD speechEnd) to first audio of TTS playback |
| **Total pipeline** | VAD (~0ms) + STT (<800ms) + Translation (~12ms) + TTS (<600ms) = target ≤ 2500ms |

---

## 3. Functional Requirements

### 3.1 AudioViewModel Orchestration

**REQ-PIPE-01**: `AudioViewModel` SHALL hold a reference to `TranslationService` (protocol) and `LanguagePairManager`.

**REQ-PIPE-02**: WHEN a new `TranscriptionResult` is emitted from `sttService.transcriptionStream` THEN `AudioViewModel` SHALL automatically:
1. Extract `result.text` (non-empty, final result).
2. Call `translationService.translate(text:from:to:)` using `languagePairManager.sourceLanguage` and `languagePairManager.targetLanguage`.
3. On success, call `synthesisService.speak(text:locale:)` with the translated text and `targetLanguage`.

**REQ-PIPE-03**: `AudioViewModel` SHALL expose new published state:
```swift
@Published private(set) var latestTranslation: String?
@Published private(set) var isTranslating: Bool
```

**REQ-PIPE-04**: WHEN `translate()` is called THEN `isTranslating` SHALL be set to `true`. WHEN translation completes or throws THEN `isTranslating` SHALL be set to `false`.

**REQ-PIPE-05**: WHEN translation succeeds THEN `latestTranslation` SHALL be updated with the translated text before synthesis begins.

**REQ-PIPE-06**: WHEN `stopCapture()` is called THEN any in-progress translation task SHALL be cancelled and `isTranslating` SHALL be set to `false`.

### 3.2 Pipeline Initialization

**REQ-PIPE-10**: `AudioViewModel.init` SHALL accept an optional `translationService: (any TranslationService)?` parameter (default: `nil`). If nil, translation is disabled (pipeline falls through to no-op).

**REQ-PIPE-11**: `AudioViewModel.init` SHALL accept a `languagePairManager: LanguagePairManager` parameter (default: `LanguagePairManager()`).

**REQ-PIPE-12**: `TranslateCallApp` SHALL construct `AppleTranslationService(model: translationBridgeModel)` and pass it to `AudioViewModel` alongside the `LanguagePairManager`.

**REQ-PIPE-13**: The pipeline SHALL be resilient to a nil `translationService`: IF `translationService == nil` THEN transcription is displayed but no translation or synthesis occurs. This preserves M2 debug mode.

### 3.3 Translation Loop

**REQ-PIPE-20**: The translation loop SHALL run in a dedicated `Task` (`translationTask: Task<Void, Never>?`) inside `AudioViewModel`, consuming `sttService.transcriptionStream`.

**REQ-PIPE-21**: The translation loop SHALL be structured as:
```
for await result in sttService.transcriptionStream {
    guard !result.text.isEmpty else { continue }
    isTranslating = true
    do {
        let translated = try await translationService.translate(...)
        latestTranslation = translated
        isTranslating = false
        await synthesisService.speak(text: translated, locale: targetLocale)
    } catch {
        isTranslating = false
        // surface error via errorAlert
    }
}
```

**REQ-PIPE-22**: The translation task SHALL be cancelled when `deactivateSTT()` is called, ensuring it stops consuming the stream.

**REQ-PIPE-23**: IF `isSpeaking == true` WHEN a new transcription arrives THEN the current synthesis SHALL be interrupted (call `synthesisService.stopSpeaking()` if such a method exists) before starting the new translation. This prevents stale speech from queuing up.

### 3.4 Half-Duplex Integration (from PoC5)

**REQ-PIPE-30**: WHILE `isSpeaking == true` THEN VAD and STT SHALL continue to run but translation SHOULD NOT be triggered for new segments. This avoids translating TTS output captured by the microphone (echo).

**REQ-PIPE-31**: The simplest M3 implementation: skip the translation call (drop segment) if `isSpeaking == true` at the time the transcription result arrives.

**REQ-PIPE-32**: Full half-duplex echo management (PoC5, 3-state machine with 300ms transition buffer) is out of scope for M3. The simple drop-if-speaking guard is sufficient for MVP.

### 3.5 UI Updates

**REQ-PIPE-40**: The main window SHALL display the translation output. `latestTranslation` SHALL be shown below `latestTranscription` in `TranscriptionView` or equivalent.

**REQ-PIPE-41**: A `StatusBadgeView` state SHALL indicate "translating" while `isTranslating == true` (e.g. blue spinning indicator or "Translating..." label).

**REQ-PIPE-42**: The "Test TTS" button (`testTTS()`) SHALL be removed or repurposed as a debug-only button (controlled by `#if DEBUG`) since the real pipeline replaces it.

**REQ-PIPE-43**: The language pair display (source → target) SHALL be visible in the UI so the user can confirm which direction translation is occurring.

### 3.6 Error Handling

**REQ-PIPE-50**: IF translation throws `TranslationError.bridgeUnavailable` THEN `errorAlert` SHALL surface a user-readable message: "Translation unavailable. Restart the app."

**REQ-PIPE-51**: IF translation throws `TranslationError.unsupportedPair` THEN `errorAlert` SHALL surface: "This language pair is not supported. Change languages in settings."

**REQ-PIPE-52**: IF translation throws any other error THEN `errorAlert` SHALL surface the localized description.

**REQ-PIPE-53**: After a translation error, the pipeline SHALL remain active — subsequent STT results SHALL trigger new translation attempts. Errors are per-utterance, not fatal to the session.

### 3.7 Language Pair Change During Session

**REQ-PIPE-60**: Changing language pair is disabled while `isCapturing == true` (enforced by F3.2 REQ-LPM-45). Therefore, `AudioViewModel` does NOT need to handle dynamic language pair changes during a live session in M3.

---

## 4. Non-Functional Requirements

### 4.1 End-to-End Latency

**REQ-NFR-01**: Total pipeline latency (end of speech → first audio of translation) SHALL be ≤ 2500 ms in the typical case (warm STT + installed translation model + first TTS word):
- VAD: ≤ 512 ms speech-end detection
- STT: ≤ 800 ms (Apple Speech on short utterances)
- Translation: ≤ 50 ms (warm session)
- TTS first audio: ≤ 600 ms

**REQ-NFR-02**: IF translation latency exceeds 500 ms THEN `isTranslating` SHALL be visibly `true` so the user understands the system is working.

### 4.2 Resource Usage

**REQ-NFR-03**: The translation loop task SHALL NOT retain strong references to completed `TranscriptionResult` values — process and discard.

**REQ-NFR-04**: Only one translation SHALL be in-flight at a time (sequential queue). If a new transcription arrives while translating, it SHALL be processed after the current translation completes OR the current task is cancelled if `isSpeaking` guard applies.

### 4.3 Privacy

**REQ-NFR-05**: Transcription text processed by the translation pipeline never leaves the device. Apple Translation runs on-device.

**REQ-NFR-06**: `latestTranscription` and `latestTranslation` are ephemeral UI state — not logged, not persisted, cleared when capture stops.

### 4.4 Swift 6 / Concurrency

**REQ-NFR-07**: All pipeline wiring in `AudioViewModel` runs on `@MainActor`. Async calls to `translationService` and `synthesisService` are properly `await`-ed.

**REQ-NFR-08**: The translation `Task` must be properly cancelled and set to `nil` in all teardown paths (`stopCapture`, `deactivateSTT`).

---

## 5. Constraints

| Constraint | Value |
|-----------|-------|
| Platform | macOS 15.0+ |
| Language | Swift 6.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` |
| Orchestrator | `AudioViewModel` (`@MainActor ObservableObject`) |
| Dependencies | F3.1 (TranslationService), F3.2 (LanguagePairManager), F2.2 (STT), F2.3 (TTS) |
| Half-duplex | Simple drop-if-speaking guard (full PoC5 machine deferred to M4) |
| Translation direction | One-way only (source → target); bidirectional in M4 |

---

## 6. Out of Scope (F3.3)

- Bidirectional translation (both speakers) — M4
- Language auto-detection from audio — M4+
- Partial / streaming translation results — requires streaming STT, M4+
- Translation history / session transcript — M5
- Full half-duplex echo management (PoC5 3-state machine) — M4
- BlackHole routing (output to Zoom/Teams) — M4

---

## 7. Acceptance Criteria (Gate 4 — Validation)

| ID | Criterion | Test |
|----|-----------|------|
| AC-01 | Saying "hello" in English with EN→ES pair produces Spanish synthesis ("hola") within 2500 ms | Manual end-to-end test |
| AC-02 | `latestTranslation` is set after a successful translation | `testLatestTranslationUpdated()` |
| AC-03 | `isTranslating` toggles true→false around a translation call | `testIsTranslatingToggle()` |
| AC-04 | Empty transcription result does NOT trigger translation | `testEmptyTranscriptionSkipped()` |
| AC-05 | Segment arriving while `isSpeaking == true` is dropped (no translation called) | `testSegmentDroppedWhileSpeaking()` |
| AC-06 | `stopCapture()` cancels in-progress translation task | `testStopCaptureCancelsTranslation()` |
| AC-07 | Translation error sets `errorAlert` and leaves pipeline active | `testTranslationErrorSurfacedAsAlert()` |
| AC-08 | `testTTS()` button is absent in release build | Code review / UI test |
| AC-09 | 3 consecutive utterances all produce translated synthesis (no hang/deadlock) | `testConsecutiveUtterancesTranslated()` |
| AC-10 | All code compiles with 0 warnings under Swift 6 strict concurrency | CI build check |

---

## 8. Open Questions (to resolve before design.md)

1. **Interrupt current synthesis on new transcription**: Should a new utterance interrupt in-progress TTS?
   - **Preferred**: Yes — `SynthesisService` needs `func stopSpeaking()` (not currently in protocol). Add in F3.3 or as a protocol amendment.

2. **Translation loop location**: Should the translation loop be in `observeTranscriptions()` or a separate `activateTranslation()` method?
   - **Preferred**: Separate `activateTranslation(stream:)` method, consistent with `activateSTT` and `activateTTS` patterns.

3. **`LanguagePairManager` as `@StateObject` vs. owned by `AudioViewModel`**: See F3.2 open question 2. Decision here affects how `AudioViewModel.init` signature looks.
   - **Preferred**: Owned by `AudioViewModel` — all pipeline config in one place.

4. **UI placement of `latestTranslation`**: Below transcription text in existing `TranscriptionView`? Or a separate panel?
   - **Preferred**: Same panel, two text rows (original above, translation below with subtle visual differentiation).

---

*Gate 1 Review: human must approve this document before design.md is written.*
