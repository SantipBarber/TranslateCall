# F8.3 — Translation Engine Abstraction — Technical Design

## 1. Scope Reminder

This is a **preparatory refactor**, not a new feature. No new translation backend is implemented. The goal is to wire the existing Apple Translation through a `TranslationEngineSelector` so that adding future backends requires minimal changes.

## 2. Architecture Overview

### Before (Current)

```
AppContainer
    ├── outBridge = TranslationBridgeModel()
    ├── inBridge = TranslationBridgeModel()
    ├── outTranslation = AppleTranslationService(model: outBridge)   ← hardcoded
    ├── inTranslation = AppleTranslationService(model: inBridge)     ← hardcoded
    └── AudioCoordinator(outgoingTranslationService: outTranslation, ...)
```

### After (M8)

```
AppContainer
    ├── outBridge = TranslationBridgeModel()
    ├── inBridge = TranslationBridgeModel()
    ├── translationSelector = TranslationEngineSelector(             ← NEW
    │       outgoingBridge: outBridge,
    │       incomingBridge: inBridge
    │   )
    └── AudioCoordinator(
            outgoingTranslationService: translationSelector.makeOutgoingService(),
            incomingTranslationService: translationSelector.makeIncomingService(),
            ...
        )
```

## 3. TranslationEngine Enum

```swift
// File: TranslateCall/Core/Translation/TranslationEngine.swift (NEW)

enum TranslationEngine: String, Codable, Sendable, CaseIterable {
    case appleTranslation

    var displayName: String {
        switch self {
        case .appleTranslation: return "Apple Translation"
        }
    }
}
```

Future cases (NOT implemented in M8):
```swift
    // case opusMT           // On-device Opus-MT via CoreML
    // case libreTranslate   // Self-hosted LibreTranslate API
    // case argosTranslate   // Argos Translate (on-device)
```

## 4. TranslationEngineSelector

```swift
// File: TranslateCall/Core/Translation/TranslationEngineSelector.swift (NEW)

@MainActor
final class TranslationEngineSelector: ObservableObject {
    @Published private(set) var preferredEngine: TranslationEngine

    private let defaults: UserDefaults
    private static let defaultsKey = "tlk.translation.engine"

    // Apple Translation dependencies (kept here since they need SwiftUI bridge models)
    private let outgoingBridge: TranslationBridgeModel
    private let incomingBridge: TranslationBridgeModel

    init(
        outgoingBridge: TranslationBridgeModel,
        incomingBridge: TranslationBridgeModel,
        defaults: UserDefaults = .standard
    ) {
        self.outgoingBridge = outgoingBridge
        self.incomingBridge = incomingBridge
        self.defaults = defaults
        self.preferredEngine = defaults.string(forKey: Self.defaultsKey)
            .flatMap { TranslationEngine(rawValue: $0) } ?? .appleTranslation
    }

    // MARK: - Service Factories

    func makeOutgoingService() -> any TranslationService {
        switch preferredEngine {
        case .appleTranslation:
            return AppleTranslationService(model: outgoingBridge)
        }
    }

    func makeIncomingService() -> any TranslationService {
        switch preferredEngine {
        case .appleTranslation:
            return AppleTranslationService(model: incomingBridge)
        }
    }

    // MARK: - Language Pair Support

    func supports(
        source: Locale.Language,
        target: Locale.Language
    ) async -> Bool {
        switch preferredEngine {
        case .appleTranslation:
            let status = await LanguageAvailability().status(from: source, to: target)
            return status == .installed || status == .supported
        }
    }

    // MARK: - Engine Selection

    func setPreferredEngine(_ engine: TranslationEngine) {
        preferredEngine = engine
        defaults.set(engine.rawValue, forKey: Self.defaultsKey)
    }
}
```

## 5. TranslationService Protocol — Audit

The current protocol is sufficient:

```swift
protocol TranslationService: AnyObject {
    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
    func prepare(source: Locale.Language, target: Locale.Language) async throws
}
```

