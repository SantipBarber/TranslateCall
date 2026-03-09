# F2.2: Speech-to-Text — Technical Design

**Feature**: Speech-to-Text Integration
**Milestone**: M2 — Speech Pipeline
**Status**: DRAFT — awaiting Gate 2 review
**Date**: 2026-03-07
**Prerequisites**: requirements.md (Gate 1 approved)

---

## 0. SpeechAnalyzer (macOS 26+) — Future Path

> **Cupertino + Tavily finding (WWDC25)**: Apple introduced `SpeechAnalyzer` (`final actor SpeechAnalyzer`) as the modern replacement for `SFSpeechRecognizer`. Available macOS 26+ / iOS 26+ only.

Our deployment target is **macOS 15.0** → `SFSpeechRecognizer` is required. However, `SpeechAnalyzer` natively uses actors and `AsyncSequence` — an architecture identical to our `SpeechRecognizerService` protocol. In **M6 (Enhanced STT)**, adding `SpeechAnalyzerService: SpeechRecognizerService` with `@available(macOS 26, *)` requires zero protocol changes.

Migration pattern (M6):
```swift
// M6: progressive enhancement
if #available(macOS 26, *) {
    service = try await SpeechAnalyzerService(locale: locale, config: config)
} else {
    service = try await AppleSpeechService(locale: locale, config: config)
}
```

---

## 1. Key Design Decisions

### 1.1 Actor-based protocol, one recognizer per locale

`SpeechRecognizerService` is an actor protocol (same pattern as `VADService`). The Apple implementation holds one `SFSpeechRecognizer` per active locale. Recognizers are created lazily and cached; switching locale creates a new recognizer but retains the old one to allow in-flight tasks to complete.

### 1.2 Segment-at-a-time recognition (not streaming)

VAD gives us complete utterances as `SpeechSegment`. We submit each as a discrete `SFSpeechAudioBufferRecognitionRequest`:
```
request = SFSpeechAudioBufferRecognitionRequest()
request.shouldReportPartialResults = false
request.requiresOnDeviceRecognition = true   // when supported
request.append(segment.audio)
request.endAudio()
```
This is simpler than streaming, produces a single final result per segment, and avoids the complexity of managing an open microphone tap inside the recognizer.

### 1.3 Async bridge via `withCheckedThrowingContinuation`

`SFSpeechRecognizer.recognitionTask(with:resultHandler:)` uses a callback. We bridge it to `async throws` using `withCheckedThrowingContinuation`. The continuation is resumed once (on final result or error).

```swift
let result = try await withCheckedThrowingContinuation { continuation in
    let task = recognizer.recognitionTask(with: request) { result, error in
        if let error { continuation.resume(throwing: error); return }
        guard let result, result.isFinal else { return }
        continuation.resume(returning: result)
    }
    activeTask = task
}
```

### 1.4 Confidence from word segments

`SFSpeechRecognitionResult` does not expose utterance-level confidence directly. We compute it as the mean of `bestTranscription.segments.map(\.confidence)`. Empty segment array → confidence = 0.0 → discarded.

### 1.5 On-device recognition preferred

`SFSpeechRecognitionRequest.requiresOnDeviceRecognition = true` is set when `SFSpeechRecognizer.supportsOnDeviceRecognition` is `true` for the locale. If not supported, we fall back to cloud silently (no user-visible change). This satisfies REQ-NFR-STT-02.

---

## 2. Architecture Overview

```
VADService.speechSegments              SpeechRecognizerService
AsyncStream<SpeechSegment>             actor AppleSpeechService
        │                              ┌─────────────────────────────┐
        │   activate(stream:) ────────▶│  processingTask             │
        │                              │  for await segment in stream│
        │                              │    ┌──────────────────────┐ │
        │                              │    │ SFSpeechRecognizer   │ │
        └─────── SpeechSegment ───────▶│    │ .recognitionTask(..) │ │
                                       │    └──────────────────────┘ │
                                       │    → TranscriptionResult?    │
                                       │    (if confidence ≥ 0.60)   │
                                       └──────────┬──────────────────┘
                                                  │
                                    AsyncStream<TranscriptionResult>
                                          │
                                    AudioViewModel (@MainActor)
                                    @Published latestTranscription: String?
                                    @Published isTranscribing: Bool
```

