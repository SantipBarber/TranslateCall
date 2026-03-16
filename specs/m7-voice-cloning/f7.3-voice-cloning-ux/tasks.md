# F7.3 — Voice Cloning UX: Task Breakdown

> **Feature**: F7.3 — Voice Cloning UX
> **Milestone**: M7 — Voice Cloning
> **Status**: DRAFT
> **Date**: 2026-03-15
> **Depends on**: design.md (approved)

---

## Overview

5 tasks. T1 creates the preview service. T2 adds demo text localization. T3 builds the preview UI. T4 enhances ContentView. T5 is cleanup + regression.

```
T1 (VoicePreviewService) ──▶ T2 (demo text) ──▶ T3 (preview UI)
                                                       │
                                                  T4 (ContentView polish)
                                                       │
                                                  T5 (cleanup + commit)
```

---

## T1 — VoicePreviewService

**Goal**: Actor managing standalone preview synthesis and training audio playback.

### Steps

1. **Create `VoicePreviewService.swift`** in `Core/VoiceCloning/`:
   - Actor with separate `AVAudioEngine` + `AVAudioPlayerNode` + `AVAudioMixerNode`
   - `PreviewState` enum: `.idle`, `.loadingModel`, `.synthesizing(mode)`, `.playing(mode)`, `.error(String)`
   - `VoicePreviewMode` enum: `.cloned`, `.standard`, `.abComparison`, `.recording`
   - `stateStream: AsyncStream<PreviewState>` (nonisolated let)
   - `previewClone(profileId:text:language:)` — load profile, get inferrer from QwenCloneModelManager, synthesize, play
   - `compareAB(profileId:text:locale:)` — synthesize standard (AVSpeechSynthesizer.write), pause, synthesize cloned, play both
   - `playRecording(profileId:)` — decrypt profile, convert samples to PCMBuffer, play
   - `stop()` — cancel inference task, stop playerNode, transition to idle
   - `makePCMBuffer(from:)` — same 24kHz→device SRC pattern as QwenCloneSpeechService
   - Disable when `AudioCoordinator.isCapturing` is true (REQ-UX-NF-04)

2. **Audio engine setup**: same `nonisolated func setupAudioEngineNonisolated()` pattern, uses default output (no deviceID routing)

3. **Standard TTS for A/B**: use `AVSpeechSynthesizer.write(_:toBufferCallback:)` to collect PCM → play through same playerNode. No `AVSpeechService` dependency — direct AVFoundation use.

### Tests

```swift
@Suite @MainActor struct VoicePreviewServiceTests {
    @Test func initialStateIsIdle() async { ... }
    @Test func stopTransitionsToIdle() async { ... }
    @Test func playRecordingPlaysFromProfile() async throws { ... }
    @Test func previewCloneRequiresModel() async throws { ... }
    @Test func stateStreamEmitsTransitions() async { ... }
}
```

### Acceptance
- 5 tests pass
- Preview service compiles and transitions states correctly

---

## T2 — Demo Text Localization

**Goal**: Localized demo sentences for all 10 Qwen3-TTS languages.

### Steps

1. **Add `demoText(for:)` to `QwenCloneConfiguration`**: static method returning localized demo sentence per language string.

2. **Add `supportedLanguageList`**: array of `(key: String, label: String)` tuples for the language picker UI.

### Tests

```swift
// Add to QwenCloneConfigurationTests
@Test func demoTextEnglishIsNotEmpty() { ... }
@Test func demoTextAllLanguagesNonEmpty() { ... }
@Test func supportedLanguageListHas10Entries() { ... }
```

### Acceptance
- 3 new tests pass
- All 10 demo texts are meaningful sentences (not placeholders)

---

## T3 — VoicePreviewSection + VoiceProfileDetailView Enhancement

**Goal**: Preview UI with language picker, demo text, action buttons, and status.

### Steps

1. **Create `VoicePreviewSection.swift`** in `Features/VoiceCloning/`:
   - `@State private var previewState: VoicePreviewService.PreviewState`
   - `@State private var selectedLanguage: String`
   - `@State private var customText: String`
   - Language picker (10 languages from `QwenCloneConfiguration.supportedLanguageList`)
   - Editable demo text field (placeholder = localized default)
   - Three buttons: Preview, Compare A/B, Stop
   - Status label showing current playback mode
   - Buttons disabled when session is active (via `isSessionActive` closure)

2. **Update `VoiceProfileDetailView.swift`**:
   - Add `VoicePreviewSection` below profile header
   - Add "Play Recording" button with play/stop icon toggle
   - Move quality metrics below preview section
   - Inject `VoicePreviewService` from environment or create locally

3. **Wire state observation**: `.task` that observes `previewService.stateStream` and updates `@State previewState`

### Tests

No automated tests (SwiftUI views). Manual verification in T5.

### Acceptance (manual)
- Preview section visible in VoiceProfileDetailView
- Language picker shows 10 languages
- Demo text updates when language changes
- All three buttons (Preview, Compare, Stop) are functional
- Play Recording works independently of model

---

## T4 — ContentView Polish

**Goal**: Fallback label and language info in voice profile row.

### Steps

1. **Update voice profile row** in `ContentView.swift`:
   - Show "Cloning ON" when `voiceCloningActive` (already working)
   - Show "Fallback — [lang] not supported" when cloning enabled but locale unsupported
   - Access target locale from `viewModel.ttsEngineSelector.currentTargetLocale`

2. **Verify window height** — ensure 680 is still sufficient with all elements

### Tests

No automated tests. Manual verification in T5.

### Acceptance (manual)
- Fallback label shows for unsupported languages (e.g., Hindi)
- Label hides when switching to supported language
- Window layout fits at 680pt height

---

## T5 — Cleanup + Regression + Commit

**Goal**: SwiftLint, full test suite, manual testing, commit.

### Steps

1. **SwiftLint** on all new/modified files
2. **Full test suite regression**
3. **Manual testing checklist**:
   - [ ] Preview Voice plays cloned audio for English
   - [ ] Preview Voice plays cloned audio for Spanish (cross-lingual)
   - [ ] Compare A/B plays standard then cloned
   - [ ] Play Recording plays original training audio
   - [ ] Language picker changes demo text
   - [ ] Custom text overrides demo text
   - [ ] Stop button halts playback
   - [ ] Preview disabled during active session
   - [ ] Fallback label for unsupported language
   - [ ] "Cloning ON" badge visible
   - [ ] Model auto-loads if needed for preview
4. **Commit**

### Acceptance
- All unit tests pass (≥ 8 new)
- SwiftLint: 0 errors on new files
- Manual checklist complete

---

## Summary Table

| Task | New Files | Modified Files | New Tests |
|------|-----------|---------------|-----------|
| T1 | `VoicePreviewService.swift` | — | 5 |
| T2 | — | `QwenCloneConfiguration.swift` | 3 |
| T3 | `VoicePreviewSection.swift` | `VoiceProfileDetailView.swift` | 0 (manual) |
| T4 | — | `ContentView.swift` | 0 (manual) |
| T5 | — | — | 0 (regression) |
| **Total** | **2 new** | **~3 modified** | **≥ 8** |

---

*Implementation begins with T1. Each task verified with `xcodebuild build` before proceeding.*
