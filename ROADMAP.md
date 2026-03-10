# TranslateCall - Development Roadmap

> **Methodology**: Spec-Driven Development (SDD)
> **Last Updated**: 2026-03-10
> **Version**: 0.5.0-beta
> **Status**: M4 COMPLETED — Starting M5

---

## Table of Contents

- [Development Philosophy](#development-philosophy)
- [Spec-Driven Development Workflow](#spec-driven-development-workflow)
- [Milestone Overview](#milestone-overview)
- [M0: Proof of Concept (COMPLETED)](#m0-proof-of-concept)
- [M1: Foundation](#m1-foundation)
- [M2: Speech Pipeline](#m2-speech-pipeline)
- [M3: Translation Core](#m3-translation-core)
- [M4: Full Pipeline Integration](#m4-full-pipeline-integration)
- [M5: Beta Release](#m5-beta-release)
- [M6: Enhanced STT/TTS](#m6-enhanced-stttts)
- [M7: Neural Voice Cloning](#m7-neural-voice-cloning)
- [M8: Full Language Coverage](#m8-full-language-coverage)
- [M9: Public Launch](#m9-public-launch)
- [Critical Path](#critical-path)
- [Risk Registry](#risk-registry)
- [Success Metrics](#success-metrics)
- [Spec Directory Structure](#spec-directory-structure)

---

## Development Philosophy

TranslateCall follows **Spec-Driven Development (SDD)** — a methodology where formal, structured specifications serve as the single source of truth before any code is written. Each feature goes through a rigorous cycle of specification, validation, and implementation.

### Why SDD for TranslateCall

1. **Complex audio pipeline**: Multiple interdependent components (VAD, STT, Translation, TTS, audio routing) require clear contracts between them before implementation.
2. **Privacy-critical**: 100% on-device processing demands precise specifications to ensure no data leaks are introduced by design.
3. **Extensibility**: Future phases (neural voice cloning, whisper.cpp, custom languages) need well-defined interfaces from day one.
4. **AI-assisted development**: Structured specs enable efficient collaboration with AI coding agents while maintaining human oversight over architectural decisions.

### Core Principles

- **Specs before code**: Every feature starts with a requirements document, then a technical design, then implementation tasks.
- **Human-in-the-loop**: Specs are reviewed and approved at each phase gate before proceeding.
- **TDD from specs**: Acceptance criteria in specs translate directly into test cases.
- **Living documents**: Specs evolve alongside the code and are kept in version control.
- **Incremental delivery**: Each milestone produces a working, testable increment.

---

## Spec-Driven Development Workflow

Every feature in this roadmap follows this workflow:

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  REQUIREMENTS │────▶│    DESIGN    │────▶│    TASKS     │────▶│IMPLEMENTATION│
│  (What)       │     │  (How)       │     │  (Steps)     │     │  (Code+Test) │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
       │                    │                    │                      │
   ✅ Review            ✅ Review            ✅ Review             ✅ Validate
   Gate 1               Gate 2               Gate 3                Gate 4
```

### Phase 1: Requirements (`requirements.md`)

Define **what** the feature does using EARS syntax:

```
WHEN [event] THEN [system] SHALL [response]
IF [precondition] THEN [system] SHALL [response]
WHILE [condition] THE [system] SHALL [behavior]
```

### Phase 2: Technical Design (`design.md`)

Define **how** the feature is implemented:
- Architecture decisions and rationale
- Protocol/interface contracts between components
- Data flow and state management
- Error handling strategy
- Performance constraints

### Phase 3: Task Breakdown (`tasks.md`)

Break design into implementable units:
- Numbered, dependency-ordered task list
- Each task maps back to specific requirements
- Each task is independently testable
- TDD cycle: RED → GREEN → REFACTOR

### Phase 4: Implementation + Validation

- Write failing tests from acceptance criteria
- Implement minimal code to pass
- Refactor and clean up
- Validate against spec, mark task complete

---

## Milestone Overview

```
M0 ✅ PoC Validation          ── COMPLETED (2026-01-31)
 │
M1 ✅ Foundation              ── COMPLETED (2026-03-07)
 │
M2 ✅ Speech Pipeline         ── COMPLETED (2026-03-08)
 │
M3 ✅ Translation Core        ── COMPLETED (2026-03-08)
 │
M4 ✅ Full Pipeline           ── COMPLETED (2026-03-10)
 │
M5 ○  Beta Release            ── Testing, polish, beta distribution  [SPECS WRITTEN]
 │
M6 ○  Enhanced STT/TTS        ── FluidAudio Parakeet, MLX-Audio Kokoro
 │
M7 ○  Neural Voice Cloning    ── MLX-Audio CSM-1B integration
 │
M8 ○  Full Language Coverage   ── whisper.cpp, custom language framework
 │
M9 ○  Public Launch            ── Mac App Store, marketing, community
```

---

## M0: Proof of Concept

**Status**: COMPLETED
**Date**: 2026-01-31
**Decision**: GO

### Results Summary

| PoC | Component | Result | Key Finding |
|-----|-----------|--------|-------------|
| 1 | Translation API | PASS | TranslationBridge pattern required; 12ms/translation after init |
| 2 | VAD | PASS | < 0.01ms latency; 100% accuracy on synthetic data |
| 3 | Voice Cloning (DSP) | NO-GO | 64.6% quality, below 70% threshold; deferred to Phase 2 neural |
| 4 | BlackHole Integration | PASS | 48kHz stereo, reliable device enumeration |
| 5 | Half-Duplex Echo Mgmt | PASS | 315ms transition, 100% echo prevention |

### Decisions from M0

- Voice cloning removed from MVP scope; use premium TTS voices instead
- TranslationBridge (hidden SwiftUI view) is a required architectural component
- BlackHole 2ch is the audio routing solution
- Half-duplex with visual state indicator is the echo management strategy
- Total latency budget (~2.5s) is achievable

---

## M1: Foundation

**Status**: COMPLETED — 2026-03-07
**Prerequisites**: M0 (completed)
**Spec Directory**: `specs/m1-foundation/`

### Scope

Set up the project infrastructure, audio capture/playback system, and basic UI shell.

### Features to Specify

#### F1.1: Project Setup & Build Configuration

**Requirements (summary)**:
- WHEN the project is opened in Xcode THEN it SHALL build for macOS 14.0+ with Swift 6.0
- WHEN the app launches THEN it SHALL request microphone permissions
- WHILE the app is running THE build system SHALL enforce strict concurrency checking

**Key deliverables**:
- Xcode project with SwiftUI lifecycle
- SPM dependency configuration (FluidAudio)
- Code signing and entitlements (microphone, audio input)
- SwiftLint + SwiftFormat configuration
- CI pipeline (GitHub Actions): build + test on push

#### F1.2: Audio Infrastructure (AudioManager)

**Requirements (summary)**:
- WHEN AudioManager initializes THEN it SHALL enumerate all available audio devices
- WHEN a user selects an input device THEN AudioManager SHALL capture audio at 48kHz PCM
- WHEN BlackHole 2ch is available THEN it SHALL appear as a selectable output device
- WHILE capturing audio THE system SHALL provide real-time level metering

**Key deliverables**:
- `AudioManager` class wrapping AVAudioEngine
- Device enumeration and hot-plug detection
- Audio capture pipeline (48kHz → 16kHz conversion for ML models)
- Audio playback to selected output (speakers or BlackHole)
- Audio level monitoring (RMS/peak) for UI meters

#### F1.3: Basic UI Shell

**Requirements (summary)**:
- WHEN the app launches THEN it SHALL display a main window with device selectors and controls
- WHEN the user clicks Start THEN the audio pipeline SHALL begin capturing
- WHILE audio is captured THE UI SHALL display real-time input level meters

**Key deliverables**:
- Main window with SwiftUI (compact, menu-bar-friendly design)
- Input/output device dropdown selectors
- Start/Stop translation toggle
- Audio level visualization
- Status indicators (listening/speaking/transitioning)

### Acceptance Gates

- [x] Project builds and runs on macOS 15.0+ with Swift 6.0 strict concurrency
- [x] Microphone audio is captured and can be played back through BlackHole
- [x] Device hot-plug is detected and UI updates accordingly
- [x] Audio level meters respond to real-time input
- [x] All unit tests pass, CI is green
- [x] Basic UI Shell: device pickers, start/stop, level meter, status badge

### Lessons Learned (M1)

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` causes AVAudioEngine tap closures to inherit `@MainActor` → `_dispatch_assert_queue_fail` on audio thread. Fix: `configureEngine()` must be `nonisolated`.
- `AVAudioConverter.convert(to:from:)` does NOT support sample rate conversion. Must use `convert(to:error:withInputFrom:)` callback API.
- `AVAudioConverterInputBlock` is `@Sendable` in Swift 6 — use a `SyncBox<T>: @unchecked Sendable` with `nonisolated(unsafe) var` for mutable state in synchronous callbacks.
- macOS deployment target must be **15.0** (not 14.0) — Apple Translation Framework requires 15.0.
- `Grid(horizontalSpacing:verticalSpacing:)` — NOT `columnSpacing/rowSpacing`.
- SwiftFormat must NOT run as a build phase (introduces typos via automated rewrites).

---

## M2: Speech Pipeline

**Status**: IN PROGRESS — started 2026-03-07
**Prerequisites**: M1 (completed)
**Spec Directory**: `specs/m2-speech-pipeline/`

### Scope

Integrate Voice Activity Detection, Speech-to-Text, and Text-to-Speech into the audio pipeline.

### Features to Specify

#### F2.1: VAD Integration (FluidAudio Silero)

**Requirements (summary)**:
- WHEN audio is captured THEN VADService SHALL continuously analyze buffers for speech
- WHEN speech is detected THEN VADService SHALL emit a `speechStarted` event with buffered audio
- WHEN silence exceeds 800ms after speech THEN VADService SHALL emit `speechEnded` with the complete utterance
- WHILE no speech is detected THE system SHALL NOT forward audio to STT (resource conservation)

**Key deliverables**:
- `VADService` protocol + FluidAudio Silero implementation
- `SimpleEnergyVAD` fallback implementation
- Speech/silence event stream (Combine/AsyncSequence)
- Configurable silence threshold and minimum speech duration

#### F2.2: Speech-to-Text (Apple Speech Framework)

**Requirements (summary)**:
- WHEN a speech segment is received from VAD THEN STT SHALL transcribe it in the source language
- WHEN transcription completes THEN STT SHALL emit the recognized text with confidence score
- IF confidence is below 60% THEN the system SHALL discard the segment and continue listening

**Key deliverables**:
- `SpeechRecognizerService` wrapping `SFSpeechRecognizer`
- Language selection and on-the-fly switching
- Streaming transcription (partial results for UI feedback)
- Error handling (permission denied, language unavailable)

#### F2.3: Text-to-Speech (AVSpeechSynthesizer)

**Requirements (summary)**:
- WHEN translated text is ready THEN TTS SHALL synthesize audio in the target language
- WHEN synthesis completes THEN the audio SHALL be routed to the configured output device
- WHILE TTS is speaking THE system SHALL indicate "speaking" state in the UI

**Key deliverables**:
- `SynthesisService` wrapping `AVSpeechSynthesizer`
- Premium voice selection per language
- Audio output routing (to speakers for incoming, to BlackHole for outgoing)
- Speech rate and pitch adjustment controls

### Acceptance Gates

- [ ] VAD correctly segments continuous speech into utterances
- [ ] STT transcribes speech in at least 5 languages with > 80% accuracy
- [ ] TTS produces natural-sounding output in target language
- [ ] End-to-end: speak → detect → transcribe → display text works reliably
- [ ] Latency: VAD + STT < 900ms for a typical sentence

---

## M3: Translation Core ✅ COMPLETED (2026-03-08)

**Prerequisites**: M2
**Spec Directory**: `specs/m3-translation-core/`

### Scope

Integrate Apple Translation Framework via the TranslationBridge pattern and build language pair management.

### Features to Specify

#### F3.1: TranslationBridge

**Requirements (summary)**:
- WHEN the app launches THEN TranslationBridge SHALL initialize a hidden SwiftUI view with TranslationSession
- WHEN text is submitted for translation THEN TranslationBridge SHALL return translated text within 600ms
- IF the required language pair is not downloaded THEN the system SHALL prompt the user to download it

**Key deliverables**:
- `TranslationBridge` hidden SwiftUI view
- `TranslationService` protocol with Apple Translation implementation
- Async translation API (`translate(text:from:to:) async throws -> String`)
- Language pair availability checking and download management

#### F3.2: Language Pair Management

**Requirements (summary)**:
- WHEN the app launches THEN it SHALL detect installed language pairs
- WHEN the user selects a language pair THEN the system SHALL verify it is downloaded
- IF a language pair is missing THEN the system SHALL offer to download it with progress indication

**Key deliverables**:
- Language pair configuration UI (source ↔ target)
- Download manager for language models
- Favorite/recent language pairs
- Language detection hints from STT

#### F3.3: One-Way Translation Pipeline

**Requirements (summary)**:
- WHEN the user speaks THEN the system SHALL: detect speech → transcribe → translate → synthesize → output
- WHILE the pipeline is active THE UI SHALL show: original text, translated text, and current state
- WHEN an error occurs at any stage THEN the system SHALL recover gracefully and continue listening

**Key deliverables**:
- `TranslationCoordinator` orchestrating VAD → STT → Translation → TTS
- Pipeline state machine with error recovery
- Real-time subtitle display (original + translated)
- Pipeline latency monitoring and reporting

### Acceptance Gates

- [x] Translation works for all installed Apple language pairs (TranslationBridge pattern)
- [ ] End-to-end latency (speech → translated audio) < 3 seconds (manual validation pending)
- [x] Language pair download flow works smoothly (LanguagePairManager + LanguagePairView)
- [x] Pipeline recovers from transient STT/Translation errors (error propagation via alertItem)
- [x] Subtitle display updates in real-time during speech (TranscriptionView dual rows)

---

## M4: Full Pipeline Integration

**Prerequisites**: M3
**Spec Directory**: `specs/m4-full-pipeline/`

### Scope

Enable bidirectional translation with echo management and BlackHole routing for real video calls.

### Features to Specify

#### F4.1: Bidirectional Translation ✅ COMPLETED (2026-03-09)

**Requirements (summary)**:
- WHEN the user speaks THEN outgoing pipeline SHALL translate and output to BlackHole (for remote participant)
- WHEN remote audio arrives THEN incoming pipeline SHALL translate and output to speakers (for user)
- WHILE both pipelines are active THE system SHALL maintain half-duplex to prevent feedback

**Key deliverables**:
- Dual pipeline: outgoing (mic → BlackHole) and incoming (system audio → speakers)
- `AudioCoordinator` managing both pipelines
- System audio capture (for incoming remote voice)
- Audio routing matrix configuration

#### F4.2: Half-Duplex Echo Management ✅ COMPLETED (2026-03-10)

**Requirements (summary)**:
- WHILE TTS is playing on speakers THEN the microphone capture SHALL be muted
- WHEN TTS finishes THEN the system SHALL wait 300ms before re-enabling capture
- WHILE transitioning THE UI SHALL display yellow indicator

**Key deliverables**:
- `HalfDuplexManager` state machine (listening → speaking → transitioning)
- Microphone mute/unmute tied to TTS lifecycle
- Visual state indicator (green/red/yellow)
- Configurable transition buffer

#### F4.3: Video Call Integration ✅ COMPLETED (2026-03-10)

**Requirements (summary)**:
- WHEN BlackHole is configured as microphone in Zoom/Teams/Meet THEN the remote participant SHALL hear translated audio
- WHEN the user sets up TranslateCall THEN a setup wizard SHALL guide device configuration

**Key deliverables**:
- `SetupManager`: BlackHole readiness check, capture app selection, UserDefaults persistence
- `VideoCallApp` enum: per-app instructions for Zoom, Teams, Meet, Discord
- `RouteTestService`: TTS test tone routed to BlackHole
- 4-step setup wizard (`SetupWizardView` + `BlackHoleCheckStepView` + `VideoAppInstructionStepView` + `CaptureAppSelectStepView` + `RouteTestStepView`)
- `SetupBannerView` + inline capture app selector in main window
- `ContentView` integration: auto-shows wizard on first launch, re-checkable via Setup… button
- 13 new unit tests: `VideoCallAppTests` (7) + `SetupManagerTests` (6)

### Acceptance Gates

- [ ] Bidirectional translation works in a real Zoom call
- [ ] Echo/feedback is eliminated in half-duplex mode
- [ ] Setup wizard successfully configures a new user
- [ ] Total latency < 3 seconds in both directions
- [ ] 30-minute call stability test passes without degradation

---

## M5: Beta Release

**Prerequisites**: M4
**Spec Directory**: `specs/m5-beta/`

### Scope

Polish, stabilize, and distribute to beta testers.

### Features to Specify

#### F5.1: Stability & Performance

- Memory leak audit and fix
- CPU usage optimization (target: < 15% sustained)
- Crash reporting (local-only, privacy-respecting)
- Graceful degradation on older hardware (M1 vs M2/M3)

#### F5.2: User Experience Polish

- Onboarding flow for first-time users
- BlackHole installation assistant
- Keyboard shortcuts for start/stop, mute, language switch
- Menu bar mode (compact, always-accessible)
- Settings persistence

#### F5.3: Beta Distribution

- TestFlight or direct DMG distribution
- Feedback collection mechanism (in-app, local-only)
- Auto-update mechanism
- Beta tester recruitment (target: 50+ users)

### Acceptance Gates

- [ ] 50+ beta testers actively using the app
- [ ] Crash-free rate > 99%
- [ ] User satisfaction > 4/5
- [ ] No audio glitches in 1-hour sustained use
- [ ] Works reliably with Zoom, Teams, and Google Meet

---

## M6: Enhanced STT/TTS

**Prerequisites**: M5
**Spec Directory**: `specs/m6-enhanced-speech/`

### Scope

Upgrade speech recognition and synthesis with higher-quality models.

### Features to Specify

#### F6.1: FluidAudio Parakeet STT

- Integration of FluidAudio Parakeet for 25 European languages
- A/B comparison framework (Apple Speech vs Parakeet)
- User-selectable STT engine per language
- Improved accuracy for accented speech

#### F6.2: MLX-Audio Kokoro TTS

- Integration of MLX-Audio Kokoro for superior voice quality
- Voice selection UI with audio previews
- Latency optimization for on-device inference
- Fallback to AVSpeechSynthesizer if model loading fails

### Acceptance Gates

- [ ] Parakeet STT shows measurable accuracy improvement over Apple Speech
- [ ] Kokoro TTS rated higher in naturalness by beta testers
- [ ] No latency regression (still < 3 seconds end-to-end)
- [ ] Smooth fallback when enhanced models unavailable

---

## M7: Neural Voice Cloning

**Prerequisites**: M6
**Spec Directory**: `specs/m7-voice-cloning/`

### Scope

Implement neural voice cloning so translated speech sounds like the original speaker.

### Features to Specify

#### F7.1: Voice Profile Training

- 30-second voice sample collection UI
- Voice characteristic extraction and storage
- Encrypted voice profile storage (AES-256-GCM)
- Profile management (create, update, delete)

#### F7.2: MLX-Audio CSM-1B Integration

- CSM-1B model loading and inference
- Voice conditioning from stored profile
- Real-time voice style transfer in TTS pipeline
- Quality validation (target: > 80% similarity score)

#### F7.3: Voice Cloning UX

- A/B toggle: cloned voice vs standard TTS
- Voice similarity preview before call
- Per-language voice profile tuning

### Acceptance Gates

- [ ] Voice cloning achieves > 80% similarity score
- [ ] Users can identify the cloned voice as "sounding like them"
- [ ] No significant latency increase (< 500ms additional)
- [ ] Voice profiles are securely stored and encrypted

---

## M8: Full Language Coverage

**Prerequisites**: M6
**Spec Directory**: `specs/m8-languages/`

### Scope

Expand from ~20 Apple Translation languages to 99+ via whisper.cpp and custom language support.

### Features to Specify

#### F8.1: whisper.cpp Integration

- whisper.cpp model loading (multiple sizes: tiny → large)
- 99+ language STT support
- Model download manager with size/quality tradeoffs
- Performance optimization for Apple Silicon

#### F8.2: Custom Language Framework

- Plugin architecture for community-contributed languages
- Fine-tuning guide for low-resource languages (Opus-MT)
- Deployment options: on-device CoreML, local server, API
- Language pack format and distribution

#### F8.3: Translation Engine Abstraction

- Pluggable translation backend (Apple, custom models, future engines)
- Language capability matrix (which engine handles which pair)
- Automatic engine selection based on language pair
- Quality metrics per engine/pair

### Acceptance Gates

- [ ] whisper.cpp handles 50+ languages with acceptable accuracy
- [ ] At least one custom language (e.g., Catalan, Aragonese) working end-to-end
- [ ] Language switching is seamless and responsive
- [ ] Users can install additional language packs without app update

---

## M9: Public Launch

**Prerequisites**: M5 (minimum), M6-M8 (desired)
**Spec Directory**: `specs/m9-launch/`

### Scope

Prepare for public distribution and community building.

### Features to Specify

#### F9.1: Distribution

- Mac App Store submission (code signing, notarization, review guidelines)
- Website with documentation and download links
- Homebrew cask formula

#### F9.2: Community

- Open-source contribution guidelines
- Language pack contribution workflow
- Community forum or Discord server
- Bug report and feature request templates

#### F9.3: Documentation

- User guide with visual setup instructions
- API documentation for plugin developers
- Video tutorials for common use cases
- FAQ and troubleshooting guide

### Acceptance Gates

- [ ] App approved on Mac App Store
- [ ] 500+ active users
- [ ] 5+ verified language pairs with quality ratings
- [ ] Average latency < 2.5 seconds
- [ ] Active community with contributors

---

## Critical Path

```
M0 ✅ ──▶ M1 ──▶ M2 ──▶ M3 ──▶ M4 ──▶ M5 (MVP)
                                          │
                              ┌───────────┼───────────┐
                              ▼           ▼           ▼
                             M6          M7          M8
                              │           │           │
                              └───────────┼───────────┘
                                          ▼
                                         M9 (Launch)
```

**MVP Critical Path**: M0 → M1 → M2 → M3 → M4 → M5

**Notes**:
- M6, M7, M8 can be developed in parallel after M5
- M7 (Voice Cloning) depends on M6 (Enhanced TTS) for best results
- M8 (Languages) is independent and can proceed alongside M6/M7
- M9 can launch with M5 alone, or wait for M6-M8 for a stronger release

---

## Risk Registry

| ID | Risk | Probability | Impact | Mitigation |
|----|------|-------------|--------|------------|
| R1 | BlackHole driver instability on macOS updates | Low | High | Monitor macOS betas; evaluate Soundflower/Loopback as alternatives |
| R2 | Apple Speech STT latency > 800ms | Medium | High | FluidAudio Parakeet as fallback (M6); optimize buffer sizes |
| R3 | Apple Translation API changes at WWDC | Low | Medium | Abstraction layer (`TranslationService` protocol); monitor announcements |
| R4 | Users unwilling to install BlackHole | Medium | High | Guided installer in onboarding wizard; explore AudioDriverKit alternative |
| R5 | Voice cloning quality below user expectations | Medium | Medium | Set clear expectations in UI; offer standard TTS as default |
| R6 | Memory usage too high with multiple ML models | Medium | Medium | Lazy model loading; user-configurable quality/memory tradeoff |
| R7 | Mac App Store rejection (virtual audio) | Low | High | Direct distribution as alternative; comply with review guidelines |
| R8 | FluidAudio/MLX-Audio API breaking changes | Low | Medium | Pin dependency versions; abstraction protocols |

---

## Success Metrics

### MVP (M5)

| Metric | Target |
|--------|--------|
| Beta testers | 50+ |
| End-to-end latency | < 3 seconds |
| Crash-free sessions | > 99% |
| User satisfaction | > 4/5 |
| Supported language pairs | 10+ (Apple Translation) |
| CPU usage (sustained) | < 15% |

### Launch (M9)

| Metric | Target |
|--------|--------|
| Active users | 500+ |
| Verified language pairs | 5+ with quality ratings |
| Average latency | < 2.5 seconds |
| App Store rating | > 4.0 |
| Community contributors | 10+ |

### Long-term (12+ months)

| Metric | Target |
|--------|--------|
| Active users | 2,000+ |
| Language coverage | 50+ languages |
| Voice cloning satisfaction | > 80% "sounds like me" |
| iOS companion app | Released |

---

## Spec Directory Structure

All specifications live in version control alongside the code:

```
TranslateCall/
├── specs/
│   ├── m1-foundation/
│   │   ├── f1.1-project-setup/
│   │   │   ├── requirements.md
│   │   │   ├── design.md
│   │   │   └── tasks.md
│   │   ├── f1.2-audio-infrastructure/
│   │   │   ├── requirements.md
│   │   │   ├── design.md
│   │   │   └── tasks.md
│   │   └── f1.3-basic-ui/
│   │       ├── requirements.md
│   │       ├── design.md
│   │       └── tasks.md
│   ├── m2-speech-pipeline/
│   │   ├── f2.1-vad-integration/
│   │   ├── f2.2-speech-to-text/
│   │   └── f2.3-text-to-speech/
│   ├── m3-translation-core/
│   │   ├── f3.1-translation-bridge/
│   │   ├── f3.2-language-management/
│   │   └── f3.3-one-way-pipeline/
│   ├── m4-full-pipeline/
│   │   ├── f4.1-bidirectional/
│   │   ├── f4.2-echo-management/
│   │   └── f4.3-video-call-integration/
│   ├── m5-beta/
│   ├── m6-enhanced-speech/
│   ├── m7-voice-cloning/
│   ├── m8-languages/
│   └── m9-launch/
├── docs/                    # Existing documentation
│   ├── poc_results/         # PoC validation results
│   └── ...
└── src/                     # Implementation (generated from specs)
```

### How to Use This Roadmap

1. **Pick the next milestone** (M1 is next)
2. **For each feature**, create its spec directory and write `requirements.md` using EARS syntax
3. **Review** requirements with stakeholders (human gate)
4. **Write** `design.md` with architecture decisions, interfaces, and data flows
5. **Review** design (human gate)
6. **Break down** into `tasks.md` with numbered, testable implementation tasks
7. **Review** tasks (human gate)
8. **Implement** following TDD: write failing test → implement → refactor
9. **Validate** against acceptance gates
10. **Move to next feature** or milestone

---

*This roadmap is a living document. It will be updated as specs are written, validated, and implemented.*

*Methodology reference: [Spec-Driven Development (Thoughtworks)](https://www.thoughtworks.com/en-us/insights/blog/agile-engineering-practices/spec-driven-development-unpacking-2025-new-engineering-practices)*
