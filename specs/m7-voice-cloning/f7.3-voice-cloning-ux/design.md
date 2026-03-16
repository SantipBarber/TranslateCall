# F7.3 — Voice Cloning UX: Design

> **Feature**: F7.3 — Voice Cloning UX
> **Milestone**: M7 — Voice Cloning
> **Status**: DRAFT
> **Date**: 2026-03-15
> **Depends on**: requirements.md (approved)

---

## 1. Architecture Overview

F7.3 is a UI/UX layer on top of existing F7.1 (profiles) and F7.2 (Qwen3-TTS). No new core components — it adds a `VoicePreviewService` actor for standalone preview synthesis and enhances `VoiceProfileDetailView`.

```
┌─ VoiceProfileDetailView (enhanced) ──────────────────┐
│                                                        │
│  ┌─ VoicePreviewSection ─────────────────────────┐    │
│  │  Language picker + demo text + buttons          │    │
│  │  [Preview] [Compare A/B] [Stop]                 │    │
│  │  Playback status label                          │    │
│  └─────────────────────┬─────────────────────────┘    │
│                        │                               │
│  [Play Recording]      │                               │
│        │               │                               │
│        ▼               ▼                               │
│  AudioPlayback    VoicePreviewService                  │
│  Service          (actor)                              │
│  (raw PCM)        ├─ QwenCloneSpeechService (clone)    │
│                   └─ AVSpeechService (standard A/B)    │
└────────────────────────────────────────────────────────┘
```

---

## 2. Component Design

### 2.1 VoicePreviewService (Actor)

New actor that manages preview synthesis independently from the main translation pipeline.

```swift
// Core/VoiceCloning/VoicePreviewService.swift

actor VoicePreviewService {
    enum PreviewState: Sendable, Equatable {
        case idle
        case loadingModel
        case synthesizing(VoicePreviewMode)
        case playing(VoicePreviewMode)
        case error(String)
    }

    enum VoicePreviewMode: Sendable, Equatable {
        case cloned
        case standard       // A/B: standard TTS
        case abComparison   // A/B: full sequence
        case recording      // Raw training audio
    }

    nonisolated let stateStream: AsyncStream<PreviewState>
    private let stateContinuation: AsyncStream<PreviewState>.Continuation

    // Audio engine (separate from main pipeline)
    nonisolated(unsafe) private let engine = AVAudioEngine()
    nonisolated(unsafe) private let playerNode = AVAudioPlayerNode()

    // Dependencies
    private let profileStore: any VoiceProfileStoring
    private var inferrer: (any QwenCloneInferring)?

    init(profileStore: any VoiceProfileStoring) throws { ... }

    // MARK: - Public API

    /// Preview cloned voice with demo text in specified language.
    func previewClone(
        profileId: UUID,
        text: String,
        language: String
    ) async { ... }

    /// A/B comparison: standard TTS → pause → cloned voice.
    func compareAB(
        profileId: UUID,
        text: String,
        locale: Locale
    ) async { ... }

    /// Play raw training audio from profile.
    func playRecording(profileId: UUID) async { ... }

    /// Stop any active playback.
    func stop() { ... }
}
```

**Key decisions**:
- Separate `AVAudioEngine` from the main pipeline (REQ-UX-NF-04: no interference)
- Reuses `QwenCloneModelManager.shared` for model access (no separate model load)
- Uses default output device (not BlackHole) — REQ-UX-NF-03
- State exposed via `AsyncStream` for UI binding

### 2.2 Demo Text Localization

```swift
// Core/VoiceCloning/QwenCloneConfiguration.swift (extension)

extension QwenCloneConfiguration {
    static func demoText(for language: String) -> String {
        switch language {
        case "english":    return "Hello, this is a preview of my cloned voice."
        case "spanish":    return "Hola, esta es una vista previa de mi voz clonada."
        case "french":     return "Bonjour, ceci est un aperçu de ma voix clonée."
        case "german":     return "Hallo, dies ist eine Vorschau meiner geklonten Stimme."
        case "italian":    return "Ciao, questa è un'anteprima della mia voce clonata."
        case "portuguese": return "Olá, esta é uma prévia da minha voz clonada."
        case "russian":    return "Здравствуйте, это предварительный просмотр моего клонированного голоса."
        case "chinese":    return "你好，这是我克隆声音的预览。"
        case "japanese":   return "こんにちは、これは私のクローン音声のプレビューです。"
        case "korean":     return "안녕하세요, 제 복제된 목소리의 미리보기입니다."
        default:           return "Hello, this is a preview of my cloned voice."
        }
    }
}
```

### 2.3 VoicePreviewSection (SwiftUI View)

New sub-view embedded in `VoiceProfileDetailView`:

```swift
// Features/VoiceCloning/VoicePreviewSection.swift

struct VoicePreviewSection: View {
    let profile: VoiceProfileHeader
    @State private var previewState: VoicePreviewService.PreviewState = .idle
    @State private var selectedLanguage: String = "english"
    @State private var customText: String = ""

    // Computed demo text: custom if non-empty, else localized default
    private var demoText: String {
        customText.isEmpty
            ? QwenCloneConfiguration.demoText(for: selectedLanguage)
            : customText
    }

    var body: some View {
        GroupBox("Preview") {
            VStack(alignment: .leading, spacing: 8) {
                // Language picker
                HStack {
                    Text("Language")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $selectedLanguage) {
                        ForEach(supportedLanguages, id: \.key) { lang in
                            Text(lang.label).tag(lang.key)
                        }
                    }
                    .frame(maxWidth: 140)
                }

                // Demo text (editable)
                TextField("Demo text", text: $customText, prompt: Text(demoText))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                // Action buttons
                HStack(spacing: 12) {
                    previewButton
                    compareButton
                    stopButton
                }

                // Status label
                statusLabel
            }
        }
    }
}
```

