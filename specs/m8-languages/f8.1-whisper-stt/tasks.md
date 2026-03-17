# F8.1 — WhisperKit STT Integration — Tasks

## Dependency Graph

```
T1 (WhisperConfiguration + WhisperLanguages)
 │
 ├──▶ T2 (WhisperModelManager)
 │        │
 │        ▶ T3 (WhisperSpeechService)
 │
 ├──▶ T4 (STTEngine + STTEngineSelector changes)
 │        │
 │        ▶ T5 (UI: engine picker + download sheet + model size)
 │
 └──▶ T6 (Tests)
```

**Recommended order**: T1 → T2 → T3 → T4 → T5 → T6

**Pre-requisite**: Add WhisperKit SPM dependency before starting T1.

---

## T0 — Add WhisperKit SPM Dependency

**File**: Xcode project (SPM)

**Steps**:
1. In Xcode: File → Add Package Dependencies
2. URL: `https://github.com/argmaxinc/WhisperKit.git`
3. Version rule: Up to Next Minor (pin to latest 0.9.x)
4. Add `WhisperKit` product to TranslateCall target
5. Verify build succeeds with the new dependency

**Acceptance**:
- `import WhisperKit` compiles
- Build succeeds with zero new warnings from our code

---

## T1 — Create `WhisperConfiguration` and `WhisperLanguages`

**Files**:
- `TranslateCall/Core/STT/WhisperConfiguration.swift` (NEW)
- `TranslateCall/Core/STT/WhisperLanguages.swift` (NEW)

**Steps**:

### WhisperConfiguration.swift
1. Create `WhisperModelSize: String, Codable, Sendable, CaseIterable` enum with cases: `.tiny`, `.base`, `.small`, `.medium`, `.largeV3`
2. Add computed properties:
   - `whisperKitName: String` — maps to WhisperKit model identifiers (e.g. `"openai_whisper-base"`)
   - `approximateSizeMB: Int` — 75, 150, 500, 1500, 3000
   - `qualityDescription: String` — "Fastest", "Real-time", "Good", "High", "Best"
3. Create `WhisperConfiguration: Sendable` struct with:
   - `modelSize: WhisperModelSize = .base`
   - `language: String? = nil` (nil = auto-detect)
   - `beamSize: Int = 5`
   - `noSpeechThreshold: Float = 0.6`
   - `nonisolated static let \`default\` = WhisperConfiguration()`

### WhisperLanguages.swift
1. Create `WhisperLanguages` enum with `static let supported: Set<String>` containing all 99 Whisper language codes
2. Add `static func supports(_ locale: Locale) -> Bool` — checks `locale.language.languageCode?.identifier` against `supported`
3. Add `static func whisperCode(for locale: Locale) -> String?` — returns the Whisper language code for a locale

**Acceptance**:
- `WhisperLanguages.supports(Locale(identifier: "uk"))` returns `true`
- `WhisperLanguages.supports(Locale(identifier: "en"))` returns `true`
- `WhisperModelSize.base.approximateSizeMB == 150`

---

## T2 — Create `WhisperModelManager`

**File**: `TranslateCall/Core/STT/WhisperModelManager.swift` (NEW)

**Steps**:
1. Create `actor WhisperModelManager` with `static let shared = WhisperModelManager()`
2. State properties (private(set)):
   - `isReady: Bool = false`
   - `isDownloading: Bool = false`
   - `downloadProgress: Double = 0`
   - `currentModelSize: WhisperModelSize = .base`
   - `loadError: Error? = nil`
3. Private storage:
   - `pipe: WhisperKit?`
   - `loadTask: Task<WhisperKit, Error>?`
4. `ensureReady(config: WhisperConfiguration = .default) async throws -> WhisperKit`:
   - If `pipe` exists and model size matches, return it
   - If `loadTask` exists, await and return (task coalescing)
   - Otherwise, create new task:
     - Set `isDownloading = true`, `currentModelSize = config.modelSize`
     - Init `WhisperKit(WhisperKitConfig(model: config.modelSize.whisperKitName))`
     - WhisperKit auto-downloads from HuggingFace if needed
     - Set `pipe`, `isReady = true`, `isDownloading = false`
     - Return pipe
   - On error: set `loadError`, `isDownloading = false`, rethrow
5. `unloadModel()`:
   - Set `pipe = nil`, `loadTask = nil`, `isReady = false`
