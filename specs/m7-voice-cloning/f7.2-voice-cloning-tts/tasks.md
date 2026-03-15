# F7.2 — Voice Cloning TTS (Qwen3-TTS): Task Breakdown

> **Feature**: F7.2 — Voice Cloning TTS Integration
> **Milestone**: M7 — Voice Cloning
> **Status**: DRAFT
> **Date**: 2026-03-14
> **Depends on**: design.md (approved)

---

## Overview

8 tasks in dependency order. T0 deletes CSM-1B code. T1–T6 implement the Qwen3-TTS replacement. T7 is integration tests + cleanup. Each task follows TDD (RED → GREEN → REFACTOR) where applicable.

```
T0 (cleanup CSM) ──▶ T1 (SPM + config + protocol)
                          │
                     T2 (QwenCloneClient)
                          │
                     T3 (QwenCloneModelManager + tests)
                          │
                     T4 (QwenCloneSpeechService + tests)
                          │
                     T5 (TTSEngine + TTSEngineSelector + tests)
                          │
                     T6 (UI wiring)
                          │
                     T7 (integration tests + cleanup + commit)
```

---

## T0 — Remove CSM-1B Implementation

**Goal**: Clean slate — delete all CSM-1B code, Python scripts, and tests.

### Steps

1. **Delete source files**:
   - `Core/VoiceCloning/CSMConfiguration.swift`
   - `Core/VoiceCloning/CSMInferring.swift`
   - `Core/VoiceCloning/CSMClient.swift`
   - `Core/VoiceCloning/CSMProcessManager.swift`
   - `Core/VoiceCloning/CSMModelManager.swift`
   - `Core/VoiceCloning/CSMSpeechService.swift`

2. **Delete Python resources**:
   - `Resources/CSM/csm_server.py`
   - `Resources/CSM/setup_csm_env.sh`
   - `Resources/CSM/` directory

3. **Delete test files**:
   - `TranslateCallTests/CSMConfigurationTests.swift`
   - `TranslateCallTests/CSMClientTests.swift`
   - `TranslateCallTests/CSMModelManagerTests.swift`
   - `TranslateCallTests/CSMSpeechServiceTests.swift`
   - `TranslateCallTests/TTSEngineSelectorCSMTests.swift`
   - `TranslateCallTests/Mocks/MockCSMInferrer.swift`

4. **Update existing files** to remove CSM references (compile errors guide you):
   - `TTSEngine.swift` — temporarily keep `.csm` case but rename to `.voiceClone`
   - `TTSEngineSelector.swift` — remove CSM imports, `CSMModelManager` refs, `csmFactory`. Keep `voiceCloningEnabled`, `isCSMDownloading` (rename in T5)
   - `ContentView.swift` — remove CSM download sheet temporarily
   - `AudioViewModel.swift` — remove CSM-specific wiring if any
   - `TTSEngineTests.swift` — update `.csm` → `.voiceClone`

5. **Verify build**: `xcodebuild build` must succeed with 0 errors.

### Acceptance

- All CSM files deleted, no CSM references remain in codebase.
- Build succeeds.
- Existing non-CSM tests still pass.

---

## T1 — SPM Integration + Configuration + Protocol

**Goal**: Add `mlx-audio-swift` package, create config and protocol.

### Steps

1. **Add SPM dependency** to `TranslateCall.xcodeproj`:
   - URL: `https://github.com/Blaizzy/mlx-audio-swift.git`
   - Version: from `0.30.6`
   - Link products: `MLXAudioTTS`, `MLXAudioCore` to TranslateCall target

2. **Create `QwenCloneConfiguration.swift`**:
   - `modelRepo: String` (default: `"mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"`)
   - `maxTokens`, `temperature`, `topP`, `repetitionPenalty`
   - `inferenceTimeoutSeconds: Int = 10`
   - `textTruncationLimit: Int = 200`
   - `static func language(for: Locale) -> String?` — maps locale → Qwen3 language string
   - `static func supportsLocale(_: Locale) -> Bool`
   - `static let voiceCloningEnabledKey`
   - `nonisolated(unsafe) static let default`

3. **Create `QwenCloneInferring.swift`** (protocol):
   ```swift
   protocol QwenCloneInferring: Actor {
       func synthesize(
           text: String,
           referenceAudio: [Float],
           referenceTranscript: String,
           language: String
       ) async throws -> [Float]
       var sampleRate: Int { get }
   }
   ```

