# F8.3 — Translation Engine Abstraction — Tasks

## Dependency Graph

```
T1 (TranslationEngine enum)
 │
 ├──▶ T2 (TranslationService protocol extensions)
 │
 ├──▶ T3 (TranslationEngineSelector)
 │        │
 │        ▶ T4 (AppContainer rewiring)
 │
 └──▶ T5 (Tests)
```

**Recommended order**: T1 → T2 → T3 → T4 → T5

---

## T1 — Create `TranslationEngine` enum

**File**: `TranslateCall/Core/Translation/TranslationEngine.swift` (NEW)

**Steps**:
1. Create `TranslationEngine: String, Codable, Sendable, CaseIterable` with one case: `.appleTranslation`
2. Add `displayName: String` computed property returning `"Apple Translation"`
3. Add comments indicating future cases (opusMT, libreTranslate) as reference

**Acceptance**:
- Compiles with zero warnings
- Enum is accessible from `@MainActor` and actor contexts

---

## T2 — Extend `TranslationService` protocol and `TranslationError`

**File**: `TranslateCall/Core/Translation/TranslationService.swift` (MODIFY)

**Steps**:
1. Add protocol extension with default implementations:
   ```swift
   extension TranslationService {
       var engineName: String { "Unknown" }
       func supports(source: Locale.Language, target: Locale.Language) async -> Bool { true }
   }
   ```
2. Add two new cases to `TranslationError`:
   - `.networkUnavailable`
   - `.modelNotLoaded`
3. Add `errorDescription` for the new cases
4. Override `engineName` in `AppleTranslationService` to return `"Apple Translation"`

**Acceptance**:
- Existing code compiles without changes (default implementations)
- All existing translation tests pass

---

## T3 — Create `TranslationEngineSelector`

**File**: `TranslateCall/Core/Translation/TranslationEngineSelector.swift` (NEW)

**Steps**:
1. Create `@MainActor final class TranslationEngineSelector: ObservableObject`
2. Properties:
   - `@Published private(set) var preferredEngine: TranslationEngine`
   - `private let defaults: UserDefaults`
   - `private let outgoingBridge: TranslationBridgeModel`
   - `private let incomingBridge: TranslationBridgeModel`
3. Init: accept bridges + defaults, load preference from UserDefaults
4. `makeOutgoingService() -> any TranslationService` — switch on preferredEngine, return `AppleTranslationService(model: outgoingBridge)`
5. `makeIncomingService() -> any TranslationService` — same pattern with incomingBridge
6. `supports(source:target:) async -> Bool` — delegate to `LanguageAvailability().status(from:to:)`
7. `setPreferredEngine(_:)` — update published property + persist

**Acceptance**:
- `makeOutgoingService()` returns a valid `AppleTranslationService`
- `makeIncomingService()` returns a separate instance
- Preference persists across instantiations

---

## T4 — Rewire `AppContainer`

**File**: `TranslateCall/App/AppContainer.swift` (MODIFY)

**Steps**:
1. Add `let translationSelector: TranslationEngineSelector` property
2. In `init()`:
   - Create `TranslationEngineSelector(outgoingBridge: outBridge, incomingBridge: inBridge)`
   - Replace direct `AppleTranslationService(model:)` calls with `translationSelector.makeOutgoingService()` / `.makeIncomingService()`
   - Assign selector to property
3. Remove direct `outTranslation` / `inTranslation` local variables (now created by selector)

**Acceptance**:
- App launches and translation works exactly as before
- `AudioCoordinator` init signature unchanged
- No observable behavior change

---

## T5 — Tests

**File**: `TranslateCallTests/TranslationEngineSelectorTests.swift` (NEW)

**Tests**:
1. `testDefaultEngine` — verify default is `.appleTranslation`
2. `testSetPreferredEnginePersists` — set engine, create new selector with same UserDefaults, verify persisted
3. `testMakeOutgoingServiceReturnsAppleTranslation` — verify returned service is `AppleTranslationService`
4. `testMakeIncomingServiceReturnsSeparateInstance` — outgoing and incoming are different instances
5. `testSupportsAppleTranslationPair` — verify delegates to LanguageAvailability (mock or use known-supported pair EN→ES)
6. `testTranslationEngineDisplayName` — verify `.appleTranslation.displayName == "Apple Translation"`
7. `testTranslationErrorNewCases` — verify `.networkUnavailable` and `.modelNotLoaded` have error descriptions

**Acceptance**:
- All 7 tests pass
- Zero warnings