6. Inject `pipeFactory: @Sendable (WhisperModelSize) async throws -> WhisperKit` for testing
   - Default: `{ size in try await WhisperKit(WhisperKitConfig(model: size.whisperKitName)) }`
   - Tests inject mock

**Acceptance**:
- Task coalescing: two concurrent `ensureReady()` calls result in one load
- `unloadModel()` resets all state
- `isReady` is `true` after successful load

---

## T3 — Create `WhisperSpeechService`

**File**: `TranslateCall/Core/STT/WhisperSpeechService.swift` (NEW)

**Steps**:
1. Create `actor WhisperSpeechService: SpeechRecognizerService`
2. Protocol conformance:
   - `nonisolated let transcriptionStream: AsyncStream<TranscriptionResult>`
   - `nonisolated private(set) var locale: Locale`
3. Private state:
   - `continuation: AsyncStream<TranscriptionResult>.Continuation?`
   - `processingTask: Task<Void, Never>?`
   - `pipe: WhisperKit?`
   - `config: STTConfiguration`
   - `whisperConfig: WhisperConfiguration`
   - `pipeFactory: @Sendable () async throws -> WhisperKit`
4. Init:
   ```swift
   init(
       locale: Locale,
       config: STTConfiguration = .default,
       whisperConfig: WhisperConfiguration = .default,
       pipeFactory: @Sendable @escaping () async throws -> WhisperKit = {
           try await WhisperModelManager.shared.ensureReady()
       }
   )
   ```
   - Set up `transcriptionStream` + `continuation` via `AsyncStream.makeStream()`
5. `activate(stream: AsyncStream<SpeechSegment>) async throws`:
   - Lazy-load pipe via `pipeFactory()` on first call (retain for reuse)
   - Start `processingTask` that iterates over speech segments
   - For each segment: call `transcribeSegment(_:)`
6. `transcribeSegment(_ segment: SpeechSegment)`:
   - Extract `Float` array from `segment.audio` (AVAudioPCMBuffer → `[Float]`)
   - Truncate to 480,000 samples (30s) if needed
   - Build `DecodingOptions` with language from locale
   - Call `pipe.transcribe(audioArray: samples, decodeOptions: options)`
   - Extract text and confidence from result
   - Record STT metrics
   - If confidence >= `config.minimumConfidence`, emit `TranscriptionResult` via continuation
7. `deactivate() async`:
   - Cancel `processingTask`, set to nil
8. `setLocale(_ locale: Locale) async`:
   - Update `self.locale` (Whisper uses this in DecodingOptions on next transcription)

**Acceptance**:
- Conforms to `SpeechRecognizerService` protocol
- Emits `TranscriptionResult` for valid speech
- Filters out low-confidence results
- Truncates segments > 30s

---

## T4 — Update `STTEngine` and `STTEngineSelector`

**Files**:
- `TranslateCall/Core/STT/STTEngine.swift` (MODIFY)
- `TranslateCall/Core/STT/STTEngineSelector.swift` (MODIFY)

**Steps**:

### STTEngine.swift
1. Add `.whisper` case to `STTEngine` enum
2. Update `displayName`: `.whisper` → `"Whisper"`
3. Update `supports(locale:)`: `.whisper` → `WhisperLanguages.supports(locale)`

### STTEngineSelector.swift
1. Add published properties:
   - `@Published var whisperAvailable: Bool = false`
   - `@Published var isWhisperDownloading: Bool = false`
2. Add factory property:
   - `private let whisperFactory: (Locale) -> any SpeechRecognizerService`
3. Update init to accept `whisperFactory` (with default: `{ WhisperSpeechService(locale: $0) }`)
4. Update `makeOutgoingService(for:)`:
   - Add Whisper check before Parakeet: if `preferredEngine == .whisper && whisperAvailable && STTEngine.whisper.supports(locale: locale)` → return `whisperFactory(locale)`
5. Update `makeIncomingService(for:)`:
   - Add Whisper check: if `preferredEngine == .whisper && whisperAvailable && STTEngine.whisper.supports(locale: locale)` → return `whisperFactory(locale)`
   - (Unlike Parakeet, Whisper can serve incoming too)