4. **Create `QwenCloneError.swift`** (or include in config file):
   - `.modelNotReady`, `.inferenceTimeout`, `.downloadFailed(String)`, `.unsupportedLocale`

5. **Verify build** with mlx-audio-swift linked.

### Tests

```swift
@Suite @MainActor struct QwenCloneConfigurationTests {
    @Test func defaultModelRepo() { ... }
    @Test func languageMappingEnglish() { ... }
    @Test func languageMappingSpanish() { ... }
    @Test func supportsLocaleEnglish() { ... }
    @Test func supportsLocaleSpanish() { ... }
    @Test func unsupportedLocaleHindi() { ... }
    @Test func allSupportedLanguagesCount() { ... }
}
```

### Acceptance

- `mlx-audio-swift` builds as part of TranslateCall (SPM resolution + compile).
- 7 configuration tests pass.
- Protocol compiles.

---

## T2 — QwenCloneClient (Production Inferrer)

**Goal**: Wrap `mlx-audio-swift`'s `SpeechGenerationModel` in our `QwenCloneInferring` protocol.

### Steps

1. **Create `QwenCloneClient.swift`**:
   - Actor conforming to `QwenCloneInferring`
   - Holds `any SpeechGenerationModel` from mlx-audio-swift
   - `synthesize()`: convert `[Float]` → `MLXArray`, call `model.generate()`, convert output → `[Float]`
   - `sampleRate` from model (24000)

2. **Import**: `import MLXAudioTTS`, `import MLXAudioCore`, `import MLX`

### Tests

No automated tests for this class (requires real model). Verified via T7 integration tests.

### Acceptance

- Compiles successfully with mlx-audio-swift types.
- Conforms to `QwenCloneInferring` protocol.

---

## T3 — QwenCloneModelManager + Tests

**Goal**: Singleton actor managing model lifecycle (download → load → ready).

### Steps

1. **Create `QwenCloneModelManager.swift`**:
   - Actor singleton (`static let shared`)
   - State machine: `.idle` → `.downloading` → `.loading` → `.ready` / `.failed(String)`
   - `stateStream: AsyncStream<ModelState>` (nonisolated let)
   - `ensureReady()` — coalesces concurrent callers via shared `loadTask`
   - `getInferrer() throws -> QwenCloneClient` — returns client when ready
   - `unload()` — nil model + inferrer, clear MLX cache, transition to idle
   - `isModelCached() -> Bool` — check HuggingFace cache directory
   - Private `startSetup()`: calls `TTS.loadModel(modelRepo:)`, creates `QwenCloneClient`

2. **Factory init** for test injection:
   ```swift
   init(config: QwenCloneConfiguration = .default,
        modelLoader: ((String) async throws -> any SpeechGenerationModel)? = nil)
   ```

### Tests

```swift
@Suite @MainActor struct QwenCloneModelManagerTests {
    @Test func initialStateIsIdle() async { ... }
    @Test func getInferrerThrowsWhenNotReady() async { ... }
    @Test func unloadTransitionsToIdle() async { ... }
    @Test func isModelCachedReturnsFalseForFreshInstall() async { ... }
    @Test func stateStreamEmitsTransitions() async { ... }
}
```

### Acceptance

- 5 tests pass.
- State machine transitions verified via `stateStream`.

---

## T4 — QwenCloneSpeechService + Tests

**Goal**: `SynthesisService`-conforming actor for voice-cloned synthesis.

### Steps

1. **Create `QwenCloneSpeechService.swift`**:
   - Actor conforming to `SynthesisService`
   - Same audio engine pattern as `KokoroSpeechService` (AVAudioEngine + PlayerNode + MixerNode)
   - Dependencies: `any QwenCloneInferring`, `any VoiceProfileStoring`, `activeProfileId: UUID`, `config: QwenCloneConfiguration`
   - `speak(text:locale:)`: decrypt profile, get language from locale, call inferrer, play audio
   - `stopSpeaking()`: cancel, clear queue, stop player
   - `deactivate()`: stop engine
   - Text truncation at 200 chars (same helper as CSM version)
   - 10-second inference timeout via `withThrowingTaskGroup`
   - Metrics recording to `TTSMetricsCollector` with `.voiceClone` engine

