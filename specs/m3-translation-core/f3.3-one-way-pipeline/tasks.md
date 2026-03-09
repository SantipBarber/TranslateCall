# F3.3: One-Way Translation Pipeline — Tasks

**Feature**: End-to-end pipeline: STT result → Translation → TTS synthesis
**Milestone**: M3 — Translation Core
**Status**: DRAFT — awaiting Gate 3 review
**Date**: 2026-03-08
**Prerequisites**: design.md (Gate 2 approved), F3.1 complete, F3.2 T1+T2 complete

---

## Dependency Order

```
T1 (AudioViewModel: translation state + handleTranslation)
  ├──▶ T2 (TranscriptionView: translation row)
  ├──▶ T3 (StatusBadgeView: translating state)
  ├──▶ T4 (cleanup: testTTS + start button)
  └──▶ T5 (tests)
```

T1 is the only task with code dependencies on F3.1 and F3.2. T2–T4 depend only on T1.

---

## T1 — Add translation state and pipeline to `AudioViewModel`

**Maps to**: REQ-PIPE-01 through REQ-PIPE-06, REQ-PIPE-10 through REQ-PIPE-23
**File**: `TranslateCall/Features/Main/AudioViewModel.swift` *(modify)*
**Depends on**: F3.1 T3 (`AppleTranslationService`), F3.2 T2 (`languagePairManager` already in init)

### What to implement

1. Add published state:
   ```swift
   @Published private(set) var latestTranslation: String?
   @Published private(set) var isTranslating: Bool = false
   ```

2. Modify `observeTranscriptions(_ service:)` to inline translation:
   ```swift
   private func observeTranscriptions(_ service: any SpeechRecognizerService) {
       transcriptionTask?.cancel()
       transcriptionTask = Task { @MainActor [weak self] in
           guard let self else { return }
           for await result in service.transcriptionStream {
               self.latestTranscription = result.text
               self.isTranscribing = false
               await self.handleTranslation(of: result.text)
           }
       }
   }
   ```

3. Add `private func handleTranslation(of text: String) async`:
   ```swift
   private func handleTranslation(of text: String) async {
       guard !text.isEmpty,
             let service = translationService,
             !isSpeaking
       else { return }

       await synthesisService?.stopSpeaking()
       isTranslating = true
       do {
           let translated = try await service.translate(
               text: text,
               from: languagePairManager.sourceLanguage,
               to: languagePairManager.targetLanguage
           )
           latestTranslation = translated
           isTranslating = false
           let targetLocale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
           await synthesisService?.speak(text: translated, locale: targetLocale)
       } catch {
           isTranslating = false
           errorAlert = AlertItem(
               title: "Translation Error",
               message: translationErrorMessage(for: error),
               action: nil
           )
       }
   }

   private func translationErrorMessage(for error: Error) -> String {
       switch error {
       case TranslationError.bridgeUnavailable:
           return "Translation unavailable. Restart the app."
       case TranslationError.unsupportedPair:
           return "This language pair is not supported. Change languages in settings."
       default:
           return error.localizedDescription
       }
   }
   ```

4. Update `deactivateSTT()` to reset new state:
   ```swift
   private func deactivateSTT() async {
       await sttService?.deactivate()
       transcriptionTask?.cancel()
       transcriptionTask = nil
       sttService = nil
       isTranscribing = false
       isTranslating = false       // add
       latestTranslation = nil     // add
   }
   ```

5. Update `preview()` factory — add `latestTranscription` and `latestTranslation` preview values if desired (optional, for UI preview).

### Tests (RED first) — `TranslateCallTests/TranslationPipelineTests.swift` *(new file)*

Use a `MockTranslationService: TranslationService` that synchronously returns a canned result.

```swift
@Suite(.serialized) @MainActor
struct TranslationPipelineTests {
    // MockTranslationService: returns "TRANSLATED: <input>" immediately
    // MockSynthesisService: records calls to speak/stopSpeaking
}
```

- `testLatestTranslationUpdated()` — inject mock service, deliver transcription result, assert `latestTranslation == "TRANSLATED: hello"` (AC-02)
- `testIsTranslatingToggle()` — observe `isTranslating` transitions: assert true → false around translate call (AC-03)
- `testEmptyTranscriptionSkipped()` — deliver empty string, assert `translationService.translate()` never called (AC-04)
- `testSegmentDroppedWhileSpeaking()` — set `isSpeaking = true` (via mock synthesis stream), deliver transcription, assert `translate()` not called (AC-05)
- `testStopCaptureCancelsTranslation()` — start slow mock translate (100ms delay), call `stopCapture()`, assert `isTranslating == false` after stop (AC-06)
- `testTranslationErrorSurfacedAsAlert()` — mock service throws `TranslationError.bridgeUnavailable`, assert `errorAlert != nil` and pipeline not crashed (AC-07)
- `testConsecutiveUtterancesTranslated()` — deliver 3 sequential transcription results via mock, assert all 3 produce translations in order without hang (AC-09)

### Done when
- `AudioViewModel` compiles with zero warnings
- Existing M2 tests still green (`AudioManagerTests`, `STTServiceTests`, `TTSServiceTests`, `VADServiceTests`)
- New pipeline tests green

---

## T2 — Update `TranscriptionView` — add translation row and isTranslating indicator

**Maps to**: REQ-PIPE-40, REQ-PIPE-41
**File**: `TranslateCall/Features/Main/TranscriptionView.swift` *(modify — was new in M2)*
**Depends on**: T1

### What to implement

Replace or extend the view body to show both transcription and translation:

```swift
struct TranscriptionView: View {
    @EnvironmentObject private var viewModel: AudioViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Original transcription (existing)
            if let text = viewModel.latestTranscription {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
            }

            // Translation row (new)
            if viewModel.isTranslating {
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.6)
                    Text("Translating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let translated = viewModel.latestTranslation {
                Text(translated)
                    .font(.body)
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
}
```

