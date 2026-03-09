# F3.3: One-Way Translation Pipeline — Technical Design

**Feature**: End-to-end pipeline: STT result → Translation → TTS synthesis
**Milestone**: M3 — Translation Core
**Status**: DRAFT — awaiting Gate 2 review
**Date**: 2026-03-08
**Prerequisites**: requirements.md (Gate 1 approved), F3.1 design.md, F3.2 design.md

---

## 1. Key Design Decisions

### 1.1 Translation is inlined into the transcription observer task

`AsyncStream<TranscriptionResult>` is single-consumer. The existing `transcriptionTask` is the only consumer of `sttService.transcriptionStream`. Rather than creating a second independent Task that tries to read the same stream, the translation + synthesis steps are added sequentially inside `transcriptionTask`'s for-await loop.

```
transcriptionTask (Task<Void, Never>):
  for await result in sttService.transcriptionStream {
    latestTranscription = result.text        // existing
    await handleTranslation(of: result.text) // new — translate → speak
  }
```

This keeps the pipeline strictly sequential: the next STT result is not processed until the current one has been translated and synthesis has been scheduled.

### 1.2 `handleTranslation` is `@MainActor async` — suspension is intentional

`handleTranslation` calls `translationService.translate()` which suspends for ~50ms. The `transcriptionTask` is suspended during this time. This is correct for M3: we don't want to start translating a new utterance while the current one is still being processed.

Consequence: new STT results that arrive while translating are buffered in the `AsyncStream` (default buffer capacity is unlimited for `.unbounded` policy). They will be processed in order once the current translation completes. If a result is dropped (e.g. `isSpeaking` guard), it is simply skipped.

### 1.3 Simple half-duplex guard: drop if speaking at translation time

Before calling `translationService.translate()`, check `isSpeaking`. If true, drop the segment. This prevents translating/speaking TTS output that was picked up by the microphone.

This guard is approximate: `isSpeaking` is updated asynchronously via `isSpeakingStream`, so there is a short window where `isSpeaking` is still `false` even though audio has started. For M3 this is acceptable. Full half-duplex coordination (PoC5 3-state machine) is M4.

### 1.4 Interrupt current synthesis when a new human utterance arrives

Before calling `translate()`, call `synthesisService?.stopSpeaking()`. This cancels any in-progress TTS and clears the queue before synthesizing the new translation. Without this, a long TTS output from utterance N would finish before utterance N+1 is spoken, which feels laggy.

Note: `stopSpeaking()` is already in `SynthesisService` protocol (F2.3 design section 3.3). No protocol amendment needed.

### 1.5 `Locale` for TTS derived from `targetLanguage` via `minimalIdentifier`

`AVSpeechService.speak(text:locale:)` takes a `Locale`. Convert `Locale.Language` → `Locale`:

```swift
let targetLocale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
```

`minimalIdentifier` returns a BCP-47 string like `"en"` or `"es"` — sufficient for `AVSpeechSynthesisVoice` language matching, which uses a 2-letter prefix.

### 1.6 `translationService` is optional — nil disables translation, preserves M2 debug mode

When `translationService == nil`, `handleTranslation` returns immediately (no-op). The M2 pipeline continues to work: transcription is shown, `testTTS()` can still be called manually in `#if DEBUG` builds.

---

## 2. Architecture Overview

```
AudioViewModel (@MainActor ObservableObject)
│
├── @Published latestTranscription: String?  ← existing (F2.2)
├── @Published latestTranslation: String?    ← NEW
├── @Published isTranslating: Bool           ← NEW
├── @Published isSpeaking: Bool              ← existing (F2.3)
│
├── private let translationService: (any TranslationService)?  ← NEW
├── private let languagePairManager: LanguagePairManager       ← NEW (F3.2)
│
└── transcriptionTask: Task<Void, Never>?
      for await result in sttService.transcriptionStream {
        latestTranscription = result.text
        await handleTranslation(of: result.text)   ← NEW — sequential pipeline
      }

handleTranslation(text):
  guard !text.isEmpty, translationService != nil, !isSpeaking → drop if speaking
  await synthesisService?.stopSpeaking()           → interrupt current TTS
  isTranslating = true
  translated = try await translationService.translate(text, from: src, to: tgt)
  latestTranslation = translated
  isTranslating = false
  await synthesisService?.speak(translated, locale: targetLocale)
```