---

## 3. Type Definitions

### 3.1 `TranscriptionResult`

```swift
/// A finalized speech recognition result for one utterance.
struct TranscriptionResult: Sendable {
    /// Recognized text (bestTranscription.formattedString).
    let text: String
    /// Mean word-level confidence (0.0 – 1.0).
    let confidence: Float
    /// Locale used for recognition.
    let locale: Locale
    /// Wall-clock time when speech started (from SpeechSegment.capturedAt).
    let capturedAt: Date
    /// Duration of the audio that was recognized, in seconds.
    let audioDuration: TimeInterval
}
```

### 3.2 `STTError`

```swift
enum STTError: LocalizedError {
    case permissionDenied
    case recognizerUnavailable(Locale)
    case recognitionFailed(Error)
}
```

### 3.3 `STTConfiguration`

```swift
struct STTConfiguration: Sendable {
    /// Minimum mean word confidence to emit a result (default: 0.60).
    var minimumConfidence: Float = 0.60
    /// Prefer on-device recognition when available (default: true).
    var preferOnDevice: Bool = true

    static let `default` = STTConfiguration()
}
```

### 3.4 `SpeechRecognizerService` protocol

```swift
protocol SpeechRecognizerService: Actor {
    /// Emitted TranscriptionResults (confidence ≥ threshold). Set in init().
    nonisolated var transcriptionStream: AsyncStream<TranscriptionResult> { get }
    /// Currently configured locale.
    nonisolated var locale: Locale { get }

    /// Begin consuming speech segments from VAD. Throws on permission/availability error.
    func activate(stream: AsyncStream<SpeechSegment>) async throws
    /// Stop processing. In-flight recognition is cancelled; no further output.
    func deactivate() async
    /// Switch to a different recognition locale.
    func setLocale(_ locale: Locale) async
}
```

---

## 4. `AppleSpeechService` — Implementation Design

### 4.1 Initialization

```swift
actor AppleSpeechService: SpeechRecognizerService {
    nonisolated let transcriptionStream: AsyncStream<TranscriptionResult>
    nonisolated private(set) var locale: Locale

    private let config: STTConfiguration
    private var continuation: AsyncStream<TranscriptionResult>.Continuation?
    private var processingTask: Task<Void, Never>?
    private var activeRecognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    init(locale: Locale = .current, config: STTConfiguration = .default) {
        self.locale = locale
        self.config = config
        var cont: AsyncStream<TranscriptionResult>.Continuation?
        transcriptionStream = AsyncStream { cont = $0 }
        continuation = cont
        // Recognizer created lazily in activate() after permission check
    }
}
```

### 4.2 Activation

```swift
func activate(stream: AsyncStream<SpeechSegment>) async throws {
    guard processingTask == nil else { return }

    // 1. Request authorization
    let status = await SFSpeechRecognizer.requestAuthorization()
    guard status == .authorized else { throw STTError.permissionDenied }

    // 2. Create recognizer for locale
    recognizer = SFSpeechRecognizer(locale: locale)
    guard let recognizer, recognizer.isAvailable else {
        throw STTError.recognizerUnavailable(locale)
    }

    // 3. Spawn processing loop
    processingTask = Task { [weak self] in
        guard let self else { return }
        await self.runProcessingLoop(stream: stream)
    }
}
```

### 4.3 Per-segment Recognition