### Done when
- View compiles with zero warnings
- SwiftUI Preview with `latestTranscription = "Hola"` and `latestTranslation = "Hello"` renders both rows
- `isTranslating == true` shows spinner instead of previous translation

---

## T3 — Update `StatusBadgeView` — add "Translating" state

**Maps to**: REQ-PIPE-41
**File**: `TranslateCall/Features/Main/StatusBadgeView.swift` *(modify)*
**Depends on**: T1

### What to implement

Add `isTranslating` to the priority chain. New priority (highest → lowest):

```
speaking (red) > translating (blue) > transcribing (purple) > speech-active (orange) > capturing (green) > idle (grey)
```

Locate the existing status logic in `StatusBadgeView` and insert the translating case:

```swift
// After isSpeaking check, before isTranscribing:
} else if viewModel.isTranslating {
    StatusBadge(label: "Translating", color: .blue)
} else if viewModel.isTranscribing {
```

> The exact variable/view name used in `StatusBadgeView` must match what's already there — read the file before editing.

### Done when
- Badge shows blue "Translating" label during mock translation in Preview
- Priority order correct (speaking overrides translating)

---

## T4 — Cleanup: wrap `testTTS()` in `#if DEBUG` and update start button guard

**Maps to**: REQ-PIPE-42, REQ-PIPE-43 (start button guard for unsupported pair — may already be done in F3.2 T4)
**Files**: `TranslateCall/Features/Main/AudioViewModel.swift`, `TranslateCall/Features/Main/ContentView.swift`
**Depends on**: T1

### What to implement

1. In `AudioViewModel.swift`, wrap `testTTS()`:
   ```swift
   #if DEBUG
   func testTTS() {
       startSynthesis(text: "Hello, translation is working.", locale: .current)
   }
   #endif
   ```

2. In `ContentView.swift`, wrap any "Test TTS" button in `#if DEBUG`:
   ```swift
   #if DEBUG
   Button("Test TTS") { viewModel.testTTS() }
   #endif
   ```

3. Confirm start button guard from F3.2 T4 is in place (check `ContentView`). If not already done, add:
   ```swift
   .disabled(
       viewModel.isStarting ||
       (!viewModel.isCapturing && viewModel.languagePairManager.pairStatus == .unsupported)
   )
   ```

### Done when
- Release build has no "Test TTS" button visible
- `#if DEBUG` build retains the button for manual testing
- Start button disabled when pair is `.unsupported`

---

## T5 — Tests

**Maps to**: All REQ-PIPE + AC-01 through AC-10
**File**: `TranslateCallTests/TranslationPipelineTests.swift`
**Depends on**: T1–T4

### Integration test (manual — AC-01)

> **AC-01 — End-to-end validation**:
> 1. Select source = Spanish (ES), target = English (EN), verify `.installed`.
> 2. Press Start. Say "Hola, ¿cómo estás?" in Spanish.
> 3. Expected: `latestTranscription` shows Spanish text; `latestTranslation` shows English translation; TTS speaks the English translation within 2500ms.
> Run on device with Apple Translation models installed. Not automatable.

### Additional automated tests

- `testPipelineWithNilTranslationServiceIsNoop()` — create `AudioViewModel(translationService: nil)`, deliver transcription, assert `latestTranslation == nil` and no crash
- `testStopSpeakingCalledBeforeTranslation()` — inject mock synthesis service that records `stopSpeaking()` calls; deliver transcription while `isSpeaking == false`; assert `stopSpeaking()` was called before `speak()` (design decision to interrupt any residual audio)
- `testTranslateLocaleMatchesTargetLanguage()` — mock speaks with canned locale; assert `speak(text:locale:)` received locale matching `languagePairManager.targetLanguage.minimalIdentifier`
- `testAllCodeCompilesUnderSwift6()` — CI build check (automated by build system, not Swift Testing)

### Done when
- All automated tests green
- AC-01 through AC-10 covered by test or documented as manual integration
- Zero new warnings introduced in the modified files

---

## Task Summary

| Task | File(s) | Effort | Blocks |
|------|---------|--------|--------|
| T1 — ViewModel pipeline | `Features/Main/AudioViewModel.swift` | M | T2, T3, T4, T5 |
| T2 — TranscriptionView | `Features/Main/TranscriptionView.swift` | XS | T5 |
| T3 — StatusBadgeView | `Features/Main/StatusBadgeView.swift` | XS | T5 |
| T4 — Cleanup | `AudioViewModel.swift`, `ContentView.swift` | XS | T5 |
| T5 — Tests | `TranslateCallTests/TranslationPipelineTests.swift` | S | — |

---

## M3 Implementation Order (across all three features)

```
F3.1-T1 (TranslationService types)
  └──▶ F3.1-T2 (TranslationBridgeModel + Bridge view)
         └──▶ F3.1-T3 (AppleTranslationService)
                └──▶ F3.1-T4 (AppContainer + TranslateCallApp)
                       ┃
                       ▼
F3.2-T1 (LanguagePairManager) ──▶ F3.2-T2 (AudioViewModel wiring)
                                         ┃
                                         ▼
                             F3.3-T1 (handleTranslation)
                               ├──▶ F3.3-T2 (TranscriptionView)
                               ├──▶ F3.3-T3 (StatusBadgeView)
                               └──▶ F3.3-T4 (cleanup)
                                          └──▶ F3.2-T3 (LanguagePairView)
                                                 └──▶ F3.2-T4 (ContentView)
                                                        └──▶ All T5s (tests)
```

---

*Gate 3 Review: human must approve this document before implementation begins.*