2. **Create `MockQwenCloneInferrer.swift`** in test target:
   - Actor conforming to `QwenCloneInferring`
   - Configurable: `stubSamples`, `stubError`, `delay`
   - Tracks: `callCount`, `lastText`, `lastLanguage`, `lastReferenceAudioCount`

### Tests

```swift
@Suite(.serialized) @MainActor struct QwenCloneSpeechServiceTests {
    @Test func speakCallsInferrerWithProfileContext() async throws { ... }
    @Test func textTruncatedAt200Chars() async throws { ... }
    @Test func emptyTextIgnored() async throws { ... }
    @Test func stopClearsQueue() async throws { ... }
    @Test func inferenceErrorContinuesQueue() async throws { ... }
    @Test func conformsToSynthesisServiceProtocol() async throws { ... }
    @Test func languagePassedToInferrer() async throws { ... }
    @Test func inferenceTimeoutRecovery() async throws { ... }
}
```

### Acceptance

- 8 tests pass.
- `SynthesisService` protocol fully satisfied.
- Language parameter correctly derived from locale.

---

## T5 — TTSEngine + TTSEngineSelector + Tests

**Goal**: Update engine enum and selector for Qwen3-TTS routing.

### Steps

1. **Update `TTSEngine.swift`**:
   - Rename `.csm` → `.voiceClone` (if not done in T0)
   - `displayName`: "Voice Clone"
   - `supports(locale:)`: use `QwenCloneConfiguration.supportsLocale(locale)`

2. **Update `TTSEngineSelector.swift`**:
   - Rename: `csmAvailable` → `qwenCloneAvailable`
   - Rename: `isCSMDownloading` → `isVoiceCloneDownloading`
   - Remove: `csmFactory` closure (replace with async approach or keep factory pattern)
   - Update `makeOutgoingService()`:
     - Voice Clone supports 10 languages (not just English)
     - Use `QwenCloneConfiguration.supportsLocale(locale)`
   - Update `enableVoiceCloning()`: call `QwenCloneModelManager.shared.ensureReady()`
   - Update `disableVoiceCloning()`: call `QwenCloneModelManager.shared.unload()`
   - Update `observeCSMModelManager()` → `observeQwenCloneModelManager()`
   - Add factory: `voiceCloneFactory: (AudioDeviceID?, UUID, any VoiceProfileStoring) throws -> any SynthesisService`

3. **Update `TTSEngineTests.swift`**:
   - `.csm` → `.voiceClone`
   - Add `supports(locale:)` tests for Spanish, French, etc.

### Tests

```swift
@Suite @MainActor struct TTSEngineSelectorVoiceCloneTests {
    @Test func voiceCloningActiveRequiresAllThree() { ... }
    @Test func makeOutgoingReturnsVoiceCloneWhenActive() throws { ... }
    @Test func makeOutgoingFallsBackForUnsupportedLocale() throws { ... }
    @Test func makeOutgoingUsesKokoroWhenCloningDisabled() throws { ... }
    @Test func voiceCloneSupportsSpanish() throws { ... }
}
```

### Acceptance

- 5 selector tests pass.
- Engine priority chain verified: VoiceClone > Kokoro > AVSpeech.
- Voice Clone routes for all 10 supported languages.

---

## T6 — UI Wiring

**Goal**: Update ContentView, LanguagePairView, AudioViewModel for Qwen3-TTS.

### Steps

1. **`ContentView.swift`**:
   - Rename `showCSMDownload` → `showVoiceCloneDownload`
   - Rename `isCSMDownloading` → `isVoiceCloneDownloading`
   - Update download sheet text: "Downloading Voice Clone Model\n(~2 GB · one-time download)"
   - "Cloning ON" badge unchanged

2. **`LanguagePairView.swift`**:
   - Engine picker: no changes needed (already uses `TTSEngine.allCases`)
   - Verify `enableVoiceCloning()` / `disableVoiceCloning()` calls work

3. **`AudioViewModel.swift`**:
   - Same `bindVoiceProfileManager()` pattern (profileStore injection, activeProfileId sink)
   - Update property names if renamed in TTSEngineSelector