---

## 3. `AudioViewModel` Changes

### 3.1 New properties

```swift
// AudioViewModel.swift — additions to existing class

// MARK: - Translation state
@Published private(set) var latestTranslation: String?
@Published private(set) var isTranslating: Bool = false

// MARK: - New private dependencies
private let translationService: (any TranslationService)?
private let languagePairManager: LanguagePairManager
```

### 3.2 Updated `init`

```swift
init(
    audioManager: AudioManager = AudioManager(),
    vadFactory: VADServiceFactory = VADServiceFactory(),
    translationService: (any TranslationService)? = nil,
    languagePairManager: LanguagePairManager = LanguagePairManager()
) {
    self.translationService = translationService
    self.languagePairManager = languagePairManager
    self.audioManager = audioManager
    self.vadFactory = vadFactory
    bindAudioManager()
}
```

### 3.3 Updated `observeTranscriptions`

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

### 3.4 New `handleTranslation`

```swift
private func handleTranslation(of text: String) async {
    guard !text.isEmpty,
          let service = translationService,
          !isSpeaking
    else { return }

    // Interrupt any in-progress TTS before synthesizing new translation
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

### 3.5 Updated `deactivateSTT`

```swift
private func deactivateSTT() async {
    await sttService?.deactivate()
    transcriptionTask?.cancel()      // also cancels in-flight handleTranslation
    transcriptionTask = nil
    sttService = nil
    isTranscribing = false
    isTranslating = false            // ensure clean state
    latestTranslation = nil
}
```

### 3.6 Remove `testTTS`

```swift
// BEFORE (M2 debug)
func testTTS() {
    startSynthesis(text: "Hello, translation is working.", locale: .current)
}

// AFTER (M3) — wrap in DEBUG guard or remove entirely
#if DEBUG
func testTTS() {
    startSynthesis(text: "Hello, translation is working.", locale: .current)
}
#endif
```

---

## 4. UI Changes

### 4.1 `TranscriptionView` — add translation row

```swift
// Features/Main/TranscriptionView.swift — updated
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
            // Translation output (new)
            if viewModel.isTranslating {
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.6)
                    Text("Translating…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let translated = viewModel.latestTranslation {
                Text(translated)
                    .font(.body)
                    .foregroundStyle(.secondary)    // visually distinct from source
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
}
```

### 4.2 `StatusBadgeView` — new "translating" state

Add `.translating` to the status logic:

```swift
// StatusBadgeView.swift — add translating case
// Priority: speaking > translating > transcribing > speech-active > capturing > idle
if viewModel.isSpeaking {
    StatusBadge(label: "Speaking", color: .red)
} else if viewModel.isTranslating {
    StatusBadge(label: "Translating", color: .blue)
} else if viewModel.isTranscribing {
    StatusBadge(label: "Transcribing", color: .purple)
} else if viewModel.isSpeechActive {
    StatusBadge(label: "Listening", color: .orange)
} else if viewModel.isCapturing {
    StatusBadge(label: "Capturing", color: .green)
} else {
    StatusBadge(label: "Idle", color: .gray)
}
```

### 4.3 Start button guard — disable if `pairStatus == .unsupported`

```swift
// ContentView.swift — disable start if language pair is unsupported
Button(viewModel.isCapturing ? "Stop" : "Start") {
    Task { await viewModel.toggleCapture() }
}
.disabled(
    viewModel.isStarting ||
    viewModel.languagePairManager.pairStatus == .unsupported
)
```

---

## 5. `ContentView` Integration

```
ContentView (VStack)
├── DeviceSelectionView          ← existing
├── LevelMeterView               ← existing
├── LanguagePairView             ← NEW (F3.2)
├── TranscriptionView            ← UPDATED (shows translation)
├── StatusBadgeView              ← UPDATED (translating state)
└── StartStopButton              ← UPDATED (unsupported guard)
```

---

## 6. File Structure

```
TranslateCall/
├── App/
│   ├── AppContainer.swift           // NEW (F3.1) — owns all pipeline objects
│   ├── TranslationBridge.swift      // REWRITE (F3.1)
│   └── TranslateCallApp.swift       // UPDATE — uses AppContainer
├── Core/
│   └── Translation/
│       ├── TranslationService.swift       // NEW (F3.1)
│       ├── AppleTranslationService.swift  // NEW (F3.1)
│       └── LanguagePairManager.swift      // NEW (F3.2)
└── Features/
    └── Main/
        ├── AudioViewModel.swift           // UPDATE — translation properties + handleTranslation
        ├── ContentView.swift              // UPDATE — embed LanguagePairView
        ├── TranscriptionView.swift        // UPDATE — translation row
        ├── StatusBadgeView.swift          // UPDATE — translating state
        └── LanguagePairView.swift         // NEW (F3.2)