### 2.4 Training Audio Playback

Simple PCM playback — no model needed. Reuses `VoicePreviewService`:

```swift
// Inside VoicePreviewService
func playRecording(profileId: UUID) async {
    transition(to: .playing(.recording))
    let profile = try await profileStore.load(id: profileId)
    guard let samples = profile.samples else { ... }

    // Convert [Float] 24kHz → AVAudioPCMBuffer → schedule on playerNode
    let buffer = makePCMBuffer(from: samples)
    scheduleBuffer(buffer)
}
```

### 2.5 A/B Comparison Flow

```
User taps "Compare A/B"
  │
  ├─ 1. Synthesize with AVSpeechSynthesizer (standard)
  │     → Play standard audio
  │     → Label: "▶ Standard"
  │
  ├─ 2. Pause 0.5s
  │
  ├─ 3. Synthesize with QwenCloneSpeechService (cloned)
  │     → Play cloned audio
  │     → Label: "▶ Cloned"
  │
  └─ 4. Done → state = .idle
```

Standard TTS uses `AVSpeechSynthesizer.write()` to get PCM samples (same as AVSpeechService), avoiding any playback conflicts with the main audio engine.

### 2.6 ContentView Enhancements

Update voice profile row to show language fallback info:

```swift
// In voiceProfileRow
if viewModel.ttsEngineSelector.voiceCloningActive {
    Text("Cloning ON")
        .font(.caption2)
        .padding(.horizontal, 6)
        .background(.green.opacity(0.15))
        .foregroundStyle(.green)
        .clipShape(Capsule())
} else if viewModel.ttsEngineSelector.voiceCloningEnabled,
          !QwenCloneConfiguration.supportsLocale(currentTargetLocale) {
    Text("Fallback — unsupported language")
        .font(.caption2)
        .foregroundStyle(.orange)
}
```

---

## 3. VoiceProfileDetailView Layout (Enhanced)

```
┌─────────────────────────────────────────────────┐
│  🎤 SpBarber                        [Set Active] │
│  Mar 12, 2026 · 5.2s · Good                      │
│                                                   │
│  ┌─ Preview ──────────────────────────────────┐  │
│  │ Language: [English ▾]                       │  │
│  │ ┌──────────────────────────────────────┐    │  │
│  │ │ Hello, this is a preview of my...    │    │  │
│  │ └──────────────────────────────────────┘    │  │
│  │                                             │  │
│  │ [▶ Preview]  [⇄ Compare]  [■ Stop]         │  │
│  │ 🔊 Playing cloned voice...                  │  │
│  └─────────────────────────────────────────────┘  │
│                                                   │
│  [▶ Play Recording]                               │
│                                                   │
│  ── Quality ──────────────────────────────────    │
│  Duration     5.2 s                               │
│  Sample rate  24000 Hz                            │
│  Peak RMS     -18.5 dBFS                          │
│  Clipping     No                                  │
│  Grade        Good                                │
│                                                   │
│  [Rename]                          [Delete]       │
└───────────────────────────────────────────────────┘
```

---

## 4. State Management

`VoicePreviewService.PreviewState` drives the entire UI:

| State | Preview Button | Compare Button | Stop Button | Status Label |
|-------|---------------|----------------|-------------|-------------|
| `.idle` | Enabled | Enabled | Disabled | — |
| `.loadingModel` | Disabled (spinner) | Disabled | Enabled | "Loading model..." |
| `.synthesizing(.cloned)` | Disabled (spinner) | Disabled | Enabled | "Synthesizing..." |
| `.playing(.cloned)` | Disabled | Disabled | Enabled | "▶ Playing cloned voice" |
| `.playing(.standard)` | Disabled | Disabled | Enabled | "▶ Playing standard voice" |
| `.playing(.recording)` | Disabled | Disabled | Enabled | "▶ Playing recording" |
| `.error(msg)` | Enabled | Enabled | Disabled | "⚠ [msg]" |

---

## 5. Error Handling

| Error | Recovery |
|-------|----------|
| Model not loaded, auto-load fails | Show error in status label, buttons re-enabled |
| Profile decrypt fails | Show error, continue |
| Inference timeout (>10s) | Cancel, show "Synthesis timed out" |
| Session active (main pipeline running) | Disable preview buttons with tooltip |
| Empty demo text | Use default demo text |

---

## 6. Testing Strategy

### Unit Tests (No Model)
- `VoicePreviewServiceTests` — state transitions, stop, error handling
- `QwenCloneConfiguration.demoText()` — all 10 languages return non-empty
- `VoicePreviewSection` — compile-time check

### Manual Tests
- Preview synthesis plays cloned audio
- A/B comparison plays standard then cloned
- Play recording plays original audio
- Language picker changes demo text and synthesis language
- Preview disabled during active session
- Stop button works mid-playback

---

*This document defines **how** the feature is built. Task breakdown is in `tasks.md`.*