```swift
private func transcribeSegment(_ segment: SpeechSegment) async -> TranscriptionResult? {
    guard let recognizer else { return nil }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = false
    if recognizer.supportsOnDeviceRecognition && config.preferOnDevice {
        request.requiresOnDeviceRecognition = true
    }
    request.append(segment.audio)
    request.endAudio()

    do {
        let result = try await withCheckedThrowingContinuation { continuation in
            activeRecognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                continuation.resume(returning: result)
            }
        }

        activeRecognitionTask = nil
        let confidence = averageConfidence(result.bestTranscription)
        guard confidence >= config.minimumConfidence else { return nil }

        let duration = Double(segment.audio.frameLength) / segment.audio.format.sampleRate
        return TranscriptionResult(
            text: result.bestTranscription.formattedString,
            confidence: confidence,
            locale: locale,
            capturedAt: segment.capturedAt,
            audioDuration: duration
        )
    } catch {
        activeRecognitionTask = nil
        // Log error; skip segment; continue
        return nil
    }
}

private func averageConfidence(_ transcription: SFTranscription) -> Float {
    let segments = transcription.segments
    guard !segments.isEmpty else { return 0 }
    return segments.map(\.confidence).reduce(0, +) / Float(segments.count)
}
```

### 4.4 Deactivation

```swift
func deactivate() async {
    processingTask?.cancel()
    processingTask = nil
    activeRecognitionTask?.cancel()
    activeRecognitionTask = nil
}
```

### 4.5 Locale Switching

```swift
func setLocale(_ newLocale: Locale) async {
    guard newLocale != locale else { return }
    // Cancel in-flight task for old locale
    activeRecognitionTask?.cancel()
    activeRecognitionTask = nil
    locale = newLocale
    recognizer = SFSpeechRecognizer(locale: newLocale)
}
```

---

## 5. ViewModel Integration

```swift
// AudioViewModel additions
@Published var latestTranscription: String?
@Published var isTranscribing: Bool = false

private var transcriptionTask: Task<Void, Never>?

func observeTranscriptions(_ service: any SpeechRecognizerService) {
    transcriptionTask?.cancel()
    transcriptionTask = Task { @MainActor [weak self] in
        for await result in service.transcriptionStream {
            self?.latestTranscription = result.text
            self?.isTranscribing = false
        }
    }
}
```

`isTranscribing = true` is set by the ViewModel when it receives a VAD `speechEnded` event (via `isSpeechActive` going `false`), signalling that a segment has been handed off to STT. When a `TranscriptionResult` arrives, `isTranscribing` goes back to `false`.

---

## 6. File Structure

```
TranslateCall/
└── Core/
    └── STT/
        ├── SpeechRecognizerService.swift   // protocol + TranscriptionResult + STTError + STTConfiguration
        └── AppleSpeechService.swift        // SFSpeechRecognizer implementation

TranslateCallTests/
└── STTServiceTests.swift                   // Unit + acceptance tests
```

---

## 7. Threading and Swift 6 Compliance

| Concern | Solution |
|---------|---------|
| `SFSpeechRecognizer` callbacks on arbitrary threads | `withCheckedThrowingContinuation` bridges to actor-isolated async; no shared mutable state |
| `SFSpeechRecognitionTask` cancellation | Stored as actor-isolated `var`; cancelled in `deactivate()` |
| `AVAudioPCMBuffer` passed from VAD actor to STT actor | `@unchecked Sendable` already in codebase |
| `TranscriptionResult` crossing actor boundary to ViewModel | `Sendable` value type — no conformance boilerplate |
| `SFSpeechRecognizer.requestAuthorization()` | Runs on arbitrary thread; `await` wraps it in async context safely |

---

## 8. Error Handling

| Error | Behavior |
|-------|---------|
| `STTError.permissionDenied` | Thrown from `activate()`; ViewModel shows alert; service not started |
| `STTError.recognizerUnavailable` | Thrown from `activate()`; ViewModel shows alert with locale name |
| Recognition task fails (network error, timeout) | Segment skipped; error logged via `os_log`; next segment processed normally |
| `AVAudioPCMBuffer` empty (zero frames) | Segment skipped before creating request |
| Locale has no installed language model | `recognizer.isAvailable == false` → `STTError.recognizerUnavailable` |

---

## 9. Info.plist Addition Required

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>TranslateCall uses speech recognition to transcribe your spoken words for translation.</string>
```

This must be added to the app target's `Info.plist` before the service can request authorization.

---

*Gate 2 Review: human must approve this document before tasks.md is written.*