4. **`AppContainer.swift`**:
   - Minimal changes (same wiring)

5. **Window height**: verify 680 still sufficient

### Tests

No new automated tests — UI verified manually in T7.

### Acceptance (manual)

- Voice Clone button in TTS picker works
- Download sheet appears when first enabling
- "Cloning ON" badge shows when model ready + profile active
- Cancel on download sheet reverts to standard TTS

---

## T7 — Integration Tests + Cleanup + Commit

**Goal**: Full regression, SwiftLint, manual testing, commit.

### Steps

1. **SwiftLint cleanup** on all new files:
   - `Core/VoiceCloning/QwenClone*.swift`
   - `TranslateCallTests/QwenClone*.swift`
   - Line length ≤ 120, no trailing commas, `import Foundation` in test files

2. **Full test suite regression**:
   ```bash
   xcodebuild test \
     -project TranslateCall.xcodeproj \
     -scheme TranslateCall \
     -destination 'platform=macOS' \
     -only-testing:TranslateCallTests \
     CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
   ```
   Known flaky: `sileroVADMaxDuration` (pre-existing).

3. **Manual testing checklist**:
   - [ ] Build succeeds with NO Python dependency
   - [ ] Select "Voice Clone" → download sheet appears (~2 GB)
   - [ ] Download completes → "Cloning ON" badge visible
   - [ ] Speak English → voice-cloned synthesis
   - [ ] Speak Spanish → voice-cloned synthesis (cross-lingual!)
   - [ ] Speak unsupported language → falls back to AVSpeech
   - [ ] Disable voice cloning → model unloaded, standard TTS resumes
   - [ ] Delete active profile → cloning disabled automatically
   - [ ] Change active profile → next utterance uses new profile
   - [ ] 10s inference timeout → fallback gracefully
   - [ ] Quit and relaunch → cloning state restored
   - [ ] Voice Profiles sheet has "Done" button to close

4. **Commit** all changes.

### Acceptance

- All unit tests pass (T1–T5: ≥ 25 tests).
- SwiftLint: 0 errors, 0 warnings on new files.
- Existing test suite: 0 regressions.
- Manual checklist: all items checked.
- Clean commit with descriptive message.

---

## Summary Table

| Task | New Files | Modified Files | New Tests | REQ Coverage |
|------|-----------|---------------|-----------|-------------|
| T0 | — | TTSEngine, TTSEngineSelector, ContentView, AudioViewModel, TTSEngineTests | 0 | Cleanup |
| T1 | `QwenCloneConfiguration.swift`, `QwenCloneInferring.swift` | — | 7 | VC-16,17 (locale) |
| T2 | `QwenCloneClient.swift` | — | 0 (manual) | VC-09 |
| T3 | `QwenCloneModelManager.swift` | — | 5 | VC-01–08, NF-01,10 |
| T4 | `QwenCloneSpeechService.swift`, `MockQwenCloneInferrer.swift` | — | 8 | VC-09–15,22–27, NF-06,07,09 |
| T5 | `TTSEngineSelectorVoiceCloneTests.swift` | `TTSEngine.swift`, `TTSEngineSelector.swift` | 5 | VC-16–21, NF-04 |
| T6 | — | `ContentView.swift`, `LanguagePairView.swift`, `AudioViewModel.swift` | 0 (manual) | VC-21 |
| T7 | — | — | 0 (regression) | AC-01–14 |
| **Total** | **5 new** | **~8 modified** | **≥ 25** | **All REQs** |

---

## Key Differences from CSM-1B Tasks

| Aspect | CSM-1B (old) | Qwen3-TTS (new) |
|--------|-------------|-----------------|
| Tasks | 10 (T0–T9) | **8** (T0–T7) |
| New files | 8 + 2 Python | **5** (Swift only) |
| Deleted files | — | 6 source + 2 Python + 6 tests |
| Python/subprocess | CSMProcessManager, CSMClient, csm_server.py, setup_csm_env.sh | **None** |
| HTTP client | CSMClient (POST /synthesize) | **None** (in-process MLX) |
| Language support | English only | **10 languages** |
| Test complexity | Mock HTTP responses, process lifecycle | **Simpler** — mock protocol only |

---

*Implementation begins with T0 (cleanup). Each task should be verified with `xcodebuild build` before moving to the next.*
