# F7.3 — Voice Cloning UX: Requirements

> **Feature**: F7.3 — Voice Cloning UX
> **Milestone**: M7 — Voice Cloning
> **Status**: DRAFT
> **Date**: 2026-03-15
> **Depends on**: F7.1 (Voice Profile Training), F7.2 (Voice Cloning TTS)

---

## 1. Overview

Add user-facing voice cloning quality tools: preview synthesis ("hear your clone"), A/B comparison with standard TTS, training audio playback, and multi-language preview. This feature transforms voice cloning from a "toggle and hope" experience into a transparent, confidence-building workflow.

### 1.1 Scope

- **In scope**: Voice preview synthesis (demo text → cloned audio), A/B toggle (standard vs cloned), training audio playback, multi-language preview selector, voice preview in VoiceProfileDetailView, integration in main workflow.
- **Out of scope**: Voice similarity scoring (automated metric), per-language profile tuning (different profiles per language), fine-tuning, voice profile re-recording from preview, streaming preview.

### 1.2 User Stories

1. **As a user**, I want to hear how my cloned voice sounds before using it in a call, so I can verify the quality.
2. **As a user**, I want to compare my cloned voice against the standard TTS voice (A/B), so I can decide which sounds better.
3. **As a user**, I want to hear my original training recording, so I can remember what I recorded.
4. **As a user**, I want to preview my cloned voice in different languages, so I know how cross-lingual cloning sounds.

---

## 2. Functional Requirements

### 2.1 Voice Preview Synthesis

**REQ-UX-01** — WHEN the user taps "Preview Voice" in VoiceProfileDetailView AND the Qwen3-TTS model is loaded THEN the system SHALL synthesize a demo sentence using the selected profile and play it through the default output device.

**REQ-UX-02** — WHEN the user taps "Preview Voice" AND the Qwen3-TTS model is NOT loaded THEN the system SHALL begin loading the model (showing a progress indicator) and synthesize after loading completes.

**REQ-UX-03** — WHEN preview synthesis is in progress THEN the button SHALL show a spinning indicator and be disabled. WHEN playback completes THEN the button SHALL return to its normal state.

**REQ-UX-04** — The default demo sentence SHALL be "Hello, this is a preview of my cloned voice." The user MAY enter custom text via an editable text field.

**REQ-UX-05** — WHEN the user taps "Stop" during preview playback THEN playback SHALL stop immediately and the button SHALL return to normal state.

### 2.2 A/B Comparison

**REQ-UX-06** — WHEN the user taps "Compare" in VoiceProfileDetailView THEN the system SHALL sequentially play:
  1. The demo sentence with standard TTS (AVSpeech)
  2. A brief pause (~0.5 s)
  3. The same sentence with the cloned voice (Qwen3-TTS)

**REQ-UX-07** — DURING A/B playback THEN the UI SHALL indicate which version is currently playing ("Standard" vs "Cloned") with a label or highlight.

**REQ-UX-08** — WHEN the user taps "Stop" during A/B comparison THEN all playback SHALL stop immediately.

### 2.3 Training Audio Playback

**REQ-UX-09** — WHEN the user taps "Play Recording" in VoiceProfileDetailView THEN the system SHALL decrypt and play the original training audio (24 kHz Float32 samples from the stored VoiceProfile).

**REQ-UX-10** — WHEN training audio playback is in progress THEN the button SHALL show a stop icon. WHEN playback completes THEN the button SHALL return to its play icon.

**REQ-UX-11** — Training audio playback SHALL NOT require the Qwen3-TTS model to be loaded (it plays raw PCM, not synthesized audio).

### 2.4 Multi-Language Preview

**REQ-UX-12** — VoiceProfileDetailView SHALL include a language picker showing the 10 supported Qwen3-TTS languages (English, Spanish, French, German, Italian, Portuguese, Russian, Chinese, Japanese, Korean).

**REQ-UX-13** — WHEN the user selects a language and taps "Preview Voice" THEN the system SHALL synthesize the demo text in the selected language, demonstrating cross-lingual voice cloning.

**REQ-UX-14** — The demo text SHALL be localized per language (e.g., "Hola, esta es una vista previa de mi voz clonada." for Spanish).

### 2.5 Integration in Main Workflow

**REQ-UX-15** — The voice profile row in ContentView SHALL show the active profile name, "Cloning ON" badge (when active), and the current cloning language (target language from LanguagePairManager).

**REQ-UX-16** — WHEN voice cloning is active AND the target language is unsupported THEN the voice profile row SHALL show an informational label: "Fallback — [language] not supported for cloning".

---

## 3. Non-Functional Requirements

**REQ-UX-NF-01** — Preview synthesis SHALL complete within 5 seconds on M1 (8 GB) for a 10-word sentence.

**REQ-UX-NF-02** — Training audio playback SHALL start within 500 ms of tap (decrypt + play).

**REQ-UX-NF-03** — All preview audio SHALL play through the system default output device (not BlackHole).

**REQ-UX-NF-04** — Preview synthesis SHALL NOT interfere with an active translation session. If a session is running, preview SHALL be disabled with a tooltip explaining why.

**REQ-UX-NF-05** — Preview SHALL reuse existing `QwenCloneSpeechService` infrastructure (no separate audio engine).

---

## 4. Acceptance Criteria

| ID | Criterion | Validation |
|----|-----------|------------|
| AC-01 | "Preview Voice" synthesizes and plays cloned audio | Manual: tap → hear cloned voice |
| AC-02 | A/B comparison plays standard then cloned sequentially | Manual: hear two distinct voices |
| AC-03 | "Play Recording" plays original training audio | Manual: hear recorded voice |
| AC-04 | Language picker changes preview language | Manual: select Spanish → hear Spanish |
| AC-05 | Demo text updates per language | Manual: select French → French demo text |
| AC-06 | Preview disabled during active session | Manual: start session → preview button disabled |
| AC-07 | Stop button halts playback immediately | Manual: tap stop mid-playback |
| AC-08 | Model auto-loads if needed for preview | Manual: unload model → tap preview → model loads → plays |
| AC-09 | "Cloning ON" badge visible in ContentView | Manual: enable cloning → badge appears |
| AC-10 | Fallback label for unsupported language | Manual: set target to Hindi → fallback message |

---

## 5. UI Wireframe (Text)

```
┌─ Voice Profile Detail ──────────────────────────────┐
│                                                       │
│  🎤 SpBarber                              [Set Active]│
│  Created: Mar 12, 2026 · 5.2s · Good quality         │
│                                                       │
│  ┌─ Preview ─────────────────────────────────────┐   │
│  │ Language: [English ▾]                          │   │
│  │ Text: [Hello, this is a preview of my...]      │   │
│  │                                                │   │
│  │ [▶ Preview Voice]  [⇄ Compare A/B]  [■ Stop]  │   │
│  │                                                │   │
│  │ 🔊 Playing: Cloned voice...                    │   │
│  └────────────────────────────────────────────────┘   │
│                                                       │
│  [▶ Play Recording]  Original training audio          │
│                                                       │
│  ── Metrics ──────────────────────────────────────    │
│  Duration: 5.2 s                                      │
│  Sample rate: 24000 Hz                                │
│  Quality: Good (RMS: -18.5 dBFS, no clipping)        │
│                                                       │
│  [Rename]                              [Delete]       │
└───────────────────────────────────────────────────────┘
```

---

*This document defines **what** the feature does. The **how** (architecture, components) is in `design.md`.*