**Additions for future extensibility** (with default implementations so existing conformances don't break):

```swift
extension TranslationService {
    /// Human-readable engine name (for UI display). Default: "Unknown".
    var engineName: String { "Unknown" }

    /// Whether this service supports a given language pair.
    /// Default: returns true (optimistic; actual failures surface at translate-time).
    func supports(source: Locale.Language, target: Locale.Language) async -> Bool { true }
}
```

`AppleTranslationService` overrides `engineName` to return `"Apple Translation"`.

## 6. TranslationError — Additions

```swift
enum TranslationError: LocalizedError {
    case bridgeUnavailable                              // existing
    case sessionError(Error)                            // existing
    case unsupportedPair(Locale.Language, Locale.Language)  // existing
    case networkUnavailable                             // NEW — for future cloud backends
    case modelNotLoaded                                 // NEW — for future on-device backends
}
```

New cases have `errorDescription` in the existing switch.

## 7. AppContainer Wiring Changes

```swift
// Before:
let outTranslation = AppleTranslationService(model: outBridge)
let inTranslation = AppleTranslationService(model: inBridge)

// After:
let translationSelector = TranslationEngineSelector(
    outgoingBridge: outBridge,
    incomingBridge: inBridge
)
let outTranslation = translationSelector.makeOutgoingService()
let inTranslation = translationSelector.makeIncomingService()
```

`AudioCoordinator` init signature is **unchanged** — it still receives `any TranslationService` for both directions. The selector is the factory, the coordinator doesn't know about it.

`AppContainer` exposes `translationSelector` as a property so the UI can bind to `preferredEngine` in the future (not needed in M8 since there's only one engine).

## 8. File Structure

```
TranslateCall/Core/Translation/
├── AppleTranslationService.swift            (MODIFY — add engineName)
├── LanguagePairManager.swift                (existing, no change)
├── TranslationService.swift                 (MODIFY — add default extensions)
├── TranslationEngine.swift                  (NEW)
└── TranslationEngineSelector.swift          (NEW)

TranslateCall/App/
├── AppContainer.swift                       (MODIFY — use selector)
├── TranslationBridge.swift                  (existing, no change)
```

## 9. What "Adding a New Backend" Looks Like (Future)

To add e.g. Opus-MT in a future milestone, a developer would:

1. **Create** `OpusMTTranslationService: TranslationService` (actor, implements translate/prepare)
2. **Add** `case opusMT` to `TranslationEngine`
3. **Add** routing in `TranslationEngineSelector.makeOutgoingService()`:
   ```swift
   case .opusMT:
       return OpusMTTranslationService(modelPath: ...)
   ```
4. **No changes** to `AudioCoordinator`, `TranslationBridge`, or UI (other than adding the engine to a Picker)

This is the extensibility goal: **3 files touched to add a new translation backend**.

## 10. Testing Strategy

| Test | Type | Description |
|------|------|-------------|
| TranslationEngineSelectorTests | Unit | Default engine, persistence, makeOutgoingService returns AppleTranslationService |
| TranslationEngineTests | Unit | Enum cases, displayName, rawValue |
| TranslationServiceExtensionTests | Unit | Default engineName, default supports() |
| AppContainerWiringTests | Unit | Verify selector is used, services are created correctly |
| ExistingTranslationTests | Regression | All existing tests pass without modification |

Mock strategy: `TranslationEngineSelector` receives `TranslationBridgeModel` instances. Tests create real (empty) bridge models — they don't need SwiftUI context for unit tests since we test the selector, not the bridge.

## 11. Risks

| Risk | Mitigation |
|------|------------|
| Over-abstraction for one backend | Minimal code: ~80 LOC for selector + enum. Worth it for architectural cleanliness. |
| Breaking existing tests | Wiring change is in AppContainer only. AudioCoordinator interface unchanged. |
| Future backends need different init patterns | Selector holds all dependencies; each case in the switch handles its own init. |
