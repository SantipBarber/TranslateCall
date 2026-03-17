# F8.3 — Translation Engine Abstraction (Preparation)

## Overview

Ensure the translation subsystem is ready for future alternative backends (Opus-MT, LibreTranslate, custom models) without implementing any new backend in M8. This is a preparatory refactor to validate extensibility.

## Motivation

- Apple Translation covers ~20 language pairs, which is sufficient for M8
- Future milestones may need alternative translation backends for:
  - Language pairs Apple doesn't support
  - Fully offline translation without Apple framework
  - Community-contributed translation models
- The current `TranslationService` protocol already exists, but the wiring in `AppContainer` and `AudioCoordinator` is hardcoded to Apple Translation
- This feature ensures the architecture is ready without over-engineering

## Functional Requirements

### FR-8.3.1 — TranslationService Protocol Audit

**REQ-A-01**: The existing `TranslationService` protocol SHALL be reviewed and confirmed sufficient for alternative backends:
```swift
protocol TranslationService: AnyObject {
    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
    func prepare(source: Locale.Language, target: Locale.Language) async throws
}
```

**REQ-A-02**: IF the protocol needs additions for alternative backends (e.g., `supportedPairs() -> [(Locale.Language, Locale.Language)]`, `engineName: String`) **THEN** these SHALL be added with default implementations so existing conformances are not broken.

**REQ-A-03**: The `TranslationError` enum SHALL be reviewed for completeness. At minimum it SHALL include:
- `bridgeUnavailable` (Apple-specific, keep)
- `sessionError(Error)` (Apple-specific, keep)
- `unsupportedPair(Locale.Language, Locale.Language)` (generic, keep)
- `networkUnavailable` (new — for future cloud backends)
- `modelNotLoaded` (new — for future on-device model backends)

### FR-8.3.2 — TranslationEngineSelector (Preparation)

**REQ-A-10**: A `TranslationEngine` enum SHALL be created with at minimum:
```swift
enum TranslationEngine: String, Codable, Sendable, CaseIterable {
    case appleTranslation  // Current — Apple Translation Framework
    // Future cases added in subsequent milestones:
    // case opusMT         // On-device Opus-MT via CoreML/ONNX
    // case libreTranslate // Self-hosted LibreTranslate API
}
```

**REQ-A-11**: A `TranslationEngineSelector` (`@MainActor ObservableObject`) SHALL be created, following the pattern of `STTEngineSelector` and `TTSEngineSelector`, with:
- `@Published preferredEngine: TranslationEngine`
- `func makeService(for source: Locale.Language, target: Locale.Language) -> any TranslationService`
- UserDefaults persistence of preference

**REQ-A-12**: For M8, `TranslationEngineSelector.makeService()` SHALL always return the Apple Translation service. The selector exists as a placeholder for future routing logic.

### FR-8.3.3 — AppContainer Wiring Update

**REQ-A-20**: `AppContainer` SHALL create `TranslationEngineSelector` and use it to provide translation services to `AudioCoordinator`, instead of directly instantiating `AppleTranslationService`.

**REQ-A-21**: `AudioCoordinator`'s translation service injection SHALL remain unchanged (`any TranslationService`). The selector is the factory, not the coordinator.

### FR-8.3.4 — Language Capability Matrix

**REQ-A-30**: `TranslationEngineSelector` SHALL expose a method to query whether a given language pair is supported:
```swift
func supports(source: Locale.Language, target: Locale.Language) async -> Bool
```

**REQ-A-31**: For M8, this SHALL delegate to `LanguageAvailability().status(from:to:)` (Apple's existing API). In future milestones, it will aggregate availability across multiple engines.

**REQ-A-32**: The UI (LanguagePairView) SHALL use this capability check to indicate unsupported pairs (grey out, warning icon, or tooltip).

## Non-Functional Requirements

**NFR-A-01**: This feature SHALL NOT change any observable behavior. It is a pure architectural refactor.

**NFR-A-02**: All existing tests SHALL continue to pass without modification (or with minimal adaptation to the new wiring).

**NFR-A-03**: The `TranslationEngineSelector` SHALL be testable with mock services (same pattern as STT/TTS selectors).

**NFR-A-04**: No new external dependencies SHALL be introduced in this feature.

## Out of Scope (Deferred)

- Implementing Opus-MT, LibreTranslate, or any alternative translation backend
- Plugin/package architecture for community-contributed translation models
- Quality metrics per engine/pair comparison
- Automatic engine selection based on quality scores

## Acceptance Criteria

- [ ] AC-A-01: `TranslationEngine` enum exists with `.appleTranslation` case
- [ ] AC-A-02: `TranslationEngineSelector` exists and routes to Apple Translation
- [ ] AC-A-03: `AppContainer` uses selector instead of direct `AppleTranslationService` instantiation
- [ ] AC-A-04: All existing translation tests pass without changes
- [ ] AC-A-05: Adding a new `TranslationEngine` case requires only: (a) a new `TranslationService` conformance, (b) a factory in the selector, (c) routing logic — no changes to `AudioCoordinator` or UI
- [ ] AC-A-06: `supports(source:target:)` correctly reports Apple Translation availability
- [ ] AC-A-07: 5+ unit tests for TranslationEngineSelector