TranslateCallTests/
└── TranslationTests.swift                 // NEW — pipeline + bridge tests
```

---

## 7. Threading and Swift 6 Compliance

| Concern | Solution |
|---------|---------|
| `handleTranslation` suspends in `transcriptionTask` | Intentional — sequential pipeline; Task suspension is safe |
| `isTranslating` set in `transcriptionTask` which is `@MainActor` | `Task { @MainActor in ... }` — mutations on main actor ✓ |
| `translationService.translate()` called from `@MainActor` Task | Actor method called with `await` — correct cross-isolation call |
| `synthesisService?.stopSpeaking()` called from `@MainActor` Task | Actor method called with `await` — correct ✓ |
| `transcriptionTask?.cancel()` in `deactivateSTT` | Cancels the Task; `Task.isCancelled` propagates through `await` points |
| `languagePairManager` read from `@MainActor` | `@MainActor` class — always on main actor ✓ |

---

## 8. Error Handling

| Error | Behavior |
|-------|---------|
| `translationService == nil` | `handleTranslation` is a no-op; STT output shown but not translated |
| `isSpeaking == true` at entry | Segment dropped silently; no error surfaced |
| `translate()` throws `.bridgeUnavailable` | `errorAlert`: "Restart the app." Pipeline remains active. |
| `translate()` throws `.unsupportedPair` | `errorAlert`: "Change languages in settings." |
| `translate()` throws other error | `errorAlert` with `localizedDescription` |
| `stopSpeaking()` during active utterance | Interrupts immediately; `isSpeakingStream` yields `false` |
| Empty transcription result | Skipped via `guard !text.isEmpty` |

---

## 9. End-to-End Latency Budget

| Stage | Typical | Budget |
|-------|---------|--------|
| VAD (speech end detection) | ~256ms | ≤ 512ms |
| STT (Apple Speech) | ~400ms | ≤ 800ms |
| Translation (warm session) | ~12ms | ≤ 50ms |
| `stopSpeaking()` overhead | ~5ms | — |
| TTS schedule first buffer | ~100ms | ≤ 600ms |
| **Total** | **~773ms** | **≤ 2500ms** ✓ |

---

## 10. Future Extensibility (M4)

- **Concurrent bidirectional pipeline**: Replace the single `translationService` with a direction-aware coordinator that dispatches to two service instances.
- **Streaming partial results**: Replace `for await result in transcriptionStream` with streaming STT partials + incremental translation.
- **Full half-duplex (PoC5)**: Replace `guard !isSpeaking` with `HalfDuplexCoordinator` 3-state machine (listening / transitioning / speaking), wired to `AudioManager` mute control and BlackHole routing.
- **`testTTS()` removal**: Fully remove in M3 production build. Keep in `#if DEBUG` until M3 is validated end-to-end.

---

*Gate 2 Review: human must approve this document before tasks.md is written.*