6. Add `downloadWhisperModel()` and `unloadWhisperModel()` methods (delegate to `WhisperModelManager`)
7. Update `usingFallback` to account for Whisper:
   ```swift
   var usingFallback: Bool {
       switch preferredEngine {
       case .parakeet: return !parakeetAvailable || !currentSourceLocale.isEnglish
       case .whisper:  return !whisperAvailable || !STTEngine.whisper.supports(locale: currentSourceLocale)
       case .appleSpeech: return false
       }
   }
   ```

**Acceptance**:
- `STTEngine.allCases` contains `.whisper`
- Selector routes to Whisper for both outgoing and incoming when preferred
- Falls back to Apple Speech when Whisper unavailable

---

## T5 — UI: Engine Picker, Download Sheet, Model Size Selector

**Files**:
- `TranslateCall/Features/Main/LanguagePairView.swift` (MODIFY)
- `TranslateCall/Features/Main/ContentView.swift` (MODIFY — add Whisper download sheet)
- `TranslateCall/Features/STT/WhisperModelSizeView.swift` (NEW — optional, could be inline)

**Steps**:

### LanguagePairView.swift
1. Add `"Whisper"` option to STT engine Picker:
   ```swift
   Text("Whisper").tag(STTEngine.whisper)
   ```
2. Add fallback badge for Whisper (same pattern as Parakeet):
   ```swift
   if engineSelector.preferredEngine == .whisper && engineSelector.usingFallback {
       Text("Using Apple Speech").font(.caption2).foregroundStyle(.secondary)
   }
   ```

### ContentView.swift
1. Add Whisper download sheet trigger (same pattern as Kokoro/Parakeet):
   ```swift
   .sheet(isPresented: $showWhisperDownload) {
       WhisperDownloadSheet(selector: engineSelector)
   }
   ```
2. Show sheet when Whisper is selected but not available

### WhisperDownloadSheet (inline or separate file)
1. Model size picker with radio buttons showing: name, size, quality, speed
2. Download button with progress bar
3. Default selection: `.base`
4. Cancel button

**Acceptance**:
- Whisper appears in engine picker
- Download sheet appears when Whisper is selected and model not ready
- Model size is selectable before download
- Fallback badge appears when Whisper unavailable

---

## T6 — Tests

**File**: `TranslateCallTests/WhisperSTTTests.swift` (NEW)

**Tests**:

### WhisperConfiguration & Languages
1. `testDefaultConfiguration` — verify defaults (modelSize .base, language nil, beamSize 5)
2. `testModelSizeWhisperKitName` — verify all sizes map to correct names
3. `testModelSizeApproximateSize` — verify MB values
4. `testWhisperLanguagesSupportsUkrainian` — `supports(Locale(identifier: "uk"))` → true
5. `testWhisperLanguagesSupportsEnglish` — true
6. `testWhisperLanguagesRejectsUnsupported` — `supports(Locale(identifier: "xx"))` → false
7. `testWhisperCodeForLocale` — `whisperCode(for: Locale(identifier: "uk"))` → "uk"

### WhisperModelManager
8. `testEnsureReadyCallsFactory` — mock factory is called
9. `testTaskCoalescing` — two concurrent ensureReady() calls result in one factory call
10. `testUnloadResetsState` — after unload, isReady is false, pipe is nil
11. `testEnsureReadyReturnsExistingPipe` — second call returns cached pipe without factory call

### WhisperSpeechService
12. `testActivateLoadsPipe` — pipe factory is called on first activate
13. `testTranscriptionEmitted` — mock pipe returns result, service emits TranscriptionResult
14. `testLowConfidenceFiltered` — result below minimumConfidence is not emitted
15. `testSetLocaleUpdatesLocale` — locale changes after setLocale()
16. `testDeactivateCancelsProcessing` — processingTask is cancelled

### STTEngineSelector (Whisper additions)
17. `testWhisperSupportsUkrainian` — `STTEngine.whisper.supports(locale: Locale(identifier: "uk"))` → true
18. `testSelectorRoutesToWhisperOutgoing` — preferred .whisper + available → whisperFactory called
19. `testSelectorRoutesToWhisperIncoming` — preferred .whisper + available → whisperFactory called for incoming too
20. `testSelectorFallsBackWhenWhisperUnavailable` — preferred .whisper + not available → appleSpeechFactory called
21. `testUsingFallbackWhisper` — preferred .whisper + unavailable → usingFallback == true

**Acceptance**:
- All 21 tests pass
- Zero warnings
- No real model download in tests (mock factory)
