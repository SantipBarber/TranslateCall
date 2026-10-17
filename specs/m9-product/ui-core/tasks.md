# M9 UI core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The everyday flow of the new UI, end to end. The user picks the call app, their language and the other side's language, then presses Start. Models are chosen automatically. A small non-activating panel floating over the call shows that translation is alive. The menu bar popover follows the prototype. Settings (⌘,) holds the General tab and a temporary "Advanced (legacy)" tab with today's technical controls.

**Architecture:**
- **Pure rules.** A small set of pure, unit-tested rules derives everything the views show:
  - `ModelCatalog`/`ModelChoice` for automatic engines;
  - `Readiness` for the primary button and cards;
  - `DirectionState`/`PanelTitle` for chips and the header;
  - `MenuBarDot`;
  - `LanguageOrdering`;
  - `DirectionCopy`.
- **Coordinator additions.** `AudioCoordinator` gains published per-direction flags, a capped transcript and Pause (a `PauseGate` that zeroes buffers before each VAD, like `MicEchoGate`).
- **Session model.** A new `CallSessionModel` turns the coordinator's state into panel/popover state and routes mid-call alerts to notices.
- **AppKit pieces.** `StatusPanel` is a non-activating `NSPanel`. `SettingsOpener` and the existing `MainWindowOpener` hand SwiftUI's `openSettings`/`openWindow` to AppKit contexts.
- **Views.** SwiftUI views are thin over these models and are checked against the pen.dev frames.

**Tech Stack:**
- Swift 6 (app target: default MainActor isolation, approachable concurrency, `MemberImportVisibility`);
- SwiftUI + AppKit (`NSPanel`, `NSStatusItem`, `NSPopover`, `Settings` scene, `SMAppService`);
- Combine, `Synchronization.Mutex`;
- FluidAudio (`AsrModels.modelsExist`), WhisperKit, mlx-audio-swift (cache layout only);
- ScreenCaptureKit (unchanged);
- Swift Testing, `just`, SwiftLint (strict), opengrep;
- the pencil MCP, to read `design/translatecall.pen`.

**Spec:** `specs/m9-product/ui-core/requirements.md`, `specs/m9-product/ui-core/design.md` (APPROVED 2026-10-17, D-1…D-6). Context: `specs/m9-product/ui-redesign/design-brief.md` (text-fitting rules), `specs/m9-product/ui-redesign/roadmap.md`.

## Global Constraints

- **Branches and PR:**
  - work on branch `feat/m9-ui-core`, created from `spec/m9-ui-swiftui`; spec and code ship in one PR (the M8.5 practice);
  - never commit to `main`;
  - `just pr` must pass before the PR;
  - execution is subagent-driven (the user's standing choice).
- Commits: Conventional Commits; end every message with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
- **Build settings:**
  - `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`;
  - the app target has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: a type used off the main actor must say `nonisolated` (and its extensions too: `nonisolated extension …`);
  - the test target has no default isolation: suites touching app types are `@MainActor`.
- New files are picked up automatically (`PBXFileSystemSynchronizedRootGroup`), and a `.json` or `.xcstrings` file next to sources is bundled as a resource. Never edit `project.pbxproj`.
- Unit tests use no audio device, no ML model, no network, no real `NSWorkspace` launches and no `UserDefaults.standard` (always a `UserDefaults(suiteName: "test-\(UUID())")`). There are no fixed sleeps except where a test drives a fake that sleeps: wait with `waitUntil` (`TranslateCallTests/Support/AsyncTestHelpers.swift`) or a `TestClock` (`sleeperCount`, then `advance(by:)`).
- Run one or more unit suites with `just test-only <SuiteStructName> […]`. The unit tier is `just test`, lint is `just lint` (`swiftlint --strict`), static analysis is `just scan`, and the gate is `just pr`.
- **SwiftLint strict** (app target only):
  - lines ≤ 120;
  - function bodies ≤ 50 lines, type bodies ≤ 250 lines (extensions do not count), files ≤ 400 lines;
  - cyclomatic complexity ≤ 10;
  - identifiers ≥ 3 characters;
  - tuples ≤ 2 members;
  - no trailing commas, no void-returning ternaries, no superfluous `swiftlint:disable`;
  - sorted imports.

  Budgets close to the limit:
  - `AudioViewModel.swift`: 399 lines, so do not grow it (P1);
  - `AudioCoordinator+Pipeline.swift`: about 395 lines after Task 9;
  - `AppContainer.init`: 50 lines (P12).
- **UI rules:**
  - UI strings are English, through the String Catalog (Task 14): `Text("…")` literals are keys automatically, and model code uses `String(localized:)`.
  - Native look only: system font, SF Symbols, semantic colours through `Theme` (Task 14), automatic light/dark.
  - **Text fitting (brief):**
    - single-line labels use `.lineLimit(1)` and `.truncationMode(.tail)` and never push siblings out;
    - the panel's last line has `.lineLimit(2)`;
    - body copy wraps.
- **Prototype:** read `design/translatecall.pen` only through the pencil MCP: `get_app_state`, then `execute` with `TakeScreenshot([...])` or `Get`. Never use Read or Grep on it. Each view task names the light and dark frame node ids.
  - Before writing the view, screenshot both frames.
  - Before review, compare them with screenshots of the view's Xcode previews (light and dark). The prototype's Inter and Lucide are stand-ins for the system font and SF Symbols.
  - pen.dev saves to the main checkout: never switch the main checkout to a branch without `design/translatecall.pen`.
- The latency thread works in `/Users/spbarber/Desarrollo/TranslateCall-bench` (`spec/m9-benchmark`). Do not touch it. Its `TraceSink` is not used here (D-3).

## Review Focus

- **The call app is in full screen and the user types in its chat while the panel updates or is dragged.** The call app stays frontmost and receives every keystroke. This is pinned in Task 2 (`neverTakesFocus`, `showHide`) and checked by hand in Task 2 step 6 and checklist U3.
- **"Open Zoom and start" while Zoom never manages to launch** (quarantine prompt, deleted app). The session still starts after 15 s and incoming shows "Can't hear Zoom" with Retry. This is pinned in Task 13 (`startAfterLaunchTimeout`).
- **Pause pressed while a sentence is being translated.** The sentence appears in the transcript but is never spoken, and nothing plays during the pause. This is pinned in Task 9 (`translationReturningAfterPauseIsNotSpoken`).
- **An engine fails while the session starts** (e.g. STT activation throws) but the session goes active, so the main window closes. The error becomes a panel notice: no modal over the call, and no alert lost behind a closed window. This is pinned in Task 13 (`startErrorOfActiveSessionIsNotice`).
- **Only the reverse direction's pack is missing.** The button says "Download Español to start", not "Ready". This is pinned in Task 12 (`pairReadiness`).

## Decisions made while planning (spec deviations are marked ⚠)

Every logic task below (1–13) was implemented on a throwaway clone of `spec/m9-ui-swiftui` at feceed3 while planning.
- **Checks passed:** `just build`, `just lint`, `just scan`, every new suite and the whole unit tier.
- **Repeated runs:** the concurrency suites (`AudioCoordinatorSessionTests`, `CallSessionModelTests`) passed 3 runs in a row.
- **Not replayed:** view tasks 14–22.

| # | Point | Choice |
|---|-------|--------|
| P1 ⚠ | design §5.1 puts the new panel state on `AudioViewModel` | `AudioViewModel.swift` is at 399 lines (limit 400), so panel and popover state lives in a new `CallSessionModel` (Task 13). It observes `AudioCoordinator` and `AudioViewModel.$errorAlert` and owns the mid-call notice routing (REQ-UI-82/36). `AudioViewModel` changes in one place only: the call-app retry hook (Task 11). |
| P2 | `AudioCoordinator.swift` (398 lines) and `+Pipeline.swift` (381 lines) | The TTS-monitor actions move verbatim to `AudioCoordinator+Monitor.swift`, and pause and transcript code goes to `AudioCoordinator+Session.swift` (Tasks 8–9). The new stored properties have internal setters, because extensions in other files write them (as `incomingStatus` already does). |
| P3 | `TranscriptEntry.Direction` (design §4.1) | A top-level `nonisolated enum TranscriptDirection { case outgoing, incoming }`, also used by `ModelCatalog`, `LatencyProvider` and `DirectionCopy`. |
| P4 | Parakeet for incoming | `ModelChoice.stt` takes a direction, and Parakeet is never chosen for incoming: one shared ASR model, outgoing only, as today. |
| P5 | The shared automatic flag | Both selectors read `tlk.models.automatic` from their `defaults` on every use (computed `isAutomatic`, default `true`), so a manual pick in one selector switches the other at once. The flag lives on `ModelChoice.automaticKey`. |
| P6 | Existing selector tests | Their helpers set `tlk.models.automatic = false`, so they keep covering manual mode unchanged: `STTEngineSelectorTests`, `TTSEngineSelectorTests`, `TTSEngineSelectorVoiceCloneTests`, `EdgeTTSTests`, `WhisperSTTTests`. |
| P7 ⚠ | Not in design: with a `Settings` scene, `MainWindowOpener.show` would raise the Settings window (it can become main) instead of the setup window | `MainWindowCandidate` gains `sceneIdentifier`, and only windows whose id starts with `"main-"` count. The test host shows the setup window's id is `main-AppWindow-1` (Task 1). |
| P8 | Qwen `isModelCached()` checks `~/.cache/huggingface/hub/models--…`, a folder that exists without usable weights | It checks mlx-audio's working copy `~/.cache/huggingface/hub/mlx-audio/<owner>_<name>` for `config.json` plus a non-empty `.safetensors`, which is `ModelUtils.resolveOrDownloadModel`'s own rule. It is `nonisolated` and takes a `home` for tests (Task 4). |
| P9 | The Whisper size is not persisted | The cache check uses `WhisperConfiguration.default` (`.base`), the size `STTEngineSelector` loads. |
| P10 | `CallAppMonitor.waitUntilRunning` | It polls every 200 ms and calls `refresh()` (a task-group version hit Swift 6 region-isolation errors). Polling also survives a missed launch notification. |
| P11 | Kokoro preload vs voice clone | The preloader never loads Kokoro while `voiceCloningEnabled` is on, even before the clone is loaded: one MLX TTS model at a time (NF-04). |
| P12 | `AppContainer.init` is at its 50-line limit | A `UIServices` struct (`uiServices`) holds the preloader, the call-app monitor and the session model. `VoiceProfileManager(...)` is written on two lines to make room. |
| P13 | Readiness complexity | Card building is the separate `Readiness.cards(...)`, to stay under cyclomatic complexity 10. |
| P14 | Pre-call alerts (REQ-UI-36) | `MainSetupView` presents `AudioViewModel.errorAlert` only while `!isStarting`. `CallSessionModel` turns an alert into a notice when the session is active (mid-call, or raised during a start that went active). Otherwise it stays for the window. |
| P15 ⚠ | The prototype's lost-audio copy "No sound from Teams for 20 s…" | Silence detection is out of scope (design call 6). The line comes from `DirectionCopy.unavailableLine(reason, appName:)`, and the chip reads "Can't hear <App>". |
| P16 | Pre-existing flake (not caused by this plan) | `LanguagePairManagerTests.persistsTargetLanguageToUserDefaults` uses `UserDefaults.standard` in a parallel suite. It failed once in 4 full unit runs on the replay clone. Task 23 records it in the backlog (A29); do not "fix" it inside this feature. |
| P17 | "Downloaded languages" (REQ-UI-71) | There is no API that lists installed packs. The General tab checks `LanguageAvailability().status(from: sourceLanguage, to: L)` for each supported language `L` when the tab appears, lists those that are `.installed` (plus the source language) by display name, and "Manage…" opens `x-apple.systempreferences:com.apple.Localization-Settings.extension`. |
| P18 | Menu bar glyph | The SF Symbol `translate`, with the coloured dot drawn over it (`MenuBarDot`). The old `MenuBarController.iconName(state:isCapturing:)` and its test are removed in Task 22. |

## File Structure

```
TranslateCall/
  App/
    MainWindowOpener.swift              MOD T1 sceneIdentifier filter
    TranslateCallApp.swift              MOD T1 Settings scene; T2 DEBUG panel command; T16 MainSetupView; T17 panel wiring;
                                            T22 "Skip my next sentence" command
    AppContainer.swift                  MOD T6 UIServices (preloader); T11 +monitor; T13 +callSession; T17 +statusPanel
  Core/Models/                          NEW T3 ModelCatalog.swift, ModelCatalog.json, ModelChoice.swift;
                                            T4 ModelCache.swift; T5 ModelChoice+Selectors.swift; T6 ModelPreloader.swift
  Core/Session/                         NEW T3 TranscriptEntry.swift; T7 PauseGate.swift; T10 DirectionState.swift;
                                            T13 LatencyProvider.swift
  Core/Setup/                           NEW T11 CallApp.swift, CallAppMonitor.swift; T12 Permissions.swift
    SetupManager.swift                  MOD T11 selectCaptureApp(bundleID:), selectedCaptureBundleID
  Core/Audio/
    AudioCoordinator.swift              MOD T8 UI state + hooks; T9 pause state
    AudioCoordinator+Pipeline.swift     MOD T8 transcript/translating; T9 pause gates + paused guards
    AudioCoordinator+Monitor.swift      NEW T8 (moved TTS-monitor actions)
    AudioCoordinator+Session.swift      NEW T8 transcript, incoming VAD state; T9 pause/resume
  Core/STT/STTEngineSelector.swift      MOD T5 automatic branch, catalog/cacheProbe
  Core/TTS/TTSEngineSelector.swift      MOD T5 automatic branch, catalog/cacheProbe
  Core/VoiceCloning/QwenCloneModelManager.swift  MOD T4 isModelCached fix
  Features/Main/                        NEW T12 Readiness.swift, LanguageOrdering.swift; T15 MainSetupModel.swift,
                                            MainSetupView.swift, CallAppSection.swift, StateCards.swift;
                                            T16 LanguageSection.swift, VoiceSection.swift, SetupFooter.swift
    AudioViewModel.swift                MOD T11 retry hook on selectedCaptureBundleID
  Features/Session/CallSessionModel.swift        NEW T13
  Features/StatusPanel/                 NEW T2 StatusPanel.swift; T10 DirectionCopy.swift; T17 StatusPanelView.swift,
                                            DirectionRow.swift, PanelNotices.swift; T18 TranscriptView.swift
  Features/MenuBar/                     NEW T10 MenuBarIcon.swift; MOD T19 MenuBarController.swift,
                                            MenuBarPopoverView.swift (rewritten)
  Features/Settings/                    NEW T1 SettingsOpener.swift, SettingsView.swift; T13 UISettingsKeys.swift;
                                            T20 GeneralSettingsView.swift; T21 LegacyAdvancedSettingsView.swift,
                                            Legacy/ (moved views)
  UI/                                   NEW T14 Theme.swift, Chip.swift, SectionHeader.swift, CardBox.swift
  Resources/Localizable.xcstrings       NEW T14
  Features/ContentView*.swift + old Main/ views  DEL T22 (REQ-UI-80)
TranslateCallTests/
  SettingsOpenerTests, StatusPanelTests (T1, T2); MainWindowOpenerTests MOD T1
  ModelCatalogTests T3; ModelCacheTests T4 (+QwenCloneModelManagerTests MOD); ModelChoiceSelectorTests T5
  (+ manual-mode pins in 5 existing suites); ModelPreloaderTests T6; PauseGateTests T7;
  AudioCoordinatorSessionTests T8/T9; DirectionStateTests + UICopyTests (incl. MenuBarDotTests) T10;
  CallAppMonitorTests, Mocks/FakeWorkspace.swift, SetupManagerTests MOD, AudioViewModelTests MOD T11;
  ReadinessTests T12 (+ LanguageOrdering cases in UICopyTests); CallSessionModelTests T13;
  Mocks/MockVADService.swift MOD T8 (injectVADState); TranslationPipelineTests.swift MOD T8 (MockTranslationService hold)
  ConversationSettingsViewTests, IncomingStatusBannerTests, StatusBadgeView/iconName cases  DEL/PORT T22
specs/m9-product/backlog.md (new) or specs/m8.5-stabilization/backlog.md, docs/ARCHITECTURE.md   MOD T23
```

**Dependency order:**
- T1 → T2 → T3 → T4 → T5 → T6;
- T7 → T8 → T9;
- T10 needs T3;
- T11 is independent;
- T12 needs T10 (`SessionPhase`) and T11 (`CallAppRow`);
- T13 needs T8 through T12;
- the view tasks T14 → T22 follow in order;
- then T23 and T24.

**Model per task (subagent-driven execution):**
- **opus:** T2 (StatusPanel), T6 (ModelPreloader), T7 (PauseGate), T8 and T9 (coordinator), T13 (CallSessionModel), and the final whole-branch review;
- **sonnet:** all other tasks.

---

### Task 1: Settings scene, `SettingsOpener`, and the main-window lookup that ignores Settings (sonnet)

**Files:**
- Create: `TranslateCall/Features/Settings/SettingsOpener.swift`, `TranslateCall/Features/Settings/SettingsView.swift`
- Modify: `TranslateCall/App/MainWindowOpener.swift` (protocol + filter), `TranslateCall/App/TranslateCallApp.swift` (Settings scene, hand-over)
- Test: `TranslateCallTests/SettingsOpenerTests.swift` (new), `TranslateCallTests/MainWindowOpenerTests.swift` (fake + one test)

**Interfaces:**
- Produces:
  - `enum SettingsTab: String, CaseIterable, Identifiable { case general, advancedLegacy }`;
  - `SettingsOpener.shared.open(tab:) -> Bool` (discardable);
  - `SettingsOpener.tabKey = "ui.settings.tab"`;
  - `SettingsOpener.openSettings: (() -> Void)?`;
  - `MainWindowCandidate.sceneIdentifier: String?`;
  - `SettingsView`, whose tabs are filled by Tasks 20–21.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/SettingsOpenerTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

@Suite("SettingsOpener (M9 UI core REQ-UI-70)") @MainActor
struct SettingsOpenerTests {

    @Test("open(tab:) stores the tab, activates the app and calls SwiftUI's openSettings")
    func opensOnTab() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        var activations = 0
        var opens = 0
        let opener = SettingsOpener(defaults: defaults, activate: { activations += 1 })
        opener.openSettings = { opens += 1 }

        #expect(opener.open(tab: .advancedLegacy))
        #expect(defaults.string(forKey: SettingsOpener.tabKey) == "advancedLegacy")
        #expect(activations == 1 && opens == 1)
    }

    @Test("before the setup window handed openSettings over, it reports failure but keeps the tab")
    func noHandlerYet() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let opener = SettingsOpener(defaults: defaults, activate: {})
        #expect(!opener.open(tab: .general))
        #expect(defaults.string(forKey: SettingsOpener.tabKey) == "general")
    }
}
```

In `TranslateCallTests/MainWindowOpenerTests.swift`, give `FakeWindow` a `sceneIdentifier` (default `"main-AppWindow-1"`, so the existing tests keep their meaning):
```swift
    let isMiniaturized: Bool
    let sceneIdentifier: String?
    private(set) var raised = false

    init(canBecomeMain: Bool, isVisible: Bool, isMiniaturized: Bool = false,
         sceneIdentifier: String? = "main-AppWindow-1") {
        self.canBecomeMain = canBecomeMain
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
        self.sceneIdentifier = sceneIdentifier
    }
```
and add to `MainWindowOpenerTests`:
```swift
    @Test("a visible Settings window is not the main window: a new one is requested (M9 UI core)")
    func settingsWindowIsNotMain() {
        let (opener, opens) = makeOpener()
        let settings = FakeWindow(canBecomeMain: true, isVisible: true,
                                  sceneIdentifier: "com_apple_SwiftUI_Settings_window")
        #expect(opener.show(in: [settings]) == .openRequested)
        #expect(opens() == 1)
        #expect(!settings.raised)
    }
```

- [ ] **Step 2: Run them, expect a compile failure**

Run: `just test-only SettingsOpenerTests MainWindowOpenerTests`
Expected: FAIL. `SettingsOpener` is undefined, and `FakeWindow` does not conform (`sceneIdentifier`).

- [ ] **Step 3: Implement**

`TranslateCall/Features/Settings/SettingsOpener.swift`:
```swift
import AppKit

/// The Settings tabs (REQ-UI-70). `advancedLegacy` is replaced by feature 2.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case advancedLegacy
    var id: String { rawValue }
}

/// Opens Settings on a given tab from anywhere, AppKit contexts included (status item, NSPanel).
/// SwiftUI's `openSettings` only exists inside a view: the setup window hands it over, the same
/// pattern as `MainWindowOpener` (design §7.3).
@MainActor
final class SettingsOpener {
    static let shared = SettingsOpener()
    /// `@AppStorage` key of the selected tab, read by `SettingsView`.
    static let tabKey = "ui.settings.tab"

    /// SwiftUI's `openSettings`; set once the first setup window appears.
    var openSettings: (() -> Void)?
    private let defaults: UserDefaults
    private let activate: () -> Void

    init(defaults: UserDefaults = .standard, activate: @escaping () -> Void = { NSApp.activate() }) {
        self.defaults = defaults
        self.activate = activate
    }

    /// Selects `tab`, brings the app forward and opens (or raises) the Settings window.
    @discardableResult
    func open(tab: SettingsTab) -> Bool {
        defaults.set(tab.rawValue, forKey: Self.tabKey)
        activate()
        guard let openSettings else { return false }
        openSettings()
        return true
    }
}
```

`TranslateCall/App/MainWindowOpener.swift`: add to the protocol and the `NSWindow` conformance, and filter in `show`. The setup window's identifier is `main-AppWindow-1`, as observed in the test host:
```swift
    var isMiniaturized: Bool { get }
    /// SwiftUI's scene window identifier, e.g. "main-AppWindow-1" for the `WindowGroup(id: "main")`.
    var sceneIdentifier: String? { get }
    func raise()
}

extension NSWindow: MainWindowCandidate {
    var sceneIdentifier: String? { identifier?.rawValue }
```
```swift
        // Only the setup window counts: the Settings window can become main too (M9 UI core).
        if let window = windows.first(where: { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)
            && $0.sceneIdentifier?.hasPrefix(Self.windowID + "-") == true }) {
```

`TranslateCall/Features/Settings/SettingsView.swift`: a `TabView(selection:)` bound to `@AppStorage(SettingsOpener.tabKey) private var tab = SettingsTab.general.rawValue`, with two tabs:
- **General:** `Label("General", systemImage: "gearshape")`, with a placeholder `Text("General")`;
- **Advanced (legacy):** `Label("Advanced (legacy)", systemImage: "slider.horizontal.3")`, with a placeholder.

The view has `.frame(width: 560)`. Tasks 20–21 replace the placeholders.

`TranslateCall/App/TranslateCallApp.swift`:
- add `@Environment(\.openSettings) private var openSettings` next to `openWindow`;
- add a `Settings { SettingsView() }` scene after the `WindowGroup`, injecting the same environment objects;
- in the existing `.onAppear`, right after the `MainWindowOpener` hand-over, add `SettingsOpener.shared.openSettings = { [openSettings] in openSettings() }`.

Keep the A26 lines (`translationHost.show()` first) exactly as they are.

- [ ] **Step 4: Run the tests**

Run: `just test-only SettingsOpenerTests MainWindowOpenerTests TranslationHostWindowTests`
Expected: PASS.

- [ ] **Step 5: Manual check**

Run: `just build`, then open `build/DerivedData/Build/Products/Debug/TranslateCall.app`.
- The main window opens at launch (A26).
- ⌘, opens Settings with two tabs.
- With Settings frontmost, the status item's right-click "Open Main Window" raises the main window, not Settings.
- Close the main window, then "Open Main Window" reopens it.

- [ ] **Step 6: Commit**

```bash
git add TranslateCall/Features/Settings TranslateCall/App/MainWindowOpener.swift TranslateCall/App/TranslateCallApp.swift \
  TranslateCallTests/SettingsOpenerTests.swift TranslateCallTests/MainWindowOpenerTests.swift
git commit -m "feat(ui): Settings scene and SettingsOpener; main-window lookup ignores Settings (M9 UI core T1)"
```

---

### Task 2: `StatusPanel`, a non-activating `NSPanel`, and its controller (opus)

**Files:**
- Create: `TranslateCall/Features/StatusPanel/StatusPanel.swift`
- Modify: `TranslateCall/App/TranslateCallApp.swift` (DEBUG-only command, removed in Task 17)
- Test: `TranslateCallTests/StatusPanelTests.swift`

**Interfaces:**
- Produces:
  - `final class StatusPanel: NSPanel` (`init(contentRect:)`, `static defaultOrigin(size:visibleFrame:inset:)`, `static resized(_:to:)`);
  - `@MainActor final class StatusPanelController`:
    - `init(content: NSView, size: NSSize, autosaveName: String? = "StatusPanel", screenFrame: @escaping () -> NSRect?)`;
    - `show()`, `hide()`, `resize(to:)`, `isVisible`, `panel`.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/StatusPanelTests.swift`:
```swift
import AppKit
import Testing
@testable import TranslateCall

@Suite("StatusPanel (M9 UI core REQ-UI-41)") @MainActor
struct StatusPanelTests {

    private func makeController() -> StatusPanelController {
        StatusPanelController(content: NSView(), size: NSSize(width: 320, height: 174), autosaveName: nil,
                              screenFrame: { NSRect(x: 0, y: 0, width: 1440, height: 875) })
    }

    @Test("floating, non-activating, on every Space and over full screen; never key or main")
    func neverTakesFocus() {
        let panel = makeController().panel
        defer { panel.close() }
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.isFloatingPanel)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.isMovableByWindowBackground)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.isExcludedFromWindowsMenu)
    }

    @Test("default position: top-right of the visible frame, inset 16 pt")
    func defaultPosition() {
        let controller = makeController()
        defer { controller.panel.close() }
        #expect(controller.panel.frame.origin == NSPoint(x: 1440 - 320 - 16, y: 875 - 174 - 16))
    }

    @Test("show does not make it key; hide orders it out")
    func showHide() {
        let controller = makeController()
        defer { controller.panel.close() }
        controller.show()
        #expect(controller.isVisible)
        #expect(!controller.panel.isKeyWindow)
        controller.hide()
        #expect(!controller.isVisible)
    }

    @Test("resizing keeps the top edge (compact → expanded grows down)")
    func resizeKeepsTop() {
        let controller = makeController()
        defer { controller.panel.close() }
        let top = controller.panel.frame.maxY
        controller.resize(to: NSSize(width: 340, height: 380))
        #expect(controller.panel.frame.maxY == top)
        #expect(controller.panel.frame.size == NSSize(width: 340, height: 380))
    }

    @Test("the panel never qualifies as the main window for the menu bar's lookup")
    func notAMainCandidate() {
        let controller = makeController()
        defer { controller.panel.close() }
        controller.show()
        #expect(MainWindowOpener().show(in: [controller.panel]) == .openRequested)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `just test-only StatusPanelTests`
Expected: FAIL (`StatusPanelController` undefined).

- [ ] **Step 3: Implement** `TranslateCall/Features/StatusPanel/StatusPanel.swift`:
```swift
import AppKit

// MARK: - StatusPanel

/// The in-call status panel's window (REQ-UI-41, design §7.2): floating, non-activating, on every
/// Space and over full-screen apps, draggable by its background. It can never become key or main,
/// so it never takes focus or keystrokes from the call app (anti-goal in the brief).
final class StatusPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Top-right of `visibleFrame`, inset by `inset` (the default position).
    static func defaultOrigin(size: NSSize, visibleFrame: NSRect, inset: CGFloat = 16) -> NSPoint {
        NSPoint(x: visibleFrame.maxX - size.width - inset, y: visibleFrame.maxY - size.height - inset)
    }

    /// `frame` resized to `size` keeping its top edge (compact ↔ expanded grows downwards).
    static func resized(_ frame: NSRect, to size: NSSize) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
    }
}

// MARK: - StatusPanelController

/// Shows, hides and resizes the panel; owned by `AppContainer` (design §7.2).
@MainActor
final class StatusPanelController {
    let panel: StatusPanel
    private let screenFrame: () -> NSRect?

    /// - Parameters:
    ///   - autosaveName: remembers the position across launches; nil in tests.
    ///   - screenFrame: the main screen's visible frame (injected for tests).
    init(content: NSView, size: NSSize, autosaveName: String? = "StatusPanel",
         screenFrame: @escaping () -> NSRect? = { NSScreen.main?.visibleFrame }) {
        self.screenFrame = screenFrame
        panel = StatusPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = content
        let restored = autosaveName.map { panel.setFrameUsingName($0) } ?? false
        if let autosaveName { panel.setFrameAutosaveName(autosaveName) }
        if !restored, let visible = screenFrame() {
            panel.setFrameOrigin(StatusPanel.defaultOrigin(size: size, visibleFrame: visible))
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the panel without activating the app or taking focus.
    func show() { panel.orderFrontRegardless() }

    func hide() { panel.orderOut(nil) }

    /// Compact ↔ expanded, anchored at the top edge.
    func resize(to size: NSSize) {
        panel.setFrame(StatusPanel.resized(panel.frame, to: size), display: true, animate: false)
    }
}
```

- [ ] **Step 4: Run**

Run: `just test-only StatusPanelTests MainWindowOpenerTests TranslationHostWindowTests`
Expected: PASS.

- [ ] **Step 5: Add a DEBUG-only command for the manual focus check**

In `TranslateCallApp.swift`, add it to `.commands`, inside `#if DEBUG`:
- a `CommandMenu("Debug")` with `Button("Toggle Test Status Panel")`;
- the button calls `DebugStatusPanel.toggle()`;
- `DebugStatusPanel` is a `@MainActor enum`, inside `#if DEBUG` in the same file, with:
  - a `static let controller = StatusPanelController(content: NSHostingView(rootView: Text("Status panel test").padding().frame(width: 320, height: 120)), size: NSSize(width: 320, height: 120), autosaveName: nil)`;
  - a `toggle()` written as `if controller.isVisible { controller.hide() } else { controller.show() }` (no void ternary: lint).

Task 17 deletes this command.

- [ ] **Step 6: Manual focus check (blocking for later view work)**

Run: `just build` and open the app.
1. Open Teams (or Zoom) in a meeting or chat, then use Debug › Toggle Test Status Panel.
2. Click into Teams' chat box and type. The keys go to Teams.
3. Drag the panel by its background. Teams stays the frontmost app (its menu bar stays).
4. Put Teams in full screen (⌃⌘F). The panel stays visible over it.
5. Switch Spaces. The panel follows.

If any step fails:
- try `styleMask` with `.utilityWindow` added and `orderFrontRegardless`, as in design §11;
- record the outcome in the task's report.

Do not continue to Task 17 until this passes.

- [ ] **Step 7: Commit**

```bash
git add TranslateCall/Features/StatusPanel/StatusPanel.swift TranslateCall/App/TranslateCallApp.swift \
  TranslateCallTests/StatusPanelTests.swift
git commit -m "feat(ui): non-activating status panel window and controller (M9 UI core T2)"
```

---

### Task 3: `ModelCatalog` (bundled JSON) and `ModelChoice` (sonnet)

**Files:**
- Create: `TranslateCall/Core/Models/ModelCatalog.json`, `TranslateCall/Core/Models/ModelCatalog.swift`, `TranslateCall/Core/Models/ModelChoice.swift`, `TranslateCall/Core/Session/TranscriptEntry.swift`
- Test: `TranslateCallTests/ModelCatalogTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum TranscriptDirection { case outgoing, incoming }`;
  - `nonisolated struct TranscriptEntry`, with `limit = 200`, used in Task 8;
  - `struct ModelCatalog: Decodable, Equatable`, with:
    - `static bundled`, `static builtIn`, `static load(from:)`;
    - `sttEngines(for:)`, `ttsEngines(for:direction:)`;
  - `struct ModelAvailability { parakeetCached, whisperCached, kokoroCached, voiceCloneActive }`;
  - `enum ModelChoice`, with:
    - `automaticKey = "tlk.models.automatic"`, `isAutomatic(in:)`;
    - `stt(for:direction:catalog:availability:) -> STTEngine`;
    - `tts(for:direction:catalog:availability:) -> TTSEngine`.

`ModelCatalog` and `ModelChoice` stay main-actor isolated (the default), because `STTEngine` is.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/ModelCatalogTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

private let en = Locale(identifier: "en-US")
private let es = Locale(identifier: "es-ES")
private let de = Locale(identifier: "de-DE")
private let uk = Locale(identifier: "uk-UA")

@Suite("ModelCatalog (M9 UI core)") @MainActor
struct ModelCatalogTests {

    @Test("the bundled JSON decodes and equals the built-in catalog (REQ-UI-20)")
    func bundledMatchesBuiltIn() throws {
        let url = try #require(Bundle.main.url(forResource: "ModelCatalog", withExtension: "json"))
        #expect(ModelCatalog.load(from: url) == ModelCatalog.builtIn)
        #expect(ModelCatalog.bundled == ModelCatalog.builtIn)
    }

    @Test("a missing or corrupt file falls back to the built-in catalog")
    func corruptFileFallsBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID()).json")
        try Data("{ not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ModelCatalog.load(from: url) == ModelCatalog.builtIn)
        #expect(ModelCatalog.load(from: nil) == ModelCatalog.builtIn)
    }

    @Test("languages without an entry use `default`; unknown and edgeTTS names are dropped")
    func lookupUsesDefault() {
        let catalog = ModelCatalog(version: 1, stt: ["default": ["whisper", "nope", "appleSpeech"]],
                                   ttsOutgoing: ["default": ["edgeTTS", "avSpeech"]], ttsIncoming: [:])
        #expect(catalog.sttEngines(for: de) == [.whisper, .appleSpeech])
        #expect(catalog.ttsEngines(for: de, direction: .outgoing) == [.avSpeech])
        #expect(catalog.ttsEngines(for: de, direction: .incoming).isEmpty)
    }

    @Test("STT: English prefers Parakeet, then Whisper; others Whisper; nothing cached → Apple Speech",
          arguments: [
            (en, ModelAvailability(parakeetCached: true, whisperCached: true), STTEngine.parakeet),
            (en, ModelAvailability(whisperCached: true), .whisper),
            (es, ModelAvailability(parakeetCached: true, whisperCached: true), .whisper),
            (de, ModelAvailability(parakeetCached: true), .appleSpeech),
            (uk, ModelAvailability(), .appleSpeech),
          ])
    func sttResolution(locale: Locale, availability: ModelAvailability, expected: STTEngine) {
        #expect(ModelChoice.stt(for: locale, direction: .outgoing, catalog: .builtIn, availability: availability) == expected)
    }

    @Test("STT incoming never uses Parakeet (one shared ASR model, outgoing only as today)")
    func parakeetOutgoingOnly() {
        let all = ModelAvailability(parakeetCached: true, whisperCached: true)
        #expect(ModelChoice.stt(for: en, direction: .incoming, catalog: .builtIn, availability: all) == .whisper)
        let parakeet = ModelAvailability(parakeetCached: true)
        #expect(ModelChoice.stt(for: en, direction: .incoming, catalog: .builtIn, availability: parakeet) == .appleSpeech)
    }

    @Test("TTS outgoing: the voice clone when active, else Kokoro for English, else the system voice",
          arguments: [
            (en, ModelAvailability(kokoroCached: true, voiceCloneActive: true), TTSEngine.voiceClone),
            (en, ModelAvailability(kokoroCached: true), .kokoro),
            (es, ModelAvailability(kokoroCached: true, voiceCloneActive: true), .voiceClone),
            (es, ModelAvailability(kokoroCached: true), .avSpeech),
            (de, ModelAvailability(), .avSpeech),
          ])
    func ttsOutgoingResolution(locale: Locale, availability: ModelAvailability, expected: TTSEngine) {
        #expect(ModelChoice.tts(for: locale, direction: .outgoing, catalog: .builtIn,
                                availability: availability) == expected)
    }

    @Test("TTS incoming: Kokoro for English only while the voice clone is not active (MLX exclusivity, §3.3)")
    func ttsIncomingMLXExclusivity() {
        let kokoro = ModelAvailability(kokoroCached: true)
        let both = ModelAvailability(kokoroCached: true, voiceCloneActive: true)
        #expect(ModelChoice.tts(for: en, direction: .incoming, catalog: .builtIn, availability: kokoro) == .kokoro)
        #expect(ModelChoice.tts(for: en, direction: .incoming, catalog: .builtIn, availability: both) == .avSpeech)
        #expect(ModelChoice.tts(for: es, direction: .incoming, catalog: .builtIn, availability: kokoro) == .avSpeech)
    }

    @Test("automatic choice never picks Edge, even when it is the only listed engine (REQ-UI-22)")
    func neverEdge() {
        let catalog = ModelCatalog(version: 1, stt: [:], ttsOutgoing: ["default": ["edgeTTS"]],
                                   ttsIncoming: ["default": ["edgeTTS"]])
        let all = ModelAvailability(parakeetCached: true, whisperCached: true, kokoroCached: true, voiceCloneActive: true)
        #expect(ModelChoice.tts(for: uk, direction: .outgoing, catalog: catalog, availability: all) == .avSpeech)
        #expect(ModelChoice.tts(for: uk, direction: .incoming, catalog: catalog, availability: all) == .avSpeech)
        #expect(ModelChoice.stt(for: uk, direction: .outgoing, catalog: catalog, availability: all) == .appleSpeech)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `just test-only ModelCatalogTests`
Expected: FAIL (types undefined).

- [ ] **Step 3: Implement**

`TranslateCall/Core/Models/ModelCatalog.json`:
```json
{
  "version": 1,
  "stt": {
    "en": ["parakeet", "whisper", "appleSpeech"],
    "default": ["whisper", "appleSpeech"]
  },
  "ttsOutgoing": {
    "en": ["voiceClone", "kokoro", "avSpeech"],
    "default": ["voiceClone", "avSpeech"]
  },
  "ttsIncoming": {
    "en": ["kokoro", "avSpeech"],
    "default": ["avSpeech"]
  }
}
```

`TranslateCall/Core/Models/ModelCatalog.swift`:
```swift
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "ModelCatalog")

// MARK: - ModelCatalog

/// Ordered engine preferences per language and stage (M9 UI core REQ-UI-20, design §3.1).
///
/// Loaded from the bundled `ModelCatalog.json`; the benchmark can rewrite that file without code
/// changes (D-2). Keys are BCP-47 language codes (`en`, `es`, …) plus `default`. Engine names are
/// the `STTEngine` / `TTSEngine` raw values; unknown names are ignored. Edge TTS is never listed.
struct ModelCatalog: Decodable, Equatable {
    let version: Int
    let stt: [String: [String]]
    let ttsOutgoing: [String: [String]]
    let ttsIncoming: [String: [String]]

    /// The bundled catalog; the built-in fallback when the file is missing or corrupt.
    static let bundled: ModelCatalog = load(from: Bundle.main.url(forResource: "ModelCatalog", withExtension: "json"))

    /// Same values as `ModelCatalog.json` (version 1).
    static let builtIn = ModelCatalog(
        version: 1,
        stt: ["en": ["parakeet", "whisper", "appleSpeech"], "default": ["whisper", "appleSpeech"]],
        ttsOutgoing: ["en": ["voiceClone", "kokoro", "avSpeech"], "default": ["voiceClone", "avSpeech"]],
        ttsIncoming: ["en": ["kokoro", "avSpeech"], "default": ["avSpeech"]]
    )

    /// Decodes the catalog at `url`; any failure logs and returns `builtIn`.
    static func load(from url: URL?) -> ModelCatalog {
        guard let url, let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else {
            logger.error("ModelCatalog.json missing or invalid; using the built-in catalog")
            return builtIn
        }
        return catalog
    }

    func sttEngines(for locale: Locale) -> [STTEngine] {
        names(in: stt, for: locale).compactMap(STTEngine.init(rawValue:))
    }

    func ttsEngines(for locale: Locale, direction: TranscriptDirection) -> [TTSEngine] {
        let table = direction == .outgoing ? ttsOutgoing : ttsIncoming
        return names(in: table, for: locale).compactMap(TTSEngine.init(rawValue:)).filter { $0 != .edgeTTS }
    }

    private func names(in table: [String: [String]], for locale: Locale) -> [String] {
        let code = locale.language.languageCode?.identifier ?? ""
        return table[code] ?? table["default"] ?? []
    }
}
```

`TranslateCall/Core/Models/ModelChoice.swift`:
```swift
import Foundation

// MARK: - ModelAvailability

/// What is usable on this Mac right now (D-6: "ready" = downloaded on disk; the voice clone also
/// needs to be enabled, loaded and have an active profile — `TTSEngineSelector.voiceCloningActive`).
struct ModelAvailability: Equatable {
    var parakeetCached = false
    var whisperCached = false
    var kokoroCached = false
    var voiceCloneActive = false
}

// MARK: - ModelChoice

/// Automatic engine choice (REQ-UI-21/22/24, design §3.2): the first catalog engine that supports
/// the locale and is ready; otherwise Apple Speech / the system voice. A pure function.
enum ModelChoice {
    /// Shared by both selectors: automatic (default `true`) or the engines picked by hand (REQ-UI-23).
    static let automaticKey = "tlk.models.automatic"

    static func isAutomatic(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: automaticKey) as? Bool ?? true
    }

    /// Parakeet serves the outgoing direction only, as today (one shared ASR model).
    static func stt(for locale: Locale, direction: TranscriptDirection,
                    catalog: ModelCatalog, availability: ModelAvailability) -> STTEngine {
        catalog.sttEngines(for: locale).first { engine in
            engine.supports(locale: locale) && isReady(engine, availability)
                && !(engine == .parakeet && direction == .incoming)
        } ?? .appleSpeech
    }

    static func tts(for locale: Locale, direction: TranscriptDirection,
                    catalog: ModelCatalog, availability: ModelAvailability) -> TTSEngine {
        catalog.ttsEngines(for: locale, direction: direction).first { engine in
            engine.supports(locale: locale) && isReady(engine, availability)
        } ?? .avSpeech
    }

    private static func isReady(_ engine: STTEngine, _ availability: ModelAvailability) -> Bool {
        switch engine {
        case .appleSpeech: true
        case .parakeet: availability.parakeetCached
        case .whisper: availability.whisperCached
        }
    }

    /// Kokoro is never chosen while the voice clone is active: only one MLX TTS model at a time (§3.3).
    private static func isReady(_ engine: TTSEngine, _ availability: ModelAvailability) -> Bool {
        switch engine {
        case .avSpeech: true
        case .kokoro: availability.kokoroCached && !availability.voiceCloneActive
        case .voiceClone: availability.voiceCloneActive
        case .edgeTTS: false
        }
    }
}
```

`TranslateCall/Core/Session/TranscriptEntry.swift`:
```swift
import Foundation

/// Which way a sentence travels: `outgoing` = the user → the call, `incoming` = the call → the user.
nonisolated enum TranscriptDirection: Sendable, Equatable {
    case outgoing, incoming
}

/// One sentence of the session transcript (REQ-UI-44, design §4.1).
nonisolated struct TranscriptEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let direction: TranscriptDirection
    let original: String
    /// nil while translating, or when the sentence was skipped.
    var translation: String?
    /// Translation failed: shown dimmed with a note.
    var skipped = false
    let date: Date
    /// From `LatencyProvider` when available.
    var latency: Duration?

    init(direction: TranscriptDirection, original: String, date: Date = .now) {
        id = UUID()
        self.direction = direction
        self.original = original
        self.date = date
    }

    /// Kept at most (REQ-UI-44).
    static let limit = 200
}
```

- [ ] **Step 4: Run**

Run: `just test-only ModelCatalogTests`
Expected: PASS. `bundledMatchesBuiltIn` also proves that the JSON is in the app bundle.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Models TranslateCall/Core/Session/TranscriptEntry.swift TranslateCallTests/ModelCatalogTests.swift
git commit -m "feat(models): bundled model catalog and automatic engine choice (M9 UI core T3)"
```

---

### Task 4: On-disk model checks (`ModelCache`) and the Qwen cache fix (sonnet)

**Files:**
- Create: `TranslateCall/Core/Models/ModelCache.swift`
- Modify: `TranslateCall/Core/VoiceCloning/QwenCloneModelManager.swift` (`isModelCached`), `TranslateCallTests/QwenCloneModelManagerTests.swift` (drop the `await`)
- Test: `TranslateCallTests/ModelCacheTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum ModelCache`, with:
    - `allExist(_:in:)`, `hasMLXWeights(in:)`;
    - `whisperDirectory(for:home:)`, `kokoroDirectory(home:)`, `mlxAudioDirectory(repo:home:)`, `homeDirectory`;
    - `isParakeetCached()`, `isWhisperCached()`, `isKokoroCached()`;
  - `nonisolated struct ModelCacheProbe { parakeet, whisper, kokoro: @Sendable () -> Bool; static live; static none }`;
  - `QwenCloneModelManager.isModelCached(home:)`, now `nonisolated`.

The folders come from the packages:
- **Parakeet:** FluidAudio's `AsrModels.defaultCacheDirectory`/`modelsExist(at:version:)`.
- **Whisper:** WhisperKit's default download base, `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<size>`, which must contain `MelSpectrogram.mlmodelc`, `AudioEncoder.mlmodelc` and `TextDecoder.mlmodelc`.
- **Kokoro:** FluidAudio TTS on macOS, `~/.cache/fluidaudio/Models/kokoro`, which must contain `kokoro_21_5s.mlmodelc` and `kokoro_21_15s.mlmodelc`.
- **Qwen:** mlx-audio, `~/.cache/huggingface/hub/mlx-audio/<owner>_<name>` (P8).

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/ModelCacheTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

/// A throwaway home folder; removed when the test ends.
private final class TempHome {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID())", isDirectory: true)
    deinit { try? FileManager.default.removeItem(at: url) }

    func make(_ names: [String], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(name),
                                                        withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: folder.appendingPathComponent(name))
            }
        }
    }
}

@Suite("ModelCache (M9 UI core D-6)")
struct ModelCacheTests {

    @Test("Whisper: complete with the three CoreML bundles, not with two")
    func whisperFolder() throws {
        let home = TempHome()
        let folder = ModelCache.whisperDirectory(for: .base, home: home.url)
        #expect(folder.path.hasSuffix("Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-base"))
        try home.make(Array(ModelCache.whisperRequired.prefix(2)), in: folder)
        #expect(!ModelCache.allExist(ModelCache.whisperRequired, in: folder))
        try home.make(ModelCache.whisperRequired, in: folder)
        #expect(ModelCache.allExist(ModelCache.whisperRequired, in: folder))
    }

    @Test("Kokoro: both variants are required")
    func kokoroFolder() throws {
        let home = TempHome()
        let folder = ModelCache.kokoroDirectory(home: home.url)
        #expect(folder.path.hasSuffix(".cache/fluidaudio/Models/kokoro"))
        try home.make(["kokoro_21_5s.mlmodelc"], in: folder)
        #expect(!ModelCache.allExist(ModelCache.kokoroRequired, in: folder))
        try home.make(["kokoro_21_15s.mlmodelc"], in: folder)
        #expect(ModelCache.allExist(ModelCache.kokoroRequired, in: folder))
    }

    @Test("mlx-audio: needs config.json and a non-empty .safetensors")
    func mlxWeights() throws {
        let home = TempHome()
        let folder = ModelCache.mlxAudioDirectory(repo: "owner/model", home: home.url)
        #expect(folder.lastPathComponent == "owner_model")
        #expect(!ModelCache.hasMLXWeights(in: folder))
        try home.make(["config.json"], in: folder)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("model.safetensors").path, contents: Data())
        #expect(!ModelCache.hasMLXWeights(in: folder), "a zero-byte weights file is a partial download")
        try home.make(["model.safetensors"], in: folder)
        #expect(ModelCache.hasMLXWeights(in: folder))
    }

    @Test("Qwen: the old `models--…` hub folder alone is not a cached model")
    func qwenIgnoresHubFolder() async throws {
        let home = TempHome()
        let config = QwenCloneConfiguration(modelRepo: "owner/model")
        let manager = QwenCloneModelManager(config: config, modelLoader: { _ in MockQwenCloneInferrer() })
        try home.make(["blobs.txt"], in: home.url.appendingPathComponent(".cache/huggingface/hub/models--owner--model"))
        #expect(!manager.isModelCached(home: home.url))
        try home.make(["config.json", "model.safetensors"],
                      in: ModelCache.mlxAudioDirectory(repo: "owner/model", home: home.url))
        #expect(manager.isModelCached(home: home.url))
    }
}
```

In `TranslateCallTests/QwenCloneModelManagerTests.swift`, `isModelCachedReturnsFalseForFreshInstall`: `let cached = manager.isModelCached()` (no `await`: the method becomes nonisolated).

- [ ] **Step 2: Run, expect failure**

Run: `just test-only ModelCacheTests QwenCloneModelManagerTests`
Expected: FAIL (`ModelCache` undefined).

- [ ] **Step 3: Implement**

`TranslateCall/Core/Models/ModelCache.swift`:
```swift
import FluidAudio
import Foundation

// MARK: - ModelCache

/// Cheap on-disk checks: is a model downloaded? No loading, no network (D-6, design §3.3).
/// Folders mirror where each package stores its model (FluidAudio, WhisperKit, mlx-audio-swift).
nonisolated enum ModelCache {

    // MARK: Generic checks

    /// Every name exists in `directory` (file or folder, e.g. `Encoder.mlmodelc`).
    static func allExist(_ names: [String], in directory: URL) -> Bool {
        names.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// An mlx-audio model folder is usable: `config.json` plus at least one non-empty `.safetensors`
    /// (the rule `ModelUtils.resolveOrDownloadModel` applies before it trusts a cached copy).
    static func hasMLXWeights(in directory: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.appendingPathComponent("config.json").path),
              let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return false }
        return files.contains { file in
            file.pathExtension == "safetensors"
                && ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
    }

    // MARK: Folders and required files

    static let whisperRequired = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
    static let kokoroRequired = ["kokoro_21_5s.mlmodelc", "kokoro_21_15s.mlmodelc"]

    /// WhisperKit's default download base: `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<size>`.
    static func whisperDirectory(for size: WhisperModelSize, home: URL = homeDirectory) -> URL {
        home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(size.whisperKitName)
    }

    /// FluidAudio TTS on macOS: `~/.cache/fluidaudio/Models/kokoro`.
    static func kokoroDirectory(home: URL = homeDirectory) -> URL {
        home.appendingPathComponent(".cache/fluidaudio/Models/kokoro")
    }

    /// mlx-audio's working copy: `~/.cache/huggingface/hub/mlx-audio/<owner>_<name>`.
    static func mlxAudioDirectory(repo: String, home: URL = homeDirectory) -> URL {
        home.appendingPathComponent(".cache/huggingface/hub/mlx-audio")
            .appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_"))
    }

    static var homeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Per model (production paths)

    static func isParakeetCached(_ config: ParakeetConfiguration = .default) -> Bool {
        let version = config.modelVersion
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// The size the app loads (`WhisperConfiguration.default`; the size is not persisted).
    static func isWhisperCached(_ config: WhisperConfiguration = .default) -> Bool {
        allExist(whisperRequired, in: whisperDirectory(for: config.modelSize))
    }

    static func isKokoroCached() -> Bool {
        allExist(kokoroRequired, in: kokoroDirectory())
    }
}

// MARK: - ModelCacheProbe

/// Injectable view of `ModelCache` for the selectors and the preloader (tests pass fixed answers).
nonisolated struct ModelCacheProbe: Sendable {
    var parakeet: @Sendable () -> Bool
    var whisper: @Sendable () -> Bool
    var kokoro: @Sendable () -> Bool

    static let live = ModelCacheProbe(
        parakeet: { ModelCache.isParakeetCached() },
        whisper: { ModelCache.isWhisperCached() },
        kokoro: { ModelCache.isKokoroCached() }
    )
    static let none = ModelCacheProbe(parakeet: { false }, whisper: { false }, kokoro: { false })
}
```

In `QwenCloneModelManager.swift`, replace `isModelCached()`:
```swift
    /// The model is downloaded: mlx-audio's working copy holds `config.json` and non-empty weights
    /// (M9 UI core D-6). The `models--…` hub folder alone does not prove that.
    nonisolated func isModelCached(home: URL = ModelCache.homeDirectory) -> Bool {
        ModelCache.hasMLXWeights(in: ModelCache.mlxAudioDirectory(repo: config.modelRepo, home: home))
    }
```

- [ ] **Step 4: Run**

Run: `just test-only ModelCacheTests QwenCloneModelManagerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Models/ModelCache.swift TranslateCall/Core/VoiceCloning/QwenCloneModelManager.swift \
  TranslateCallTests/ModelCacheTests.swift TranslateCallTests/QwenCloneModelManagerTests.swift
git commit -m "feat(models): on-disk model checks; Qwen cache check looks at mlx-audio's copy (M9 UI core T4)"
```

---

### Task 5: Automatic mode in `STTEngineSelector` and `TTSEngineSelector` (sonnet)

**Files:**
- Create: `TranslateCall/Core/Models/ModelChoice+Selectors.swift`
- Modify: `TranslateCall/Core/STT/STTEngineSelector.swift`, `TranslateCall/Core/TTS/TTSEngineSelector.swift`
- Modify (pin manual mode): `TranslateCallTests/STTEngineSelectorTests.swift`, `TranslateCallTests/TTSEngineSelectorTests.swift`, `TranslateCallTests/TTSEngineSelectorVoiceCloneTests.swift`, `TranslateCallTests/EdgeTTSTests.swift`, `TranslateCallTests/WhisperSTTTests.swift`
- Test: `TranslateCallTests/ModelChoiceSelectorTests.swift`

**Interfaces:**
- Consumes: Task 3 (`ModelChoice`, `ModelCatalog`), Task 4 (`ModelCacheProbe`).
- Produces, on both selectors:
  - `isAutomatic: Bool`, `setAutomatic(_:)`, `availability: ModelAvailability`, `var catalog`, `var cacheProbe`;
  - `setPreferredEngine` now also switches to manual.

  `STTEngineSelector.automaticService(for:direction:)` and `TTSEngineSelector.automaticPrimary(for:direction:)` are used internally. `TTSEngineSelector.systemOrEdgePrimary(for:)` becomes internal (it was private).

- [ ] **Step 1: Pin manual mode in the existing suites**

In each of the five suites' fresh-defaults helper, after the suite is created or cleared, add:
```swift
        suite.set(false, forKey: ModelChoice.automaticKey)   // these tests cover manual mode (M9 UI core)
```
Use the helper's own variable name (`suite` or `defaults`). In `TTSEngineSelectorVoiceCloneTests.makeSelector()`, set it on the `defaults` it creates.

- [ ] **Step 2: Write the failing tests**

`TranslateCallTests/ModelChoiceSelectorTests.swift`:
```swift
import CoreAudio
import Foundation
import Testing
@testable import TranslateCall

/// Records which STT factory a selector used.
@MainActor
private final class STTPicks {
    var used: [String] = []
    func factory(_ name: String) -> (Locale) -> any SpeechRecognizerService {
        { [weak self] locale in self?.used.append(name); return MockSpeechRecognizerService(locale: locale) }
    }
}

@MainActor
private func freshDefaults() -> UserDefaults {
    let name = "ModelChoiceSelectorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
private func makeSTT(_ defaults: UserDefaults, _ picks: STTPicks, probe: ModelCacheProbe) -> STTEngineSelector {
    let selector = STTEngineSelector(defaults: defaults, appleSpeechFactory: picks.factory("apple"),
                                     parakeetFactory: picks.factory("parakeet"), whisperFactory: picks.factory("whisper"))
    selector.catalog = .builtIn
    selector.cacheProbe = probe
    return selector
}

@MainActor
private func makeTTS(_ defaults: UserDefaults, probe: ModelCacheProbe) -> TTSEngineSelector {
    let selector = TTSEngineSelector(defaults: defaults)
    selector.catalog = .builtIn
    selector.cacheProbe = probe
    selector.hasSystemVoice = { _ in true }
    selector.outputFactory = { _ in FakeOutput() }
    selector.avSpeechFactory = { FakeSynthesizer(engine: .avSpeech) }
    selector.kokoroFactory = { _ in FakeSynthesizer(engine: .kokoro) }
    selector.voiceCloneFactory = { _, _ in FakeSynthesizer(engine: .voiceClone) }
    selector.edgeFactory = { FakeSynthesizer(engine: .edgeTTS) }
    return selector
}

private let cachedAll = ModelCacheProbe(parakeet: { true }, whisper: { true }, kokoro: { true })

@Suite("Selectors in automatic mode (M9 UI core REQ-UI-21…23)") @MainActor
struct ModelChoiceSelectorTests {

    @Test("automatic is the default, for new and existing users")
    func automaticByDefault() {
        let defaults = freshDefaults()
        defaults.set("parakeet", forKey: "tlk.stt.engine")   // an existing manual choice
        let stt = makeSTT(defaults, STTPicks(), probe: .none)
        #expect(stt.isAutomatic)
        #expect(makeTTS(defaults, probe: .none).isAutomatic)
    }

    @Test("automatic STT uses the catalog with what is on disk, per direction")
    func automaticSTT() {
        let picks = STTPicks()
        let stt = makeSTT(freshDefaults(), picks, probe: cachedAll)
        _ = stt.makeOutgoingService(for: Locale(identifier: "en-US"))
        _ = stt.makeIncomingService(for: Locale(identifier: "en-US"))
        _ = stt.makeOutgoingService(for: Locale(identifier: "es-ES"))
        #expect(picks.used == ["parakeet", "whisper", "whisper"])
    }

    @Test("nothing on disk → Apple Speech, even if Parakeet was chosen by hand before")
    func automaticFallsBackToApple() {
        let picks = STTPicks()
        let defaults = freshDefaults()
        defaults.set("parakeet", forKey: "tlk.stt.engine")
        let stt = makeSTT(defaults, picks, probe: .none)
        _ = stt.makeOutgoingService(for: Locale(identifier: "en-US"))
        #expect(picks.used == ["apple"])
    }

    @Test("picking an engine by hand switches both selectors to manual; setAutomatic(true) switches back")
    func manualAndBack() {
        let defaults = freshDefaults()
        let picks = STTPicks()
        let stt = makeSTT(defaults, picks, probe: cachedAll)
        let tts = makeTTS(defaults, probe: cachedAll)

        stt.setPreferredEngine(.appleSpeech)
        #expect(!stt.isAutomatic && !tts.isAutomatic)
        _ = stt.makeOutgoingService(for: Locale(identifier: "en-US"))
        #expect(picks.used == ["apple"], "manual = today's behaviour")

        tts.setAutomatic(true)
        #expect(stt.isAutomatic)
        #expect(defaults.bool(forKey: ModelChoice.automaticKey))
    }

    @Test("automatic TTS: Kokoro for English when cached, the system voice otherwise")
    func automaticTTS() throws {
        let tts = makeTTS(freshDefaults(), probe: cachedAll)
        let english = try tts.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        let spanish = try tts.makeOutgoingService(for: Locale(identifier: "es-ES"), deviceID: nil)
        let incomingEnglish = try tts.makeIncomingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(english.primaryEngine == .kokoro)
        #expect(spanish.primaryEngine == .avSpeech)
        #expect(incomingEnglish.primaryEngine == .kokoro)
    }

    @Test("automatic TTS never picks Edge without prior consent (REQ-UI-22)")
    func automaticNeverEdgeWithoutConsent() throws {
        let tts = makeTTS(freshDefaults(), probe: .none)
        tts.hasSystemVoice = { _ in false }
        guard !EdgeTTSConsentManager.consentGiven else { return }   // machine-wide consent: nothing to check
        let service = try tts.makeOutgoingService(for: Locale(identifier: "uk-UA"), deviceID: nil)
        #expect(service.primaryEngine == .avSpeech)
    }
}
```

- [ ] **Step 3: Run, expect failure**

Run: `just test-only ModelChoiceSelectorTests`
Expected: FAIL (`catalog`, `cacheProbe`, `isAutomatic` undefined).

- [ ] **Step 4: Implement**

`STTEngineSelector.swift`:
- `defaults`, `appleSpeechFactory`, `parakeetFactory` and `whisperFactory` lose `private`; they are read by the extension;
- add the stored properties:
  ```swift
      /// Automatic choice inputs (M9 UI core §3.3); injectable for tests.
      var catalog: ModelCatalog = .bundled
      var cacheProbe: ModelCacheProbe = .live
  ```
- in `makeOutgoingService`, after `currentSourceLocale = locale`, add `if isAutomatic { return automaticService(for: locale, direction: .outgoing) }`;
- `makeIncomingService` starts with `if isAutomatic { return automaticService(for: locale, direction: .incoming) }`;
- `setPreferredEngine` calls `setAutomatic(false)` right after persisting.

`TTSEngineSelector.swift`:
- `defaults` loses `private`;
- `profileStore` becomes `private(set)`;
- add the same two stored properties;
- `systemOrEdgePrimary(for:)` loses `private`;
- `outgoingPrimary`/`incomingPrimary` start with `if isAutomatic { return automaticPrimary(for: locale, direction: .outgoing / .incoming) }`;
- `setPreferredEngine` calls `setAutomatic(false)`.

Manual mode is today's code path, unchanged.

`TranslateCall/Core/Models/ModelChoice+Selectors.swift`:
```swift
import Combine
import Foundation

// MARK: - Automatic mode in the selectors (M9 UI core REQ-UI-21…23, design §3.3)

extension STTEngineSelector {
    /// Automatic (catalog) or manual (`preferredEngine`, today's behaviour). Shared with the TTS selector.
    var isAutomatic: Bool { ModelChoice.isAutomatic(in: defaults) }

    /// `true` = back to automatic ("Automatic (recommended)"); `setPreferredEngine` sets `false`.
    func setAutomatic(_ automatic: Bool) {
        objectWillChange.send()
        defaults.set(automatic, forKey: ModelChoice.automaticKey)
    }

    var availability: ModelAvailability {
        ModelAvailability(parakeetCached: cacheProbe.parakeet(), whisperCached: cacheProbe.whisper())
    }

    func automaticService(for locale: Locale, direction: TranscriptDirection) -> any SpeechRecognizerService {
        switch ModelChoice.stt(for: locale, direction: direction, catalog: catalog, availability: availability) {
        case .parakeet: parakeetFactory(locale)
        case .whisper: whisperFactory(locale)
        case .appleSpeech: appleSpeechFactory(locale)
        }
    }
}

extension TTSEngineSelector {
    var isAutomatic: Bool { ModelChoice.isAutomatic(in: defaults) }

    func setAutomatic(_ automatic: Bool) {
        objectWillChange.send()
        defaults.set(automatic, forKey: ModelChoice.automaticKey)
    }

    var availability: ModelAvailability {
        ModelAvailability(kokoroCached: cacheProbe.kokoro(), voiceCloneActive: voiceCloningActive)
    }

    /// The system voice path keeps today's Edge fallback, which needs prior consent (REQ-UI-22).
    func automaticPrimary(for locale: Locale, direction: TranscriptDirection) -> any UtteranceSynthesizer {
        switch ModelChoice.tts(for: locale, direction: direction, catalog: catalog, availability: availability) {
        case .voiceClone:
            if let profileId = activeVoiceProfileId, let store = profileStore {
                return voiceCloneFactory(profileId, store)
            }
            return systemOrEdgePrimary(for: locale)
        case .kokoro:
            let voiceID = defaults.string(forKey: KokoroConfiguration.voiceDefaultsKey) ?? ""
            return kokoroFactory(KokoroConfiguration(voiceIdentifier: voiceID))
        case .avSpeech, .edgeTTS:
            return systemOrEdgePrimary(for: locale)
        }
    }
}
```

- [ ] **Step 5: Run**

Run: `just test-only ModelChoiceSelectorTests ModelCatalogTests STTEngineSelectorTests TTSEngineSelectorTests TTSEngineSelectorVoiceCloneTests EdgeTTSTests WhisperSTTTests`
Expected: PASS.

- [ ] **Step 6: Lint and commit**

Run: `just lint`. Expected: no output.
```bash
git add TranslateCall/Core/Models/ModelChoice+Selectors.swift TranslateCall/Core/STT/STTEngineSelector.swift \
  TranslateCall/Core/TTS/TTSEngineSelector.swift TranslateCallTests/ModelChoiceSelectorTests.swift \
  TranslateCallTests/STTEngineSelectorTests.swift TranslateCallTests/TTSEngineSelectorTests.swift \
  TranslateCallTests/TTSEngineSelectorVoiceCloneTests.swift TranslateCallTests/EdgeTTSTests.swift TranslateCallTests/WhisperSTTTests.swift
git commit -m "feat(models): selectors pick engines from the catalog in automatic mode (M9 UI core T5)"
```

---

### Task 6: `ModelPreloader` and `UIServices` in `AppContainer` (opus)

**Files:**
- Create: `TranslateCall/Core/Models/ModelPreloader.swift`
- Modify: `TranslateCall/App/AppContainer.swift`
- Test: `TranslateCallTests/ModelPreloaderTests.swift`

**Interfaces:**
- Consumes: Task 5 (selectors' `isAutomatic`, `availability`, `catalog`); `LanguagePairManager.$sourceLanguage`/`$targetLanguage`.
- Produces:
  - `enum PreloadModel { parakeet, whisper, kokoro }`;
  - `struct ModelLoaders { load, unload; static live }`;
  - `@MainActor final class ModelPreloader`:
    - `init(stt:tts:languagePairManager:loaders:isSessionActive:)`;
    - `start()`, `wantedModels()`, `preload() async`, `loaded`;
  - `@MainActor struct UIServices` (`AppContainer.uiServices`). Tasks 11 and 13 add fields to it.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/ModelPreloaderTests.swift`:
```swift
import Foundation
import Synchronization
import Testing
@testable import TranslateCall

/// Records load/unload calls in order.
private final class LoaderLog: Sendable {
    private let calls = Mutex<[String]>([])
    var entries: [String] { calls.withLock { $0 } }
    var loaders: ModelLoaders {
        ModelLoaders(load: { model in self.calls.withLock { $0.append("load \(model)") } },
                     unload: { model in self.calls.withLock { $0.append("unload \(model)") } })
    }
}

@MainActor
private struct Harness {
    let defaults: UserDefaults
    let stt: STTEngineSelector
    let tts: TTSEngineSelector
    let pair: LanguagePairManager
    let log = LoaderLog()
    var sessionActive = false

    init(source: String, target: String, probe: ModelCacheProbe) {
        let name = "ModelPreloaderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(source, forKey: "tlk.source.language")
        defaults.set(target, forKey: "tlk.target.language")
        stt = STTEngineSelector(defaults: defaults, appleSpeechFactory: { MockSpeechRecognizerService(locale: $0) },
                                parakeetFactory: { MockSpeechRecognizerService(locale: $0) },
                                whisperFactory: { MockSpeechRecognizerService(locale: $0) })
        tts = TTSEngineSelector(defaults: defaults)
        stt.catalog = .builtIn
        stt.cacheProbe = probe
        tts.catalog = .builtIn
        tts.cacheProbe = probe
        pair = LanguagePairManager(defaults: defaults, languageLoader: { [] })
    }

    func preloader(sessionActive: @escaping () -> Bool = { false }) -> ModelPreloader {
        ModelPreloader(stt: stt, tts: tts, languagePairManager: pair, loaders: log.loaders, isSessionActive: sessionActive)
    }
}

private let cachedAll = ModelCacheProbe(parakeet: { true }, whisper: { true }, kokoro: { true })

@Suite("ModelPreloader (M9 UI core REQ-UI-21a)", .serialized) @MainActor
struct ModelPreloaderTests {

    @Test("ES ↔ EN with everything cached: Whisper (ES out), Whisper (EN in)… plus Kokoro for English")
    func wantedForSpanishEnglish() {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        #expect(harness.preloader().wantedModels() == [.whisper, .kokoro])
    }

    @Test("EN → ES: Parakeet for my English, Whisper for their Spanish")
    func wantedForEnglishSpanish() {
        let harness = Harness(source: "en", target: "es", probe: cachedAll)
        #expect(harness.preloader().wantedModels() == [.parakeet, .whisper, .kokoro])
    }

    @Test("nothing on disk → nothing to preload (never downloads)")
    func nothingCached() async {
        let harness = Harness(source: "en", target: "es", probe: .none)
        let preloader = harness.preloader()
        await preloader.preload()
        #expect(harness.log.entries.isEmpty)
    }

    @Test("no Kokoro while the voice clone is enabled (one MLX TTS model at a time)")
    func noKokoroWithVoiceClone() {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        harness.tts.voiceCloningEnabled = true
        #expect(!harness.preloader().wantedModels().contains(.kokoro))
    }

    @Test("a pair change unloads what the new pair no longer uses and loads the new picks")
    func pairChangeSwapsModels() async {
        let harness = Harness(source: "en", target: "es", probe: cachedAll)
        let preloader = harness.preloader()
        await preloader.preload()
        await harness.pair.setSourceLanguage(Locale.Language(identifier: "de"))
        await harness.pair.setTargetLanguage(Locale.Language(identifier: "es"))
        await preloader.preload()
        #expect(harness.log.entries.contains("unload parakeet"))
        #expect(harness.log.entries.contains("unload kokoro"))
        #expect(harness.log.entries.filter { $0 == "load whisper" }.count == 1, "already loaded: not reloaded")
        #expect(preloader.loaded == [.whisper])
    }

    @Test("manual mode preloads nothing; a session in progress blocks any change")
    func manualAndSession() async {
        let harness = Harness(source: "en", target: "es", probe: cachedAll)
        harness.stt.setAutomatic(false)
        #expect(harness.preloader().wantedModels().isEmpty)

        harness.stt.setAutomatic(true)
        let busy = harness.preloader(sessionActive: { true })
        await busy.preload()
        #expect(harness.log.entries.isEmpty)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `just test-only ModelPreloaderTests`
Expected: FAIL (types undefined).

- [ ] **Step 3: Implement** `TranslateCall/Core/Models/ModelPreloader.swift`:
```swift
import Combine
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "ModelPreloader")

/// A model the preloader can load ahead of Start.
nonisolated enum PreloadModel: Hashable, Sendable {
    case parakeet, whisper, kokoro
}

/// Loads and unloads one model; `live` uses the shared managers. Loading never downloads in
/// practice: the preloader only asks for models the cache probe found on disk.
nonisolated struct ModelLoaders: Sendable {
    var load: @Sendable (PreloadModel) async -> Void
    var unload: @Sendable (PreloadModel) async -> Void

    static let live = ModelLoaders(
        load: { model in
            do {
                switch model {
                case .parakeet: _ = try await ParakeetModelManager.shared.ensureReady()
                case .whisper: try await WhisperModelManager.shared.loadIfNeeded()
                case .kokoro: _ = try await KokoroModelManager.shared.ensureReady()
                }
            } catch {
                logger.info("Preload of \(String(describing: model)) skipped: \(error.localizedDescription)")
            }
        },
        unload: { model in
            switch model {
            case .parakeet: await ParakeetModelManager.shared.unload()
            case .whisper: await WhisperModelManager.shared.unloadModel()
            case .kokoro: await KokoroModelManager.shared.unload()
            }
        }
    )
}

// MARK: - ModelPreloader

/// Preloads the cached models the catalog picks for the current pair, at launch and on every
/// pair change, so Start is fast (M9 UI core D-6, REQ-UI-21a, design §3.3). Never downloads,
/// never runs during a session, and never loads Kokoro while the voice clone is enabled
/// (one MLX TTS model at a time). `AppContainer` does not start it in the test host.
@MainActor
final class ModelPreloader {
    private let stt: STTEngineSelector
    private let tts: TTSEngineSelector
    private let languagePairManager: LanguagePairManager
    private let loaders: ModelLoaders
    private let isSessionActive: () -> Bool
    private(set) var loaded: Set<PreloadModel> = []
    private var pending: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(stt: STTEngineSelector, tts: TTSEngineSelector, languagePairManager: LanguagePairManager,
         loaders: ModelLoaders = .live, isSessionActive: @escaping () -> Bool) {
        self.stt = stt
        self.tts = tts
        self.languagePairManager = languagePairManager
        self.loaders = loaders
        self.isSessionActive = isSessionActive
    }

    /// Preloads now and after every language change.
    func start() {
        languagePairManager.$sourceLanguage.combineLatest(languagePairManager.$targetLanguage)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &cancellables)
    }

    /// The models the next session would load, given the pair and what is on disk.
    func wantedModels() -> Set<PreloadModel> {
        guard stt.isAutomatic else { return [] }
        let source = Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)
        let target = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
        let (sttAvailable, ttsAvailable) = (stt.availability, tts.availability)
        let sttPicks = [
            ModelChoice.stt(for: source, direction: .outgoing, catalog: stt.catalog, availability: sttAvailable),
            ModelChoice.stt(for: target, direction: .incoming, catalog: stt.catalog, availability: sttAvailable)
        ]
        let ttsPicks = [
            ModelChoice.tts(for: target, direction: .outgoing, catalog: tts.catalog, availability: ttsAvailable),
            ModelChoice.tts(for: source, direction: .incoming, catalog: tts.catalog, availability: ttsAvailable)
        ]
        var wanted: Set<PreloadModel> = []
        if sttPicks.contains(.parakeet) { wanted.insert(.parakeet) }
        if sttPicks.contains(.whisper) { wanted.insert(.whisper) }
        if ttsPicks.contains(.kokoro), !tts.voiceCloningEnabled { wanted.insert(.kokoro) }
        return wanted
    }

    /// Loads what the pair needs and unloads what it no longer needs; a no-op during a session.
    func preload() async {
        guard !isSessionActive() else { return }
        let wanted = wantedModels()
        for model in loaded.subtracting(wanted) { await loaders.unload(model) }
        for model in wanted.subtracting(loaded) { await loaders.load(model) }
        loaded = wanted
    }

    private func schedule() {
        let previous = pending
        pending = Task { [weak self] in
            await previous?.value   // one preload at a time, in order
            await self?.preload()
        }
    }
}
```

- [ ] **Step 4: Wire it in `AppContainer` (P12)**

Add `let uiServices: UIServices` with a doc line, `/// M9 UI core: in-call state for the panel and popover, the call-app list, model preload.`.

Write `VoiceProfileManager(...)` on two lines:
```swift
        let voiceProfiles = VoiceProfileManager(store: VoiceProfileStore(), recorder: VoiceProfileRecorder(),
                                                isSessionActive: { audioManager.isCapturing })
```

The last line of `init`:
```swift
        uiServices = UIServices(coordinator: coordinator, viewModel: audioViewModel, stt: selector, tts: ttsSelector)
```

After the class:
```swift
// MARK: - UIServices

/// The M9 UI core services, built after the view model.
@MainActor
struct UIServices {
    let modelPreloader: ModelPreloader

    /// The preloader never runs in the test host (REQ-UI-21a).
    init(coordinator: AudioCoordinator, viewModel: AudioViewModel, stt: STTEngineSelector, tts: TTSEngineSelector) {
        modelPreloader = ModelPreloader(stt: stt, tts: tts, languagePairManager: viewModel.languagePairManager,
                                        isSessionActive: { coordinator.isOutgoingActive || coordinator.isStarting })
        if !AppContainer.isTestHost { modelPreloader.start() }
    }
}
```

- [ ] **Step 5: Run, lint**

Run: `just test-only ModelPreloaderTests ModelChoiceSelectorTests && just lint`
Expected: PASS, and no lint output (`AppContainer.init` ≤ 50 lines).

- [ ] **Step 6: Commit**

```bash
git add TranslateCall/Core/Models/ModelPreloader.swift TranslateCall/App/AppContainer.swift TranslateCallTests/ModelPreloaderTests.swift
git commit -m "feat(models): preload cached models for the current pair at launch and on pair change (M9 UI core T6)"
```

---

### Task 7: `PauseGate` (opus)

**Files:**
- Create: `TranslateCall/Core/Session/PauseGate.swift`
- Test: `TranslateCallTests/PauseGateTests.swift`

**Interfaces:**
- Consumes: `MicEchoGate.silence(like:)` (existing, static), `SessionAudioStream(label:)`.
- Produces: `nonisolated final class PauseGate: Sendable`, with `isPaused`, `setPaused(_:)`, `gate(_:label:) -> AsyncStream<AVAudioPCMBuffer>` and `process(_:)`.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/PauseGateTests.swift`:
```swift
import AVFoundation
import Testing
@testable import TranslateCall

private func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
    guard let data = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

@Suite("PauseGate (M9 UI core D-5)")
struct PauseGateTests {

    @Test("running: buffers pass through untouched")
    func passThrough() {
        let gate = PauseGate()
        let buffer = makePCMBuffer(frames: 480, fill: 0.5)
        #expect(gate.process(buffer) === buffer)
        #expect(!gate.isPaused)
    }

    @Test("paused: zeros of the same format and length; the captured buffer is not modified (REQ-UI-50)")
    func pausedSilences() {
        let gate = PauseGate()
        gate.setPaused(true)
        let buffer = makePCMBuffer(frames: 480, sampleRate: 48_000, fill: 0.5)
        let out = gate.process(buffer)
        #expect(out !== buffer)
        #expect(out.format == buffer.format)
        #expect(out.frameLength == buffer.frameLength)
        #expect(samples(of: out).allSatisfy { $0 == 0 })
        #expect(samples(of: buffer).allSatisfy { $0 == 0.5 })
    }

    @Test("resume takes effect from the next buffer (REQ-UI-51)")
    func resumeNextBuffer() {
        let gate = PauseGate()
        gate.setPaused(true)
        #expect(samples(of: gate.process(makePCMBuffer(fill: 0.5))).allSatisfy { $0 == 0 })
        gate.setPaused(false)
        let next = makePCMBuffer(fill: 0.5)
        #expect(gate.process(next) === next)
    }

    @Test("the gated stream keeps every buffer and finishes with its input")
    func streamKeepsEveryBuffer() async {
        let gate = PauseGate()
        let (input, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        let output = gate.gate(input, label: "test")
        continuation.yield(makePCMBuffer(fill: 0.5))
        gate.setPaused(true)
        continuation.yield(makePCMBuffer(fill: 0.5))
        continuation.finish()
        var peaks: [Float] = []
        for await buffer in output { peaks.append(samples(of: buffer).max() ?? 0) }
        #expect(peaks.count == 2)
        #expect(peaks.last == 0)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `just test-only PauseGateTests`
Expected: FAIL (`PauseGate` undefined).

- [ ] **Step 3: Implement** `TranslateCall/Core/Session/PauseGate.swift`:
```swift
import AVFoundation
import Synchronization

// MARK: - PauseGate

/// Pause for both directions (M9 UI core D-5, REQ-UI-50/51, design §4.2).
///
/// Sits before each VAD (`mic → PauseGate → MicEchoGate → VAD`, `call audio → PauseGate → VAD`).
/// While paused every buffer becomes zeros of the same format and length, like `MicEchoGate`:
/// the VAD keeps its timeline and ends an utterance in progress by its silence rule. Nothing is
/// dropped. One gate per session, shared by both directions; it never touches the echo gate.
nonisolated final class PauseGate: Sendable {
    private let paused = Mutex(false)

    var isPaused: Bool { paused.withLock { $0 } }

    /// Takes effect from the next buffer.
    func setPaused(_ value: Bool) {
        paused.withLock { $0 = value }
    }

    /// The gated copy of `input`, finishing when `input` finishes.
    func gate(_ input: AsyncStream<AVAudioPCMBuffer>, label: String) -> AsyncStream<AVAudioPCMBuffer> {
        let output = SessionAudioStream(label: label)
        Task { [self] in
            for await buffer in input {
                output.yield(process(buffer))
            }
            output.finish()
        }
        return output.stream
    }

    /// The same instance when running, a zeroed copy while paused.
    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard isPaused else { return buffer }
        return MicEchoGate.silence(like: buffer) ?? buffer
    }
}
```

- [ ] **Step 4: Run**

Run: `just test-only PauseGateTests MicEchoGateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Session/PauseGate.swift TranslateCallTests/PauseGateTests.swift
git commit -m "feat(session): pause gate that silences audio before the VAD (M9 UI core T7)"
```

---

### Task 8: Coordinator session state: transcript, translating flags, "hearing them", start time (opus)

**Files:**
- Create: `TranslateCall/Core/Audio/AudioCoordinator+Monitor.swift` (moved code), `TranslateCall/Core/Audio/AudioCoordinator+Session.swift`
- Modify: `TranslateCall/Core/Audio/AudioCoordinator.swift`, `TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift`
- Modify (test support):
  - `TranslateCallTests/Mocks/MockVADService.swift`: `injectVADState`;
  - `TranslateCallTests/TranslationPipelineTests.swift`: `MockTranslationService` gains `holdNext`/`releaseHeld`/`isHolding`.
- Test: `TranslateCallTests/AudioCoordinatorSessionTests.swift`

**Interfaces:**
- Consumes: Task 3 (`TranscriptEntry`, `TranscriptDirection`).
- Produces on `AudioCoordinator`, all `@Published` with internal setters (P2):
  - `isOutgoingTranslating`, `isIncomingTranslating`, `isIncomingSpeechActive`;
  - `transcript: [TranscriptEntry]`;
  - `sessionStartedAt: Date?`;
  - methods `beginSessionUIState()`, `endSessionUIState()`, `appendTranscript(_:_:) -> UUID`, `completeTranscript(_:translation:)`, `skipTranscript(_:error:)` and `observeIncomingVADState(_:)`.

- [ ] **Step 1: Test support**

In `MockVADService`, add before `injectSpeechSegment`:
```swift
    /// Inject a VAD speech-state change (`true` = speech started).
    func injectVADState(_ active: Bool) {
        stateContinuation?.yield(active)
    }
```

In `MockTranslationService` (`TranslationPipelineTests.swift`), add a hold, so a test can see a translation in flight:
```swift
    /// When set, the next `translate` waits here until `releaseHeld()` (a slow translation).
    var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    var isHolding: Bool { held != nil }
    func releaseHeld() { held?.resume(); held = nil }
```
In `translate`, right after `lastTranslatedText = text`, add:
```swift
        if holdNext {
            holdNext = false
            await withCheckedContinuation { held = $0 }
        }
```

- [ ] **Step 2: Write the failing tests**

`TranslateCallTests/AudioCoordinatorSessionTests.swift`:
```swift
import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

private let callTarget = CaptureTarget.app(bundleID: "com.test.call")

@MainActor
private func makeCoordinator(_ mocks: CoordinatorMocks) -> AudioCoordinator {
    AudioCoordinator(
        audioCapture: mocks.mockAudioCapture,
        systemCapture: mocks.mockSystemCapture,
        outgoingVADFactory: { mocks.mockVADFactory },
        incomingVADFactory: { mocks.mockIncomingVAD },
        outgoingSTTFactory: { _ in mocks.mockOutgoingSTT },
        incomingSTTFactory: { _ in mocks.mockIncomingSTT },
        outgoingTranslationService: mocks.mockOutgoingTranslation,
        incomingTranslationService: mocks.mockIncomingTranslation,
        outgoingTTSFactory: { _, _ in mocks.mockOutgoingTTS },
        incomingTTSFactory: { _, _ in mocks.mockIncomingTTS },
        languagePairManager: mocks.languagePairManager,
        echoGateClock: TestClock(),
        noticeClock: TestClock()
    )
}

private func transcript(_ text: String) -> TranscriptionResult {
    TranscriptionResult(text: text, confidence: 1, locale: Locale(identifier: "es-ES"), capturedAt: .now, audioDuration: 1)
}

/// Feeds one loud buffer to `inject` and waits until `vad` has seen it; returns its peak there.
@MainActor
private func peakAtVAD(_ vad: MockVADService, inject: () async -> Void) async -> Float? {
    let before = await vad.receivedPeaks.count
    await inject()
    guard await waitUntil({ await vad.receivedPeaks.count == before + 1 }) else { return nil }
    return await vad.receivedPeaks.last
}

@Suite("AudioCoordinator session state for the UI (M9 UI core)", .serialized) @MainActor
struct AudioCoordinatorSessionTests {

    // MARK: Transcript and flags (design §4.1)

    @Test("a sentence is appended when STT delivers it and completed when translated")
    func transcriptAppendAndComplete() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        #expect(coordinator.sessionStartedAt != nil)

        mocks.mockOutgoingTranslation.holdNext = true
        await mocks.mockOutgoingSTT.injectTranscription(transcript("hola"))
        #expect(await waitUntil { coordinator.isOutgoingTranslating })
        #expect(coordinator.transcript.map(\.original) == ["hola"])
        #expect(coordinator.transcript.first?.translation == nil)
        #expect(coordinator.transcript.first?.direction == .outgoing)

        mocks.mockOutgoingTranslation.releaseHeld()
        #expect(await waitUntil { !coordinator.isOutgoingTranslating })
        #expect(coordinator.transcript.first?.translation == "TRANSLATED: hola")
        await coordinator.stop()
        #expect(coordinator.sessionStartedAt == nil)
        #expect(coordinator.transcript.count == 1, "kept after Stop until the next Start")
    }

    @Test("a failed translation marks the entry skipped")
    func failedTranslationSkipped() async {
        let mocks = CoordinatorMocks()
        mocks.mockOutgoingTranslation.errors = [TranslationError.timedOut]
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("uno"))
        #expect(await waitUntil { coordinator.transcript.first?.skipped == true })
        #expect(coordinator.transcript.first?.translation == nil)
        #expect(!coordinator.isOutgoingTranslating)
        await coordinator.stop()
    }

    @Test("the transcript keeps the newest 200 entries and is cleared at the next start (REQ-UI-44)")
    func transcriptCapAndClear() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        for index in 0..<205 { _ = coordinator.appendTranscript(.incoming, "s\(index)") }
        #expect(coordinator.transcript.count == TranscriptEntry.limit)
        #expect(coordinator.transcript.first?.original == "s5")
        #expect(coordinator.transcript.last?.original == "s204")

        await coordinator.start()
        #expect(coordinator.transcript.isEmpty)
        await coordinator.stop()
    }

    @Test("the incoming VAD drives isIncomingSpeechActive; teardown clears it")
    func incomingSpeechActive() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(await waitUntil { coordinator.isIncomingActive })

        await mocks.mockIncomingVAD.injectVADState(true)
        #expect(await waitUntil { coordinator.isIncomingSpeechActive })
        await coordinator.stop()
        #expect(!coordinator.isIncomingSpeechActive)
    }
}
```

- [ ] **Step 3: Run, expect failure**

Run: `just test-only AudioCoordinatorSessionTests`
Expected: FAIL (`transcript`, `isOutgoingTranslating`, `appendTranscript` undefined).

- [ ] **Step 4: Make room (P2)**

Move the whole `// MARK: - TTS Monitor actions` block (`enableTTSMonitor`, `disableTTSMonitor`, `toggleTTSRecording`, `playLastRecording`) verbatim from `AudioCoordinator.swift` into a new `AudioCoordinator+Monitor.swift`:
```swift
import Foundation

// MARK: - TTS monitor (local playback + recording of outgoing TTS)

extension AudioCoordinator {
    // … the four methods, unchanged …
}
```
In `AudioCoordinator.swift`, `ttsMonitorRecording` and `ttsMonitor` lose `private(set)`, because the extension writes them.

- [ ] **Step 5: Implement the state**

In `AudioCoordinator.swift`, before `// MARK: - TTS Audio Monitor`, add:
```swift
    // MARK: - UI session state (M9 UI core design §4.1)
    // Written by AudioCoordinator+Session.swift and +Pipeline.swift, hence internal setters.

    @Published var isOutgoingTranslating = false
    @Published var isIncomingTranslating = false
    /// The incoming VAD hears speech ("Hearing them").
    @Published var isIncomingSpeechActive = false
    /// This session's sentences, newest last, at most `TranscriptEntry.limit` (REQ-UI-44).
    @Published var transcript: [TranscriptEntry] = []
    /// When the outgoing side went active; nil outside a session.
    @Published var sessionStartedAt: Date?
```

In `start()`:
- after `micEchoGate = makeMicEchoGate()`, call `beginSessionUIState()`;
- call `endSessionUIState()` right after both early `releaseMicEchoGate()` returns (outgoing failed; superseded);
- after `isOutgoingActive = true`, set `sessionStartedAt = .now`.

In `stop()`, after `suppressNextOutgoingTurnFlag = false`, call `endSessionUIState()`.

`AudioCoordinator+Session.swift`:
```swift
import Foundation

// MARK: - Pause and the session transcript (M9 UI core D-5, REQ-UI-44/50…52, design §4.1–4.2)

extension AudioCoordinator {

    /// "Hearing them": the incoming VAD's speech state (REQ-UI-43).
    func observeIncomingVADState(_ vad: some VADService) {
        incomingTasks.append(Task { [weak self] in
            for await active in vad.vadStateEvents {
                guard !Task.isCancelled else { return }
                self?.isIncomingSpeechActive = active
            }
        })
    }

    /// A new session: empty transcript.
    func beginSessionUIState() {
        transcript.removeAll()
    }

    /// The session ended (stop, or a start that did not go active). The transcript stays readable
    /// until the next start.
    func endSessionUIState() {
        isOutgoingTranslating = false
        isIncomingTranslating = false
        isIncomingSpeechActive = false
        sessionStartedAt = nil
    }

    /// Appends a sentence (translation pending) and keeps the newest `TranscriptEntry.limit`.
    func appendTranscript(_ direction: TranscriptDirection, _ text: String) -> UUID {
        let entry = TranscriptEntry(direction: direction, original: text)
        transcript.append(entry)
        if transcript.count > TranscriptEntry.limit {
            transcript.removeFirst(transcript.count - TranscriptEntry.limit)
        }
        return entry.id
    }

    func completeTranscript(_ id: UUID, translation: String) {
        guard let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index].translation = translation
    }

    /// A failed sentence is marked skipped; a cancelled one (session stopping) is left as it is.
    func skipTranscript(_ id: UUID, error: Error) {
        guard !(error is CancellationError),
              let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index].skipped = true
    }
}
```

In `AudioCoordinator+Pipeline.swift`:
- in `activateIncoming`, right after `try await vad.activate(stream: systemStream)` and its `try ensureCurrent(generation)`, call `observeIncomingVADState(vad)`;
- in `teardownIncomingServices`, after `isIncomingSpeaking = false`, set `isIncomingSpeechActive = false`;
- `handleOutgoingTranslation`, after the `guard !text.isEmpty else { return }`:
  ```swift
          let entry = appendTranscript(.outgoing, text)
          isOutgoingTranslating = true
          defer { isOutgoingTranslating = false }
  ```
  - on success, after `outgoingTranslation = translated`, call `completeTranscript(entry, translation: translated)`;
  - in `catch`, call `skipTranscript(entry, error: error)` before `handleTranslationFailure`;
- do the same in `handleIncomingTranslation` with `.incoming`, `isIncomingTranslating` and `incomingTranslation`.

- [ ] **Step 6: Run**

Run: `just test-only AudioCoordinatorSessionTests AudioCoordinatorTests AudioCoordinatorTranslationTests AudioCoordinatorEchoGateTests AudioCoordinatorTTSTests`
Expected: PASS.

- [ ] **Step 7: Lint and commit**

Run: `just lint`. Expected: no output (all three coordinator files ≤ 400 lines).
```bash
git add TranslateCall/Core/Audio TranslateCallTests/AudioCoordinatorSessionTests.swift \
  TranslateCallTests/Mocks/MockVADService.swift TranslateCallTests/TranslationPipelineTests.swift
git commit -m "feat(session): coordinator publishes transcript, translating and hearing state (M9 UI core T8)"
```

---

### Task 9: Pause and Resume in the coordinator (opus)

**Files:**
- Modify: `TranslateCall/Core/Audio/AudioCoordinator.swift`, `AudioCoordinator+Pipeline.swift`, `AudioCoordinator+Session.swift`
- Test: `TranslateCallTests/AudioCoordinatorSessionTests.swift` (add the pause tests)

**Interfaces:**
- Consumes: Task 7 (`PauseGate`), Task 8.
- Produces: `AudioCoordinator.isPaused` (`@Published`), `pauseGate: PauseGate?`, `pause() async`, `resume()`.

- [ ] **Step 1: Write the failing tests**

Add inside `AudioCoordinatorSessionTests`, after the last test:
```swift
    // MARK: Pause (D-5, REQ-UI-50…52)

    @Test("pause silences both directions before their VADs and stops both TTS")
    func pauseSilencesBothDirections() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(await waitUntil { coordinator.isIncomingActive })

        await coordinator.pause()
        #expect(coordinator.isPaused)
        #expect(await mocks.mockOutgoingTTS.stopSpeakingCalled)
        #expect(await mocks.mockIncomingTTS.stopSpeakingCalled)
        let micPeak = await peakAtVAD(mocks.mockVADFactory) {
            mocks.mockAudioCapture.injectBuffer(makePCMBuffer(frames: 160, fill: 0.5))
        }
        let callPeak = await peakAtVAD(mocks.mockIncomingVAD) {
            await mocks.mockSystemCapture.injectBuffer(makePCMBuffer(frames: 160, fill: 0.5))
        }
        #expect(micPeak == 0)
        #expect(callPeak == 0)

        coordinator.resume()
        let resumed = await peakAtVAD(mocks.mockVADFactory) {
            mocks.mockAudioCapture.injectBuffer(makePCMBuffer(frames: 160, fill: 0.5))
        }
        #expect(resumed == 0.5, "from the next buffer, nothing reloaded")
        #expect(mocks.mockAudioCapture.startCount == 1)
        await coordinator.stop()
    }

    @Test("text delivered while paused is not translated; after Resume it is")
    func pausedTextDropped() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        await coordinator.pause()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("ignored"))
        #expect(await waitUntil { coordinator.outgoingTranscription == "ignored" })   // consumed while paused
        coordinator.resume()
        await mocks.mockOutgoingSTT.injectTranscription(transcript("kept"))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.translateCallCount == 1 })
        #expect(mocks.mockOutgoingTranslation.lastTranslatedText == "kept")
        #expect(coordinator.transcript.map(\.original) == ["kept"])
        await coordinator.stop()
    }

    @Test("a sentence whose translation returns after Pause is shown, not spoken")
    func translationReturningAfterPauseIsNotSpoken() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        mocks.mockOutgoingTranslation.holdNext = true
        await mocks.mockOutgoingSTT.injectTranscription(transcript("hola"))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.isHolding })

        await coordinator.pause()
        mocks.mockOutgoingTranslation.releaseHeld()
        #expect(await waitUntil { coordinator.transcript.first?.translation == "TRANSLATED: hola" })
        #expect(await mocks.mockOutgoingTTS.speakCalls.isEmpty)
        await coordinator.stop()
    }

    @Test("pause outside a session does nothing; Stop while paused resets; the echo gate is untouched")
    func pauseEdges() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.pause()
        #expect(!coordinator.isPaused)

        coordinator.listeningMode = .speakers
        await coordinator.start(captureTarget: callTarget)
        await coordinator.pause()
        #expect(coordinator.conversationState != .micPaused, "pausing is not the echo gate")
        await coordinator.stop()
        #expect(!coordinator.isPaused)
        #expect(coordinator.pauseGate == nil)
    }

    @Test("Retry while paused re-activates incoming behind the same gate: still silent")
    func retryWhilePausedStaysSilent() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.setThrowOnActivate(SystemAudioCaptureError.targetNotFound(bundleID: "com.test.call"))
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(await waitUntil { if case .stopped = coordinator.incomingStatus { true } else { false } })
        await coordinator.pause()

        await mocks.mockSystemCapture.setThrowOnActivate(nil)
        coordinator.retryIncoming(captureTarget: callTarget)
        #expect(await waitUntil { coordinator.isIncomingActive })
        let callPeak = await peakAtVAD(mocks.mockIncomingVAD) {
            await mocks.mockSystemCapture.injectBuffer(makePCMBuffer(frames: 160, fill: 0.5))
        }
        #expect(callPeak == 0)
        await coordinator.stop()
    }
```

- [ ] **Step 2: Run, expect failure**

Run: `just test-only AudioCoordinatorSessionTests`
Expected: FAIL (`pause()`, `isPaused`, `pauseGate` undefined).

- [ ] **Step 3: Implement**

In `AudioCoordinator.swift`, in the UI-state block, add:
```swift
    /// Both directions paused, engines warm (D-5).
    @Published var isPaused = false
    /// This session's pause gate; nil outside a session.
    var pauseGate: PauseGate?
```

In `AudioCoordinator+Session.swift`:
- `beginSessionUIState()` also sets `pauseGate = PauseGate()`;
- `endSessionUIState()` also sets `pauseGate = nil` and `isPaused = false`;
- add:
```swift
    /// Pauses both directions with the engines kept warm: call audio and mic reach the VADs as
    /// silence, playing and queued translations stop, text arriving meanwhile is dropped.
    /// No-op outside a session or when already paused. The echo gate is not touched.
    func pause() async {
        guard isOutgoingActive, !isPaused else { return }
        isPaused = true
        pauseGate?.setPaused(true)
        await outgoingTTS?.stopSpeaking()
        await incomingTTS?.stopSpeaking()
    }

    /// Back to normal processing from the next buffer; nothing is reloaded (REQ-UI-51).
    func resume() {
        guard isPaused else { return }
        isPaused = false
        pauseGate?.setPaused(false)
    }
```

In `AudioCoordinator+Pipeline.swift`:
- `startOutgoingPipeline`: mic → pause → echo → VAD:
  ```swift
          // Pause (M9 UI core D-5) comes first, so pausing never touches the echo gate's own state.
          let pausable = pauseGate?.gate(micStream, label: "outgoing-pause") ?? micStream
          let vadInput = micEchoGate?.gate(pausable) ?? pausable
  ```
- `activateIncoming`: `try await vad.activate(stream: pauseGate?.gate(systemStream, label: "incoming-pause") ?? systemStream)`. A Retry during a pause goes through the same gate, so it stays silent.
- Both translation handlers:
  - drop text while paused: `guard !text.isEmpty, !isPaused else { return }`, adding `// Dropped while paused (M9 UI core REQ-UI-50).` on the outgoing one;
  - after `completeTranscript(...)`, before `speak`, add `guard !isPaused else { return }   // paused while translating: shown, not spoken`.

- [ ] **Step 4: Run three times**

Run: `for i in 1 2 3; do just test-only AudioCoordinatorSessionTests PauseGateTests AudioCoordinatorEchoGateTests AudioCoordinatorTests; done`
Expected: PASS in every run.

- [ ] **Step 5: Lint and commit**

Run: `just lint`. Expected: no output.
```bash
git add TranslateCall/Core/Audio TranslateCallTests/AudioCoordinatorSessionTests.swift
git commit -m "feat(session): Pause and Resume both directions with engines kept warm (M9 UI core T9)"
```

---

### Task 10: `DirectionState`, `SessionPhase`, `PanelTitle`, `DirectionCopy`, `MenuBarDot` (sonnet)

**Files:**
- Create: `TranslateCall/Core/Session/DirectionState.swift`, `TranslateCall/Features/StatusPanel/DirectionCopy.swift`, `TranslateCall/Features/MenuBar/MenuBarIcon.swift`
- Test: `TranslateCallTests/DirectionStateTests.swift`, `TranslateCallTests/UICopyTests.swift` (with `MenuBarDotTests`)

**Interfaces:**
- Consumes: `IncomingStatus`, `IncomingStopReason` (existing), `TranscriptDirection` (Task 3).
- Produces:
  - `DirectionState`, with `outgoing(paused:micPaused:speaking:translating:speech:)` and `incoming(status:paused:speaking:translating:speech:)`;
  - `SessionPhase { idle, starting, running }`;
  - `PanelTitle`, with `derive(isStarting:isPaused:incoming:)` and `.text`;
  - `DirectionCopy`, with `chip(_:direction:appName:)`, `unavailableLine(_:appName:)`, `outgoingOnlyLine` and `accessibilityLabel(direction:from:to:state:)`;
  - `MenuBarDot`, with `derive(phase:title:)` and `symbolName = "translate"`.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/DirectionStateTests.swift`:
```swift
import Testing
@testable import TranslateCall

@Suite("DirectionState (M9 UI core REQ-UI-43)")
struct DirectionStateTests {

    @Test("outgoing priority: paused > mic paused > speaking > translating > hearing > listening",
          arguments: [
            (true, true, true, true, true, DirectionState.paused),
            (false, true, true, true, true, .micPaused),
            (false, false, true, true, true, .speaking),
            (false, false, false, true, true, .translating),
            (false, false, false, false, true, .hearing),
            (false, false, false, false, false, .listening),
          ])
    func outgoingPriority(paused: Bool, micPaused: Bool, speaking: Bool, translating: Bool, speech: Bool,
                          expected: DirectionState) {
        #expect(DirectionState.outgoing(paused: paused, micPaused: micPaused, speaking: speaking,
                                        translating: translating, speech: speech) == expected)
    }

    @Test("incoming: a stopped capture wins over everything, even pause")
    func incomingUnavailableWins() {
        let state = DirectionState.incoming(status: .stopped(.targetNotFound(bundleID: "us.zoom.xos")), paused: true,
                                            speaking: true, translating: true, speech: true)
        #expect(state == .unavailable(.targetNotFound(bundleID: "us.zoom.xos")))
    }

    @Test("incoming active/starting/idle derive normally", arguments: [IncomingStatus.active, .starting, .idle])
    func incomingNormal(status: IncomingStatus) {
        #expect(DirectionState.incoming(status: status, paused: true, speaking: false, translating: false, speech: false)
                == .paused)
        #expect(DirectionState.incoming(status: status, paused: false, speaking: false, translating: true, speech: true)
                == .translating)
        #expect(DirectionState.incoming(status: status, paused: false, speaking: false, translating: false, speech: false)
                == .listening)
    }

    @Test("panel title: Starting… > Partly working > Paused > Translating")
    func panelTitle() {
        let lost = DirectionState.unavailable(.permissionDenied)
        #expect(PanelTitle.derive(isStarting: true, isPaused: true, incoming: lost) == .starting)
        #expect(PanelTitle.derive(isStarting: false, isPaused: true, incoming: lost) == .partlyWorking)
        #expect(PanelTitle.derive(isStarting: false, isPaused: true, incoming: .listening) == .paused)
        #expect(PanelTitle.derive(isStarting: false, isPaused: false, incoming: .speaking) == .translating)
        #expect(PanelTitle.translating.text == "Translating")
    }
}
```

`TranslateCallTests/UICopyTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

@Suite("UI copy and ordering (M9 UI core)")
struct UICopyTests {

    @Test("chip texts per state and direction (REQ-UI-43)")
    func chips() {
        #expect(DirectionCopy.chip(.unavailable(.permissionDenied), direction: .incoming, appName: "Teams")
                == "Can't hear Teams")
        #expect(DirectionCopy.chip(.hearing, direction: .outgoing, appName: "Teams") == "Hearing you")
        #expect(DirectionCopy.chip(.hearing, direction: .incoming, appName: "Teams") == "Hearing them")
        #expect(DirectionCopy.chip(.translating, direction: .outgoing, appName: "") == "Translating…")
        #expect(DirectionCopy.chip(.micPaused, direction: .outgoing, appName: "") == "Mic paused")
    }

    @Test("unavailable lines name the cause")
    func unavailableLines() {
        #expect(DirectionCopy.unavailableLine(.targetNotFound(bundleID: "us.zoom.xos"), appName: "Zoom")
                == "Zoom isn't running. Open it, then Retry.")
        #expect(DirectionCopy.unavailableLine(.streamError("boom"), appName: "Zoom") == "Call audio stopped: boom")
    }

    @Test("VoiceOver label reads direction, languages and state (NFR-UI-04)")
    func accessibility() {
        #expect(DirectionCopy.accessibilityLabel(direction: .outgoing, from: "Spanish", to: "German", state: "Speaking")
                == "You, Spanish to German, speaking")
    }
}

@Suite("Menu bar dot (M9 UI core REQ-UI-61)")
struct MenuBarDotTests {
    @Test("idle → none; translating → green; paused, partly working or starting → orange")
    func dots() {
        #expect(MenuBarDot.derive(phase: .idle, title: .translating) == MenuBarDot.none)
        #expect(MenuBarDot.derive(phase: .running, title: .translating) == .green)
        #expect(MenuBarDot.derive(phase: .running, title: .paused) == .orange)
        #expect(MenuBarDot.derive(phase: .running, title: .partlyWorking) == .orange)
        #expect(MenuBarDot.derive(phase: .starting, title: .starting) == .orange)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `just test-only DirectionStateTests UICopyTests MenuBarDotTests`
Expected: FAIL (types undefined).

- [ ] **Step 3: Implement**

`TranslateCall/Core/Session/DirectionState.swift`:
```swift
import Foundation

// MARK: - DirectionState

/// What one direction's chip shows in the status panel and the popover (REQ-UI-43, design §4.3).
/// Exactly one state, in this priority order.
nonisolated enum DirectionState: Equatable, Sendable {
    /// Incoming only: capture stopped ("Can't hear <App>").
    case unavailable(IncomingStopReason)
    case paused
    /// Outgoing only, speakers mode: the echo gate mutes the mic.
    case micPaused
    case speaking
    case translating
    /// The VAD hears speech ("Hearing you" / "Hearing them").
    case hearing
    case listening

    static func outgoing(paused: Bool, micPaused: Bool, speaking: Bool,
                         translating: Bool, speech: Bool) -> DirectionState {
        if paused { return .paused }
        if micPaused { return .micPaused }
        return common(speaking: speaking, translating: translating, speech: speech)
    }

    /// `.disabled` (no call app) is presented by the view from `IncomingStatus` directly.
    static func incoming(status: IncomingStatus, paused: Bool, speaking: Bool,
                         translating: Bool, speech: Bool) -> DirectionState {
        if case .stopped(let reason) = status { return .unavailable(reason) }
        if paused { return .paused }
        return common(speaking: speaking, translating: translating, speech: speech)
    }

    private static func common(speaking: Bool, translating: Bool, speech: Bool) -> DirectionState {
        if speaking { return .speaking }
        if translating { return .translating }
        if speech { return .hearing }
        return .listening
    }
}

// MARK: - Session phase

/// Idle, starting or running: drives the primary button, the panel and the menu bar dot.
nonisolated enum SessionPhase: Sendable, Equatable {
    case idle, starting, running
}

// MARK: - Panel title

/// The status panel and popover header (REQ-UI-42).
nonisolated enum PanelTitle: Equatable, Sendable {
    case starting, paused, partlyWorking, translating

    static func derive(isStarting: Bool, isPaused: Bool, incoming: DirectionState) -> PanelTitle {
        if isStarting { return .starting }
        if case .unavailable = incoming { return .partlyWorking }
        if isPaused { return .paused }
        return .translating
    }

    var text: String {
        switch self {
        case .starting: String(localized: "Starting…")
        case .paused: String(localized: "Paused")
        case .partlyWorking: String(localized: "Partly working")
        case .translating: String(localized: "Translating")
        }
    }
}
```

`TranslateCall/Features/StatusPanel/DirectionCopy.swift`:
```swift
import Foundation

/// Texts of a direction row and chip (REQ-UI-42/43); `appName` is the call app's name.
nonisolated enum DirectionCopy {
    static func chip(_ state: DirectionState, direction: TranscriptDirection, appName: String) -> String {
        switch state {
        case .unavailable: String(localized: "Can't hear \(appName)")
        case .paused: String(localized: "Paused")
        case .micPaused: String(localized: "Mic paused")
        case .speaking: String(localized: "Speaking")
        case .translating: String(localized: "Translating…")
        case .hearing where direction == .outgoing: String(localized: "Hearing you")
        case .hearing: String(localized: "Hearing them")
        case .listening: String(localized: "Listening")
        }
    }

    /// The line under an unavailable "Them" row (replaces the old incoming banner text).
    static func unavailableLine(_ reason: IncomingStopReason, appName: String) -> String {
        switch reason {
        case .targetNotFound: String(localized: "\(appName) isn't running. Open it, then Retry.")
        case .permissionDenied: String(localized: "Screen & System Audio Recording is off for TranslateCall.")
        case .streamError(let detail): String(localized: "Call audio stopped: \(detail)")
        }
    }

    /// "Only your voice is translated" when no call app is chosen (`IncomingStatus.disabled`).
    static let outgoingOnlyLine = String(localized: "Only your voice is translated")

    /// VoiceOver: "You, Spanish to German, speaking" (NFR-UI-04).
    static func accessibilityLabel(direction: TranscriptDirection, from source: String, to target: String,
                                   state: String) -> String {
        let who = direction == .outgoing ? String(localized: "You") : String(localized: "Them")
        return String(localized: "\(who), \(source) to \(target), \(state.lowercased())")
    }
}
```

`TranslateCall/Features/MenuBar/MenuBarIcon.swift`:
```swift
import Foundation

/// The status item's dot (REQ-UI-61): none when idle, green while translating, orange while
/// paused or partly working (or starting).
nonisolated enum MenuBarDot: Equatable, Sendable {
    case none, green, orange

    static func derive(phase: SessionPhase, title: PanelTitle) -> MenuBarDot {
        switch phase {
        case .idle: return .none
        case .starting: return .orange
        case .running: return title == .translating ? .green : .orange
        }
    }

    /// The base glyph; the dot is drawn over it.
    static let symbolName = "translate"
}
```

- [ ] **Step 4: Run, lint**

Run: `just test-only DirectionStateTests UICopyTests MenuBarDotTests && just lint`
Expected: PASS, no lint output.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Session/DirectionState.swift TranslateCall/Features/StatusPanel/DirectionCopy.swift \
  TranslateCall/Features/MenuBar/MenuBarIcon.swift TranslateCallTests/DirectionStateTests.swift TranslateCallTests/UICopyTests.swift
git commit -m "feat(ui): direction state, panel title, chip copy and menu bar dot rules (M9 UI core T10)"
```

---

### Task 11: Call apps — catalog, live monitor, selection by bundle ID (sonnet)

**Files:**
- Create: `TranslateCall/Core/Setup/CallApp.swift`, `TranslateCall/Core/Setup/CallAppMonitor.swift`, `TranslateCallTests/Mocks/FakeWorkspace.swift`
- Modify: `TranslateCall/Core/Setup/SetupManager.swift`, `TranslateCall/Features/Main/AudioViewModel.swift` (`bindSetupManager` only), `TranslateCall/App/AppContainer.swift` (`UIServices.callAppMonitor`)
- Test: `TranslateCallTests/CallAppMonitorTests.swift`; append to `TranslateCallTests/SetupManagerTests.swift` and `TranslateCallTests/AudioViewModelTests.swift`

**Interfaces:**
- Produces:
  - `CallApp`, with `catalog` and `meetURL`;
  - `CallAppRow`, with `bundleID`, `title`, `appName`, `callAppID`, `symbol`, `appURL`, `openURL` and `isRunning`;
  - `protocol WorkspaceProviding`, with `LiveWorkspace` as the real implementation;
  - `@MainActor final class CallAppMonitor`:
    - `init(workspace:selectedBundleID:)`;
    - `rows`, `runningBundleIDs`;
    - `refresh()`, `setSelected(bundleID:)`, `runningRegularApps()`, `open(_:) async`;
    - `waitUntilRunning(bundleID:timeout:pollEvery:) async -> Bool`;
  - `SetupManager.selectCaptureApp(bundleID:)` and `@Published selectedCaptureBundleID`;
  - `UIServices.callAppMonitor`.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/Mocks/FakeWorkspace.swift`:
```swift
import Foundation
@testable import TranslateCall

/// In-memory `WorkspaceProviding`: installed apps by bundle ID, a running set, a default browser.
@MainActor
final class FakeWorkspace: WorkspaceProviding {
    var installed: [String: String] = [:]          // bundle ID → display name
    var running: Set<String> = []
    var defaultBrowser: String?                     // bundle ID
    private(set) var openedApps: [URL] = []
    private(set) var openedURLs: [URL] = []
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Simulates a launch or quit notification.
    func setRunning(_ bundleID: String, _ isRunning: Bool) {
        if isRunning { running.insert(bundleID) } else { running.remove(bundleID) }
        continuation.yield()
    }

    func urlForApplication(bundleID: String) -> URL? {
        installed[bundleID].map { _ in URL(fileURLWithPath: "/Applications/\(bundleID).app") }
    }
    func defaultBrowserURL() -> URL? { defaultBrowser.flatMap(urlForApplication(bundleID:)) }
    func bundleID(ofAppAt url: URL) -> String? { url.deletingPathExtension().lastPathComponent }
    func displayName(ofAppAt url: URL) -> String { installed[bundleID(ofAppAt: url) ?? ""] ?? "?" }
    func runningBundleIDs() -> Set<String> { running }
    func runningRegularApps() -> [(bundleID: String, name: String)] {
        running.sorted().map { ($0, installed[$0] ?? $0) }
    }
    func openApplication(at url: URL) async throws { openedApps.append(url) }
    func open(_ url: URL) { openedURLs.append(url) }
}
```

`TranslateCallTests/CallAppMonitorTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

@Suite("CallAppMonitor (M9 UI core REQ-UI-02…04, 34)", .serialized) @MainActor
struct CallAppMonitorTests {

    private func workspace() -> FakeWorkspace {
        let fake = FakeWorkspace()
        fake.installed = ["us.zoom.xos": "zoom.us", "com.microsoft.teams2": "Microsoft Teams",
                          "com.google.Chrome": "Google Chrome", "com.apple.FaceTime": "FaceTime"]
        fake.defaultBrowser = "com.google.Chrome"
        return fake
    }

    @Test("only installed apps, in catalog order; Meet maps to the default browser")
    func rowsForInstalledApps() {
        let monitor = CallAppMonitor(workspace: workspace())
        #expect(monitor.rows.map(\.title) == ["Microsoft Teams", "Zoom", "Google Meet · Google Chrome", "FaceTime"])
        let meet = monitor.rows[2]
        #expect(meet.bundleID == "com.google.Chrome")
        #expect(meet.appName == "Google Meet")
        #expect(meet.openURL == CallApp.meetURL)
    }

    @Test("Teams classic is used when only it is installed")
    func olderBundleID() {
        let fake = FakeWorkspace()
        fake.installed = ["com.microsoft.teams": "Microsoft Teams classic"]
        #expect(CallAppMonitor(workspace: fake).rows.map(\.bundleID) == ["com.microsoft.teams"])
    }

    @Test("running state updates live on launch and quit")
    func liveRunningState() async {
        let fake = workspace()
        let monitor = CallAppMonitor(workspace: fake)
        #expect(monitor.rows.first { $0.bundleID == "us.zoom.xos" }?.isRunning == false)
        fake.setRunning("us.zoom.xos", true)
        #expect(await waitUntil { monitor.rows.first { $0.bundleID == "us.zoom.xos" }?.isRunning == true })
        fake.setRunning("us.zoom.xos", false)
        #expect(await waitUntil { monitor.rows.first { $0.bundleID == "us.zoom.xos" }?.isRunning == false })
    }

    @Test("a persisted choice outside the catalog stays as its own row")
    func otherAppKept() {
        let fake = workspace()
        fake.installed["com.example.Call"] = "Example Call"
        let monitor = CallAppMonitor(workspace: fake, selectedBundleID: "com.example.Call")
        #expect(monitor.rows.last?.title == "Example Call")
        #expect(monitor.rows.last?.callAppID == nil)
        monitor.setSelected(bundleID: "us.zoom.xos")
        #expect(!monitor.rows.contains { $0.bundleID == "com.example.Call" })
    }

    @Test("Open launches the app, or opens the Meet page in the browser")
    func openApps() async {
        let fake = workspace()
        let monitor = CallAppMonitor(workspace: fake)
        await monitor.open(monitor.rows[1])
        await monitor.open(monitor.rows[2])
        #expect(fake.openedApps.map(\.lastPathComponent) == ["us.zoom.xos.app"])
        #expect(fake.openedURLs == [CallApp.meetURL])
    }

    @Test("waitUntilRunning: true once the app runs, false after the timeout")
    func waitUntilRunning() async {
        let fake = workspace()
        let monitor = CallAppMonitor(workspace: fake)
        #expect(await !monitor.waitUntilRunning(bundleID: "us.zoom.xos", timeout: .milliseconds(100),
                                                pollEvery: .milliseconds(10)))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            fake.setRunning("us.zoom.xos", true)
        }
        #expect(await monitor.waitUntilRunning(bundleID: "us.zoom.xos", timeout: .seconds(2),
                                               pollEvery: .milliseconds(10)))
    }
}
```

Append to `SetupManagerTests.swift`:
```swift

// MARK: - Selection by bundle ID (M9 UI core REQ-UI-80b)

@Suite("SetupManager selection by bundle ID", .serialized) @MainActor
struct SetupManagerBundleSelectionTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    @Test("an app that is not running can be selected; the target and the published ID follow")
    func selectNotRunningApp() {
        let defaults = makeDefaults()
        let manager = SetupManager(defaults: defaults)
        manager.selectCaptureApp(bundleID: "us.zoom.xos")
        #expect(manager.selectedCaptureBundleID == "us.zoom.xos")
        #expect(manager.captureTarget == .app(bundleID: "us.zoom.xos"))
        #expect(defaults.string(forKey: "tlk.captureApp.bundleID") == "us.zoom.xos")
    }

    @Test("nil or empty selects None (outgoing only)")
    func selectNone() {
        let manager = SetupManager(defaults: makeDefaults())
        manager.selectCaptureApp(bundleID: "us.zoom.xos")
        manager.selectCaptureApp(bundleID: "")
        #expect(manager.selectedCaptureBundleID == nil)
        #expect(manager.captureTarget == nil)
    }

    @Test("the persisted choice is published at init")
    func restoredAtInit() {
        let defaults = makeDefaults()
        defaults.set("com.microsoft.teams2", forKey: "tlk.captureApp.bundleID")
        #expect(SetupManager(defaults: defaults).selectedCaptureBundleID == "com.microsoft.teams2")
    }
}
```

Append to `AudioViewModelTests.swift`. The file-private `ViewModelHarness` is reachable from the same file:
```swift

@Suite("AudioViewModel call-app selection (M9 UI core REQ-UI-80b)", .serialized) @MainActor
struct AudioViewModelCallAppSelectionTests {

    @Test("selecting an app by bundle ID mid-call re-targets a stopped incoming side")
    func bundleSelectionRetries() async {
        let harness = ViewModelHarness()
        await harness.mocks.mockSystemCapture.setThrowOnActivate(
            SystemAudioCaptureError.targetNotFound(bundleID: "com.test.old"))
        await harness.coordinator.start(captureTarget: .app(bundleID: "com.test.old"))
        await harness.mocks.mockSystemCapture.setThrowOnActivate(nil)

        harness.viewModel.setupManager.selectCaptureApp(bundleID: "com.test.new")

        #expect(await waitUntil { harness.coordinator.incomingStatus == .active })
        #expect(await harness.mocks.mockSystemCapture.activatedTargets.last == .app(bundleID: "com.test.new"))
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `just test-only CallAppMonitorTests SetupManagerBundleSelectionTests AudioViewModelCallAppSelectionTests`
Expected: FAIL (types and methods undefined).

- [ ] **Step 3: Implement**

`TranslateCall/Core/Setup/CallApp.swift`:
```swift
import Foundation

// MARK: - CallApp

/// A known call app for the setup window's list (REQ-UI-02…04, design §6).
nonisolated struct CallApp: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case native
        /// Runs in the default browser; "Open" opens this URL.
        case browser(URL)
    }

    let id: String
    let displayName: String
    /// All known bundle IDs, newest first.
    let bundleIDs: [String]
    /// Shown when the app icon cannot be read.
    let symbol: String
    let kind: Kind

    static let meetURL = URL(string: "https://meet.google.com")!

    /// In list order (the prototype's order, then the brief's extra apps).
    static let catalog: [CallApp] = [
        CallApp(id: "teams", displayName: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
                symbol: "person.3.fill", kind: .native),
        CallApp(id: "zoom", displayName: "Zoom", bundleIDs: ["us.zoom.xos"], symbol: "video.fill", kind: .native),
        CallApp(id: "meet", displayName: "Google Meet", bundleIDs: [], symbol: "globe", kind: .browser(meetURL)),
        CallApp(id: "facetime", displayName: "FaceTime", bundleIDs: ["com.apple.FaceTime"],
                symbol: "video.circle.fill", kind: .native),
        CallApp(id: "webex", displayName: "Webex", bundleIDs: ["Cisco-Systems.Spark", "com.cisco.webexmeetingsapp"],
                symbol: "video.bubble.fill", kind: .native),
        CallApp(id: "slack", displayName: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"],
                symbol: "number", kind: .native),
        CallApp(id: "discord", displayName: "Discord", bundleIDs: ["com.hnc.Discord", "com.discord"],
                symbol: "bubble.left.and.bubble.right.fill", kind: .native)
    ]
}

// MARK: - CallAppRow

/// One row of the Call app list: an installed app and its live state.
nonisolated struct CallAppRow: Identifiable, Sendable, Equatable {
    /// The capture target's bundle ID (the browser's for Meet).
    var id: String { bundleID }
    let bundleID: String
    /// "Microsoft Teams", "Google Meet · Chrome".
    let title: String
    /// For copy such as "Open Zoom and start" ("Google Meet" for Meet).
    let appName: String
    /// The catalog entry; nil for an "Other app…" choice.
    let callAppID: String?
    let symbol: String
    /// The installed app (icon, launch); nil when it is no longer installed.
    let appURL: URL?
    /// Meet: the page to open instead of launching the app.
    let openURL: URL?
    var isRunning: Bool
}
```

`TranslateCall/Core/Setup/CallAppMonitor.swift`:
```swift
import AppKit
import Combine
import Foundation

// MARK: - WorkspaceProviding

/// The parts of `NSWorkspace` the call-app list needs; tests use a fake.
protocol WorkspaceProviding: AnyObject {
    func urlForApplication(bundleID: String) -> URL?
    /// The app that opens https links.
    func defaultBrowserURL() -> URL?
    func bundleID(ofAppAt url: URL) -> String?
    func displayName(ofAppAt url: URL) -> String
    func runningBundleIDs() -> Set<String>
    /// Regular (Dock) apps that are running, for "Other app…".
    func runningRegularApps() -> [(bundleID: String, name: String)]
    func openApplication(at url: URL) async throws
    func open(_ url: URL)
    /// Fires after any app launches or quits.
    var changes: AsyncStream<Void> { get }
}

// MARK: - CallAppMonitor

/// The installed call apps with their live running state (REQ-UI-02…04, design §6). Uses no
/// ScreenCaptureKit, so listing needs no screen-recording permission.
@MainActor
final class CallAppMonitor: ObservableObject {
    @Published private(set) var rows: [CallAppRow] = []
    @Published private(set) var runningBundleIDs: Set<String> = []

    private let workspace: any WorkspaceProviding
    /// A persisted choice outside the catalog ("Other app…"): kept as a row.
    private var extraBundleID: String?
    private var observation: Task<Void, Never>?

    init(workspace: any WorkspaceProviding, selectedBundleID: String? = nil) {
        self.workspace = workspace
        extraBundleID = selectedBundleID
        refresh()
        let changes = workspace.changes
        observation = Task { [weak self] in
            for await _ in changes { self?.refresh() }
        }
    }

    deinit { observation?.cancel() }

    /// Rebuilds the rows from what is installed and running now.
    func refresh() {
        runningBundleIDs = workspace.runningBundleIDs()
        var result = CallApp.catalog.compactMap(row(for:))
        if let extra = extraBundleID, !result.contains(where: { $0.bundleID == extra }) {
            result.append(otherRow(bundleID: extra))
        }
        rows = result
    }

    /// Keeps an "Other app…" choice visible in the list.
    func setSelected(bundleID: String?) {
        extraBundleID = bundleID
        refresh()
    }

    func runningRegularApps() -> [(bundleID: String, name: String)] {
        workspace.runningRegularApps()
    }

    /// Launches the app (Meet: opens the page in the default browser). Does not start translation.
    func open(_ row: CallAppRow) async {
        if let url = row.openURL {
            workspace.open(url)
        } else if let appURL = row.appURL {
            try? await workspace.openApplication(at: appURL)
        }
    }

    /// True once `bundleID` runs, false after `timeout` (REQ-UI-34). Polls as well as listening,
    /// so a missed launch notification cannot make it wait for the whole timeout.
    func waitUntilRunning(bundleID: String, timeout: Duration,
                          pollEvery: Duration = .milliseconds(200)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            refresh()
            if runningBundleIDs.contains(bundleID) { return true }
            try? await Task.sleep(for: pollEvery)
        }
        refresh()
        return runningBundleIDs.contains(bundleID)
    }

    // MARK: Rows

    private func row(for app: CallApp) -> CallAppRow? {
        switch app.kind {
        case .native:
            for bundleID in app.bundleIDs {
                guard let url = workspace.urlForApplication(bundleID: bundleID) else { continue }
                return CallAppRow(bundleID: bundleID, title: app.displayName, appName: app.displayName,
                                  callAppID: app.id, symbol: app.symbol, appURL: url, openURL: nil,
                                  isRunning: runningBundleIDs.contains(bundleID))
            }
            return nil
        case .browser(let page):
            guard let browser = workspace.defaultBrowserURL(),
                  let bundleID = workspace.bundleID(ofAppAt: browser) else { return nil }
            let title = "\(app.displayName) · \(workspace.displayName(ofAppAt: browser))"
            return CallAppRow(bundleID: bundleID, title: title, appName: app.displayName, callAppID: app.id,
                              symbol: app.symbol, appURL: browser, openURL: page,
                              isRunning: runningBundleIDs.contains(bundleID))
        }
    }

    private func otherRow(bundleID: String) -> CallAppRow {
        let url = workspace.urlForApplication(bundleID: bundleID)
        let name = url.map(workspace.displayName(ofAppAt:)) ?? bundleID
        return CallAppRow(bundleID: bundleID, title: name, appName: name, callAppID: nil, symbol: "app",
                          appURL: url, openURL: nil, isRunning: runningBundleIDs.contains(bundleID))
    }
}

// MARK: - LiveWorkspace

/// `NSWorkspace`-backed provider.
final class LiveWorkspace: WorkspaceProviding {
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var tokens: [NSObjectProtocol] = []

    init() {
        (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [continuation] _ in
                continuation.yield()
            })
        }
    }

    func urlForApplication(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func defaultBrowserURL() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: CallApp.meetURL)
    }

    func bundleID(ofAppAt url: URL) -> String? { Bundle(url: url)?.bundleIdentifier }

    func displayName(ofAppAt url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func runningRegularApps() -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func openApplication(at url: URL) async throws {
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
```

`SetupManager.swift`:
- add, below `selectedCaptureApp`:
  ```swift
      /// The persisted call app (`tlk.captureApp.bundleID`); nil = "None — translate only my voice".
      /// Set by both setters; works for an app that is not running (M9 UI core REQ-UI-80b).
      @Published private(set) var selectedCaptureBundleID: String?
  ```
- in `init`, after `isSetupCompleted`, add:
  ```swift
          let saved = defaults.string(forKey: Self.captureAppBundleKey) ?? ""
          selectedCaptureBundleID = saved.isEmpty ? nil : saved
  ```
- replace `selectCaptureApp(_:)`, and add the bundle-ID setter:
  ```swift
      /// Selects and persists the capture app (nil = "None / outgoing only").
      func selectCaptureApp(_ app: SCRunningApplication?) {
          selectedCaptureApp = app
          selectCaptureApp(bundleID: app?.bundleIdentifier)
      }

      /// Selects and persists the capture app by bundle ID, running or not (nil = "None").
      /// Persists before publishing, so observers of `selectedCaptureBundleID` read the new target.
      func selectCaptureApp(bundleID: String?) {
          let id = bundleID?.isEmpty == false ? bundleID : nil
          defaults.set(id ?? "", forKey: Self.captureAppBundleKey)
          if selectedCaptureApp?.bundleIdentifier != id {
              selectedCaptureApp = availableCaptureApps.first { $0.bundleIdentifier == id }
          }
          selectedCaptureBundleID = id
      }
  ```

`AudioViewModel.bindSetupManager()` observes `setupManager.$selectedCaptureBundleID` instead of `$selectedCaptureApp` (keep `.dropFirst()` and `.receive(on: DispatchQueue.main)`). It gets a new comment:
```swift
        // Every selection (running or not) publishes the bundle ID after persisting it; the hop to
        // the next main-queue turn keeps `captureTarget` reads after the publisher's willSet.
```
The file stays at 399 lines.

`AppContainer.swift`: `UIServices` gains `let callAppMonitor: CallAppMonitor`, initialised as:
```swift
        callAppMonitor = CallAppMonitor(workspace: LiveWorkspace(),
                                        selectedBundleID: viewModel.setupManager.selectedCaptureBundleID)
```

- [ ] **Step 4: Run, lint**

Run: `just test-only CallAppMonitorTests SetupManagerTests SetupManagerBundleSelectionTests AudioViewModelTests AudioViewModelCallAppSelectionTests && just lint`
Expected: PASS, no lint output.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Setup TranslateCall/Features/Main/AudioViewModel.swift TranslateCall/App/AppContainer.swift \
  TranslateCallTests/Mocks/FakeWorkspace.swift TranslateCallTests/CallAppMonitorTests.swift \
  TranslateCallTests/SetupManagerTests.swift TranslateCallTests/AudioViewModelTests.swift
git commit -m "feat(setup): installed call apps with live state; select a call app by bundle ID (M9 UI core T11)"
```

---

### Task 12: Permissions, pair readiness, `Readiness`, language order (sonnet)

**Files:**
- Create: `TranslateCall/Core/Setup/Permissions.swift`, `TranslateCall/Features/Main/Readiness.swift`, `TranslateCall/Features/Main/LanguageOrdering.swift`
- Test: `TranslateCallTests/ReadinessTests.swift`; add the ordering tests to `TranslateCallTests/UICopyTests.swift`

**Interfaces:**
- Consumes: `CallAppRow` (Task 11), `SessionPhase` (Task 10).
- Produces:
  - `PermissionStatus`;
  - `PermissionState`, with `current()`, `allGranted`, `microphoneSettingsURL` and `screenRecordingSettingsURL`;
  - `PairReadiness`, with `derive(outgoingInstalled:incomingInstalled:unsupported:sourceName:targetName:)`;
  - `Readiness`:
    - `primary`, `primaryEnabled`, `cards`;
    - `derive(permissions:blackHolePresent:pair:app:phase:)`, `cards(permissions:blackHolePresent:app:)`;
    - `Primary.title`;
  - `LanguageOrdering.ordered(_:displayName:) -> (priority:, others:)`.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/ReadinessTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

private func row(running: Bool, installed: Bool = true) -> CallAppRow {
    CallAppRow(bundleID: "us.zoom.xos", title: "Zoom", appName: "Zoom", callAppID: "zoom", symbol: "video.fill",
               appURL: installed ? URL(fileURLWithPath: "/Applications/zoom.us.app") : nil, openURL: nil,
               isRunning: running)
}

private func derive(_ permissions: PermissionState = .allGranted, blackHole: Bool = true,
                    pair: PairReadiness = .ready, app: CallAppRow? = row(running: true),
                    phase: SessionPhase = .idle) -> Readiness {
    Readiness.derive(permissions: permissions, blackHolePresent: blackHole, pair: pair, app: app, phase: phase)
}

@Suite("Readiness (M9 UI core REQ-UI-33)")
struct ReadinessTests {

    @Test("everything ready → Start, no cards")
    func ready() {
        #expect(derive() == Readiness(primary: .start, primaryEnabled: true, cards: []))
        #expect(Readiness.Primary.start.title == "Start translating")
    }

    @Test("microphone denied → card at the top and Start disabled (REQ-UI-32/33)")
    func micDenied() {
        let result = derive(PermissionState(microphone: .denied, screenRecording: .granted))
        #expect(result.cards == [.microphoneOff])
        #expect(!result.primaryEnabled)
    }

    @Test("microphone not asked yet does not block: the system asks at Start")
    func micNotDetermined() {
        #expect(derive(PermissionState(microphone: .notDetermined, screenRecording: .granted)).primaryEnabled)
    }

    @Test("screen recording denied → card only, Start still works; no card when no call app is chosen")
    func screenDenied() {
        let denied = PermissionState(microphone: .granted, screenRecording: .denied)
        let result = derive(denied)
        #expect(result.cards == [.screenRecordingOff])
        #expect(result.primaryEnabled)
        #expect(derive(denied, app: nil).cards.isEmpty)
    }

    @Test("BlackHole missing → audio driver card, Start not blocked (REQ-UI-32a)")
    func blackHoleMissing() {
        let result = derive(blackHole: false)
        #expect(result.cards == [.audioDriverMissing])
        #expect(result.primary == .start && result.primaryEnabled)
    }

    @Test("a pack missing → Download <language> to start, disabled (REQ-UI-30)")
    func packMissing() {
        let result = derive(pair: .missing(language: "Deutsch"))
        #expect(result.primary == .download("Deutsch"))
        #expect(!result.primaryEnabled)
        #expect(result.primary.title == "Download Deutsch to start")
    }

    @Test("app installed but not running → card + Open <App> and start (REQ-UI-31)")
    func appNotOpen() {
        let result = derive(app: row(running: false))
        #expect(result.cards == [.callAppNotOpen("Zoom")])
        #expect(result.primary == .openAppAndStart("Zoom") && result.primaryEnabled)
        #expect(result.primary.title == "Open Zoom and start")
    }

    @Test("a chosen app that is no longer installed → plain Start (incoming will show Can't hear)")
    func appUninstalled() {
        #expect(derive(app: row(running: false, installed: false)).primary == .start)
    }

    @Test("session running → Stop; starting → disabled")
    func phases() {
        #expect(derive(phase: .running) == Readiness(primary: .stop, primaryEnabled: true, cards: []))
        #expect(derive(phase: .starting).primaryEnabled == false)
    }

    @Test("pair per direction: outgoing missing names the target, incoming the source; unsupported wins")
    func pairReadiness() {
        let both = PairReadiness.derive(outgoingInstalled: false, incomingInstalled: false, unsupported: false,
                                        sourceName: "Español", targetName: "Deutsch")
        let reverse = PairReadiness.derive(outgoingInstalled: true, incomingInstalled: false, unsupported: false,
                                           sourceName: "Español", targetName: "Deutsch")
        #expect(both == .missing(language: "Deutsch"))
        #expect(reverse == .missing(language: "Español"))
        #expect(PairReadiness.derive(outgoingInstalled: false, incomingInstalled: false, unsupported: true,
                                     sourceName: "", targetName: "") == .unsupported)
    }
}
```

Add to `UICopyTests` (inside the `UICopyTests` struct):
```swift
    @Test("pickers list Español, English, Deutsch first, then the rest by name (REQ-UI-06)")
    func languageOrdering() {
        let supported = ["uk", "de", "fr", "en", "es", "ja"].map { Locale.Language(identifier: $0) }
        let names = ["uk": "Ukrainian", "de": "German", "fr": "French", "en": "English", "es": "Spanish", "ja": "Japanese"]
        let result = LanguageOrdering.ordered(supported) { names[$0.languageCode?.identifier ?? ""] ?? "" }
        #expect(result.priority.map(\.minimalIdentifier) == ["es", "en", "de"])
        #expect(result.others.map(\.minimalIdentifier) == ["fr", "ja", "uk"])
    }

    @Test("no priority language supported → an empty first group")
    func noPriority() {
        let result = LanguageOrdering.ordered([Locale.Language(identifier: "fr")]) { _ in "French" }
        #expect(result.priority.isEmpty)
        #expect(result.others.count == 1)
    }
```

- [ ] **Step 2: Run, expect failure**

Run: `just test-only ReadinessTests UICopyTests`
Expected: FAIL (types undefined).

- [ ] **Step 3: Implement**

`TranslateCall/Core/Setup/Permissions.swift`:
```swift
import AVFoundation
import CoreGraphics
import Foundation

nonisolated enum PermissionStatus: Sendable, Equatable {
    case granted, denied, notDetermined
}

/// Microphone and Screen & System Audio Recording, re-read when the app becomes active (REQ-UI-32).
nonisolated struct PermissionState: Sendable, Equatable {
    var microphone: PermissionStatus
    var screenRecording: PermissionStatus

    static let allGranted = PermissionState(microphone: .granted, screenRecording: .granted)

    /// The system's answer now. Screen recording cannot report "not asked yet": not granted = denied.
    static func current() -> PermissionState {
        let mic: PermissionStatus = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        return PermissionState(microphone: mic, screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .denied)
    }

    static let microphoneSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let screenRecordingSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}
```

`TranslateCall/Features/Main/Readiness.swift`:
```swift
import Foundation

// MARK: - PairReadiness

/// The language pair, checked per direction like `AudioCoordinator.start` (REQ-UI-33).
nonisolated enum PairReadiness: Sendable, Equatable {
    case checking
    case ready
    /// A pack is missing; the display name of the language to download.
    case missing(language: String)
    case unsupported

    /// `outgoingInstalled` = source → target; a missing outgoing pack names the target language,
    /// a missing incoming one the source language (the target when both are missing).
    static func derive(outgoingInstalled: Bool, incomingInstalled: Bool, unsupported: Bool,
                       sourceName: String, targetName: String) -> PairReadiness {
        if unsupported { return .unsupported }
        if !outgoingInstalled { return .missing(language: targetName) }
        if !incomingInstalled { return .missing(language: sourceName) }
        return .ready
    }
}

// MARK: - Readiness

/// The setup window's primary button and pre-call cards (REQ-UI-08, 30…33, design §5.4).
nonisolated struct Readiness: Sendable, Equatable {
    enum Primary: Sendable, Equatable {
        case start
        case openAppAndStart(String)
        case download(String)
        case unsupportedPair
        case checking
        case starting
        case stop
    }

    /// In display order: permission cards at the top, the rest under the call-app list.
    enum Card: Sendable, Equatable {
        case microphoneOff
        case screenRecordingOff
        case audioDriverMissing
        case callAppNotOpen(String)
    }

    var primary: Primary
    var primaryEnabled: Bool
    var cards: [Card]

    static func derive(permissions: PermissionState, blackHolePresent: Bool, pair: PairReadiness,
                       app: CallAppRow?, phase: SessionPhase) -> Readiness {
        switch phase {
        case .running: return Readiness(primary: .stop, primaryEnabled: true, cards: [])
        case .starting: return Readiness(primary: .starting, primaryEnabled: false, cards: [])
        case .idle: break
        }
        let cards = cards(permissions: permissions, blackHolePresent: blackHolePresent, app: app)
        let micOK = permissions.microphone != .denied
        switch pair {
        case .missing(let language): return Readiness(primary: .download(language), primaryEnabled: false, cards: cards)
        case .unsupported: return Readiness(primary: .unsupportedPair, primaryEnabled: false, cards: cards)
        case .checking: return Readiness(primary: .checking, primaryEnabled: false, cards: cards)
        case .ready: break
        }
        if let app, !app.isRunning, app.appURL != nil {
            return Readiness(primary: .openAppAndStart(app.appName), primaryEnabled: micOK, cards: cards)
        }
        return Readiness(primary: .start, primaryEnabled: micOK, cards: cards)
    }
}

nonisolated extension Readiness {
    static func cards(permissions: PermissionState, blackHolePresent: Bool, app: CallAppRow?) -> [Card] {
        var cards: [Card] = []
        if permissions.microphone == .denied { cards.append(.microphoneOff) }
        // Only incoming needs screen recording: no card when no call app is chosen.
        if app != nil, permissions.screenRecording == .denied { cards.append(.screenRecordingOff) }
        if !blackHolePresent { cards.append(.audioDriverMissing) }
        if let app, !app.isRunning, app.appURL != nil { cards.append(.callAppNotOpen(app.appName)) }
        return cards
    }
}

nonisolated extension Readiness.Primary {
    /// The button's title (REQ-UI-08).
    var title: String {
        switch self {
        case .start: String(localized: "Start translating")
        case .openAppAndStart(let app): String(localized: "Open \(app) and start")
        case .download(let language): String(localized: "Download \(language) to start")
        case .unsupportedPair: String(localized: "This pair isn't available")
        case .checking: String(localized: "Checking languages…")
        case .starting: String(localized: "Starting…")
        case .stop: String(localized: "Stop translating")
        }
    }
}
```

`TranslateCall/Features/Main/LanguageOrdering.swift`:
```swift
import Foundation

/// The language pickers' order (REQ-UI-06): Español, English, Deutsch first, then the rest by
/// display name. `priority` is empty when none of them is supported.
nonisolated enum LanguageOrdering {
    static let priorityCodes = ["es", "en", "de"]

    static func ordered(_ supported: [Locale.Language], displayName: (Locale.Language) -> String)
        -> (priority: [Locale.Language], others: [Locale.Language]) {
        let priority = priorityCodes.compactMap { code in
            supported.first { $0.languageCode?.identifier == code }
        }
        let others = supported.filter { !priority.contains($0) }
            .sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
        return (priority, others)
    }
}
```

- [ ] **Step 4: Run, lint**

Run: `just test-only ReadinessTests UICopyTests && just lint`
Expected: PASS, no lint output.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Setup/Permissions.swift TranslateCall/Features/Main/Readiness.swift \
  TranslateCall/Features/Main/LanguageOrdering.swift TranslateCallTests/ReadinessTests.swift TranslateCallTests/UICopyTests.swift
git commit -m "feat(ui): readiness rule for the primary button and pre-call cards; language order (M9 UI core T12)"
```

---

### Task 13: `CallSessionModel`, `LatencyProvider`, UI setting keys (opus)

**Files:**
- Create: `TranslateCall/Core/Session/LatencyProvider.swift`, `TranslateCall/Features/Session/CallSessionModel.swift`, `TranslateCall/Features/Settings/UISettingsKeys.swift`
- Modify: `TranslateCall/App/AppContainer.swift` (`UIServices.callSession`)
- Test: `TranslateCallTests/CallSessionModelTests.swift`

**Interfaces:**
- Consumes: Tasks 8–12.
- Produces:
  - `protocol LatencyProvider`, with `NoLatencyProvider` and `Duration.latencyLabel`;
  - `@MainActor final class CallSessionModel`:
    - published state: `phase`, `outgoing`, `incoming`, `incomingStatus`, `title`, `isPaused`, `transcript`, `sessionStartedAt`, `notices`, `panelNotice`;
    - properties: `coordinator`, `viewModel`, `latency`;
    - actions: `togglePause() async`, `stop() async`, `skipNextSentence()`, `start(launching:monitor:timeout:) async`;
    - helpers: `static elapsedText(from:to:)`, `static composeNotices(listeningMode:transient:)`;
  - `UISettingsKeys.showStatusPanel = "ui.showStatusPanel"` and `showLatency = "ui.showLatency"`;
  - `UIServices.callSession`.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/CallSessionModelTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

/// A CallSessionModel over a mock-backed coordinator and view model (no hardware, no models).
@MainActor
private struct SessionHarness {
    let mocks = CoordinatorMocks()
    let coordinator: AudioCoordinator
    let viewModel: AudioViewModel
    let session: CallSessionModel
    let clock = TestClock()

    init(packsInstalled: Bool = true) {
        let mocks = self.mocks
        coordinator = AudioCoordinator(
            audioCapture: mocks.mockAudioCapture, systemCapture: mocks.mockSystemCapture,
            outgoingVADFactory: { mocks.mockVADFactory }, incomingVADFactory: { mocks.mockIncomingVAD },
            outgoingSTTFactory: { _ in mocks.mockOutgoingSTT }, incomingSTTFactory: { _ in mocks.mockIncomingSTT },
            outgoingTranslationService: mocks.mockOutgoingTranslation,
            incomingTranslationService: mocks.mockIncomingTranslation,
            outgoingTTSFactory: { _, _ in mocks.mockOutgoingTTS }, incomingTTSFactory: { _, _ in mocks.mockIncomingTTS },
            languagePairManager: mocks.languagePairManager,
            echoGateClock: TestClock(), noticeClock: TestClock(),
            isTranslationPairInstalled: { _, _ in packsInstalled }
        )
        let audioManager = AudioManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                                        configure: { _, _ in })
        viewModel = AudioViewModel(
            coordinator: coordinator, audioManager: audioManager, languagePairManager: mocks.languagePairManager,
            setupManager: SetupManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!),
            conversationSettings: ConversationSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        )
        session = CallSessionModel(coordinator: coordinator, viewModel: viewModel, clock: clock)
    }
}

@Suite("CallSessionModel (M9 UI core)", .serialized) @MainActor
struct CallSessionModelTests {

    @Test("phase, direction states and the title follow the coordinator")
    func derivesFromCoordinator() async {
        let harness = SessionHarness()
        await harness.coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { harness.session.phase == .running })
        #expect(harness.session.title == .translating)
        #expect(harness.session.sessionStartedAt != nil)

        await harness.mocks.mockIncomingVAD.injectVADState(true)
        #expect(await waitUntil { harness.session.incoming == .hearing })

        await harness.session.togglePause()
        #expect(await waitUntil { harness.session.outgoing == .paused && harness.session.title == .paused })
        await harness.session.togglePause()
        #expect(await waitUntil { !harness.session.isPaused })

        await harness.session.stop()
        #expect(await waitUntil { harness.session.phase == .idle })
    }

    @Test("a stopped capture makes the title Partly working")
    func partlyWorking() async {
        let harness = SessionHarness()
        await harness.mocks.mockSystemCapture.setThrowOnActivate(
            SystemAudioCaptureError.targetNotFound(bundleID: "com.test.call"))
        await harness.coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { harness.session.title == .partlyWorking })
        #expect(harness.session.incoming == .unavailable(.targetNotFound(bundleID: "com.test.call")))
        await harness.session.stop()
    }

    @Test("an alert raised mid-call becomes an 8 s notice, never a modal (REQ-UI-82)")
    func midCallAlertBecomesNotice() async {
        let harness = SessionHarness()
        await harness.coordinator.start()
        #expect(await waitUntil { harness.session.phase == .running })

        harness.coordinator.errorAlert = AlertItem(title: "Error", message: "Something broke", action: nil)
        #expect(await waitUntil { harness.session.panelNotice == "Something broke" })
        #expect(harness.viewModel.errorAlert == nil)
        #expect(harness.session.notices == ["Something broke"])

        #expect(await waitUntil { harness.clock.sleeperCount > 0 })
        harness.clock.advance(by: .seconds(8))
        #expect(await waitUntil { harness.session.panelNotice == nil })
        #expect(harness.session.notices.isEmpty)
        await harness.session.stop()
    }

    @Test("an alert from a start that does not go active stays an alert (REQ-UI-36)")
    func failedStartKeepsAlert() async {
        let harness = SessionHarness(packsInstalled: false)
        await harness.coordinator.start()
        #expect(harness.viewModel.errorAlert?.title == "Languages Not Downloaded")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.viewModel.errorAlert != nil)
        #expect(harness.session.panelNotice == nil)
    }

    @Test("Review focus: an error raised while starting, by a session that goes active, is a notice (REQ-UI-36)")
    func startErrorOfActiveSessionIsNotice() async {
        let harness = SessionHarness()
        await harness.mocks.mockOutgoingSTT.setThrowOnActivate(CocoaError(.featureUnsupported))   // STT fails, session goes on
        await harness.coordinator.start()
        #expect(harness.coordinator.isOutgoingActive)
        #expect(await waitUntil { harness.session.panelNotice != nil })
        #expect(harness.viewModel.errorAlert == nil)
        await harness.session.stop()
    }

    @Test("Review focus: the call app never launches → the session starts anyway after the timeout")
    func startAfterLaunchTimeout() async {
        let harness = SessionHarness()
        let workspace = FakeWorkspace()
        workspace.installed = ["us.zoom.xos": "zoom.us"]
        let monitor = CallAppMonitor(workspace: workspace)
        await harness.session.start(launching: monitor.rows[0], monitor: monitor, timeout: .milliseconds(100))
        #expect(workspace.openedApps.count == 1)
        #expect(harness.coordinator.isOutgoingActive)
        await harness.session.stop()
    }

    @Test("speakers mode adds the standing line first")
    func speakersLine() {
        let lines = CallSessionModel.composeNotices(listeningMode: .speakers, transient: "1 sentence skipped")
        #expect(lines == ["Your mic pauses while their translation plays (speakers on)", "1 sentence skipped"])
        #expect(CallSessionModel.composeNotices(listeningMode: .headphones, transient: nil).isEmpty)
    }

    @Test("elapsed time is mm:ss, h:mm:ss past an hour")
    func elapsed() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(CallSessionModel.elapsedText(from: start, to: start.addingTimeInterval(724)) == "12:04")
        #expect(CallSessionModel.elapsedText(from: start, to: start.addingTimeInterval(3_725)) == "1:02:05")
    }

    @Test("Start with the call app closed opens it, waits until it runs, then starts (REQ-UI-34)")
    func startLaunchesApp() async {
        let harness = SessionHarness()
        let workspace = FakeWorkspace()
        workspace.installed = ["us.zoom.xos": "zoom.us"]
        let monitor = CallAppMonitor(workspace: workspace)
        let zoom = monitor.rows[0]
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            workspace.setRunning("us.zoom.xos", true)
        }
        await harness.session.start(launching: zoom, monitor: monitor, timeout: .seconds(2))
        #expect(workspace.openedApps.count == 1)
        #expect(harness.coordinator.isOutgoingActive)
        await harness.session.stop()
    }

    @Test("the latency label is hidden in production: the provider has nothing")
    func noLatency() {
        let provider = NoLatencyProvider()
        #expect(!provider.canProvide)
        #expect(provider.latestLatency(for: .outgoing) == nil)
        #expect(Duration.milliseconds(900).latencyLabel == "0.9 s")
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `just test-only CallSessionModelTests`
Expected: FAIL (types undefined).

- [ ] **Step 3: Implement**

`TranslateCall/Core/Session/LatencyProvider.swift`:
```swift
import Foundation

/// End of speech → first audio, per direction, for the panel's latency label (REQ-UI-46, D-3).
protocol LatencyProvider: AnyObject, Sendable {
    /// Latest latency for `direction`, or nil when unknown.
    func latestLatency(for direction: TranscriptDirection) -> Duration?
    /// false → the label and the "Show latency in the panel" setting are hidden.
    var canProvide: Bool { get }
}

/// Production until the latency thread's trace sink is on `main` (design §4.4).
final class NoLatencyProvider: LatencyProvider {
    nonisolated func latestLatency(for direction: TranscriptDirection) -> Duration? { nil }
    nonisolated var canProvide: Bool { false }
}

extension Duration {
    /// "0.9 s" for the panel.
    nonisolated var latencyLabel: String {
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.1f s", seconds)
    }
}
```

`TranslateCall/Features/Session/CallSessionModel.swift`:
```swift
import Combine
import Foundation

// MARK: - CallSessionModel

/// In-call state for the status panel and the menu bar popover (M9 UI core REQ-UI-40…52, 60).
///
/// Derived from `AudioCoordinator`'s published state on the next main-queue turn after each
/// change. Kept apart from `AudioViewModel`, which is at its file-length limit.
@MainActor
final class CallSessionModel: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var outgoing: DirectionState = .listening
    @Published private(set) var incoming: DirectionState = .listening
    @Published private(set) var incomingStatus: IncomingStatus = .idle
    @Published private(set) var title: PanelTitle = .translating
    @Published private(set) var isPaused = false
    @Published private(set) var transcript: [TranscriptEntry] = []
    @Published private(set) var sessionStartedAt: Date?
    /// Up to two lines under the direction rows (REQ-UI-45).
    @Published private(set) var notices: [String] = []
    /// A mid-call error shown as a notice instead of an alert (REQ-UI-36/82).
    @Published private(set) var panelNotice: String?

    let coordinator: AudioCoordinator
    let viewModel: AudioViewModel
    let latency: any LatencyProvider
    private let noticeDuration: Duration
    private let clock: any Clock<Duration>
    private var noticeTask: Task<Void, Never>?
    /// Which transient notice is newest: the TTS line or the panel notice.
    private var newestTransient: String?
    private var cancellables: Set<AnyCancellable> = []

    init(coordinator: AudioCoordinator, viewModel: AudioViewModel, latency: any LatencyProvider = NoLatencyProvider(),
         noticeDuration: Duration = .seconds(8), clock: any Clock<Duration> = ContinuousClock()) {
        self.coordinator = coordinator
        self.viewModel = viewModel
        self.latency = latency
        self.noticeDuration = noticeDuration
        self.clock = clock
        coordinator.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        viewModel.conversationSettings.$listeningMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        viewModel.$errorAlert
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] alert in self?.routeMidCallAlert(alert) }
            .store(in: &cancellables)
        recompute()
    }

    // MARK: Actions

    func togglePause() async {
        if coordinator.isPaused { coordinator.resume() } else { await coordinator.pause() }
    }

    func stop() async {
        guard coordinator.isOutgoingActive || coordinator.isStarting else { return }
        await coordinator.stop()
    }

    /// "Skip my next sentence" (was Mute Turn, REQ-UI-80a).
    func skipNextSentence() { viewModel.muteTurn() }

    /// Start, launching the call app first when it is installed but not running (REQ-UI-34).
    /// After at most `timeout` the session starts anyway; incoming then shows "Can't hear".
    func start(launching app: CallAppRow?, monitor: CallAppMonitor, timeout: Duration = .seconds(15)) async {
        guard !coordinator.isOutgoingActive, !coordinator.isStarting else { return }
        if let app, !app.isRunning, app.appURL != nil {
            await monitor.open(app)
            _ = await monitor.waitUntilRunning(bundleID: app.bundleID, timeout: timeout)
        }
        await viewModel.toggleCapture()
    }

    /// "mm:ss" (or "h:mm:ss") since `start`.
    nonisolated static func elapsedText(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                         : String(format: "%02d:%02d", minutes, seconds)
    }

    /// The standing speakers line first, then the newest transient notice (REQ-UI-45).
    nonisolated static func composeNotices(listeningMode: ListeningMode, transient: String?) -> [String] {
        var lines: [String] = []
        if listeningMode == .speakers {
            lines.append(String(localized: "Your mic pauses while their translation plays (speakers on)"))
        }
        if let transient { lines.append(transient) }
        return lines
    }

    // MARK: Derivation

    private func recompute() {
        let coordinator = coordinator
        phase = coordinator.isStarting ? .starting : coordinator.isOutgoingActive ? .running : .idle
        isPaused = coordinator.isPaused
        incomingStatus = coordinator.incomingStatus
        outgoing = .outgoing(paused: coordinator.isPaused, micPaused: coordinator.isMicPaused,
                             speaking: coordinator.isOutgoingSpeaking, translating: coordinator.isOutgoingTranslating,
                             speech: coordinator.isSpeechActive)
        incoming = .incoming(status: coordinator.incomingStatus, paused: coordinator.isPaused,
                             speaking: coordinator.isIncomingSpeaking, translating: coordinator.isIncomingTranslating,
                             speech: coordinator.isIncomingSpeechActive)
        title = .derive(isStarting: coordinator.isStarting, isPaused: coordinator.isPaused, incoming: incoming)
        if transcript != coordinator.transcript { transcript = coordinator.transcript }
        sessionStartedAt = coordinator.sessionStartedAt
        if let tts = coordinator.ttsNotice, tts != newestTransient, tts != panelNotice { newestTransient = tts }
        if coordinator.ttsNotice == nil, newestTransient != nil, newestTransient != panelNotice {
            newestTransient = nil
        }
        if phase == .idle { clearPanelNotice() }
        // An alert raised while starting, by a session that did go active: now a notice (REQ-UI-36).
        if phase == .running, let alert = viewModel.errorAlert {
            viewModel.errorAlert = nil
            panelNotice = alert.message
            newestTransient = alert.message
            scheduleNoticeExpiry()
        }
        notices = Self.composeNotices(listeningMode: viewModel.conversationSettings.listeningMode,
                                      transient: newestTransient)
    }

    /// An alert raised while a session runs becomes a notice, never a modal (REQ-UI-82). One raised
    /// while starting stays an alert unless the session went active (REQ-UI-36): the main window
    /// shows alerts only once `isStarting` is false.
    private func routeMidCallAlert(_ alert: AlertItem) {
        guard coordinator.isOutgoingActive, !coordinator.isStarting else { return }
        viewModel.errorAlert = nil
        showPanelNotice(alert.message)
    }

    private func showPanelNotice(_ text: String) {
        panelNotice = text
        newestTransient = text
        recompute()
        scheduleNoticeExpiry()
    }

    private func scheduleNoticeExpiry() {
        noticeTask?.cancel()
        let (clock, duration) = (clock, noticeDuration)
        noticeTask = Task { [weak self] in
            do { try await clock.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }
            self?.clearPanelNotice()
            self?.recompute()
        }
    }

    private func clearPanelNotice() {
        guard panelNotice != nil else { return }
        if newestTransient == panelNotice { newestTransient = nil }
        panelNotice = nil
    }
}
```

`TranslateCall/Features/Settings/UISettingsKeys.swift`:
```swift
import Foundation

/// `@AppStorage` keys of the M9 UI settings (REQ-UI-40, 71).
nonisolated enum UISettingsKeys {
    /// "Show the status panel" (default on).
    static let showStatusPanel = "ui.showStatusPanel"
    /// "Show latency in the panel" (default on; only offered while a latency provider can provide).
    static let showLatency = "ui.showLatency"
}
```

`AppContainer.swift`: `UIServices` gains `let callSession: CallSessionModel`, set first in its `init` with `callSession = CallSessionModel(coordinator: coordinator, viewModel: viewModel)`.

- [ ] **Step 4: Run three times, lint**

Run: `for i in 1 2 3; do just test-only CallSessionModelTests; done && just lint`
Expected: PASS in every run, no lint output.

- [ ] **Step 5: Full unit tier and scan (end of the logic tasks)**

Run: `just test && just scan`
Expected: unit tier passes and scan reports no blocking findings. `LanguagePairManagerTests.persistsTargetLanguageToUserDefaults` may flake (P16). Re-run it once; if it fails twice, stop and report.

- [ ] **Step 6: Commit**

```bash
git add TranslateCall/Core/Session/LatencyProvider.swift TranslateCall/Features/Session TranslateCall/Features/Settings/UISettingsKeys.swift \
  TranslateCall/App/AppContainer.swift TranslateCallTests/CallSessionModelTests.swift
git commit -m "feat(session): in-call model for panel and popover; mid-call alerts become notices (M9 UI core T13)"
```

---

## View tasks (14–22)

Every view task uses the same loop. These tasks were not replayed while planning.
1. **Before coding:** screenshot the named frames, light and dark, with the pencil MCP. For example, `execute` with `TakeScreenshot(["UVrO6","i9YcC"])` on `design/translatecall.pen`. Use `Get(id, {depth: 3})` when you need exact copy or spacing.
2. Build the view with system font, SF Symbols and `Theme` colours only.
3. Add `#Preview`s for every state the frames show: light, and dark via `.preferredColorScheme(.dark)`. Previews use fixtures; they never use a real coordinator start.
4. **Text-fitting check:** render each preview once with the longest strings (language "Portuguese (Brazil)", app "Microsoft Teams (work or school)") and once at the largest Dynamic Type. Nothing overflows or overlaps.
5. **Before review:** put preview screenshots next to the frame screenshots in the task report. Differences that are deliberate (system controls vs the prototype's drawings) are listed. Others are fixed.

### Task 14: Theme, shared components, String Catalog (sonnet)

**Files:**
- Create:
  - `TranslateCall/UI/Theme.swift`;
  - `TranslateCall/UI/Chip.swift`, `TranslateCall/UI/SectionHeader.swift`, `TranslateCall/UI/CardBox.swift`;
  - `TranslateCall/Resources/Localizable.xcstrings`.

**Interfaces:**
- Produces:
  - `enum Theme`:
    - `static accent = Color.accentColor`;
    - `enum Status { static green = Color.green, orange = Color.orange, red = Color.red, purple = Color.purple }`;
    - `static func soft(_ color: Color) -> Color` (15 % opacity);
    - `enum Radius { static small: CGFloat = 6, medium = 8, large = 12 }`;
    - `enum Spacing { static small: CGFloat = 8, medium = 12, large = 16 }`;
  - `struct Chip: View`, `init(_ text: String, systemImage: String, tint: Color)`: a capsule on `Theme.soft(tint)`, caption font, `.lineLimit(1)`;
  - `struct SectionHeader: View`, `init(_ title: LocalizedStringKey)`: subheadline, semibold, `.secondary`;
  - `struct CardBox<Content: View>: View`: a rounded `Theme.Radius.medium` box on the grouped background with a hairline separator stroke. It is the white rounded groups in the prototype.

- [ ] **Step 1:** Run `Print(GetVariables())` with the pencil MCP. Map each prototype variable to `Theme` or a system colour:
  - `accent` → accent;
  - `green`/`green-soft` → `Status.green`/`soft(.green)`;
  - `orange`, `purple` likewise;
  - `window-bg` → `windowBackgroundColor`;
  - `group-bg` → `controlBackgroundColor`;
  - `separator` → `separatorColor`;
  - `text-primary`/`-secondary`/`-tertiary` → `.primary`/`.secondary`/`.tertiary`;
  - `panel-bg`/`panel-stroke` → material + separator.

  Write the mapping as a doc comment at the top of `Theme.swift`.
- [ ] **Step 2:** Implement the four files, plus a `#Preview("Components")` showing:
  - each `Chip` tint used in the frames ("Speaking" blue, "Listening" green, "Mic paused" grey, "Can't hear Teams" orange);
  - a `SectionHeader`;
  - a `CardBox`;

  in light and dark.
- [ ] **Step 3:** Create `TranslateCall/Resources/Localizable.xcstrings` containing `{"sourceLanguage" : "en", "strings" : {}, "version" : "1.0"}`. Run `just build`; Xcode fills it on build. Commit the file as the build leaves it.
- [ ] **Step 4:** Run `just build && just lint`. Expected: Build Succeeded, no lint output.
- [ ] **Step 5: Commit**
```bash
git add TranslateCall/UI TranslateCall/Resources/Localizable.xcstrings
git commit -m "feat(ui): theme, chip, section header, card box and the String Catalog (M9 UI core T14)"
```

---

### Task 15: `MainSetupModel`, the Call app section and the state cards (sonnet)

**Files:**
- Create: `TranslateCall/Features/Main/MainSetupModel.swift`, `TranslateCall/Features/Main/CallAppSection.swift`, `TranslateCall/Features/Main/StateCards.swift`
- Test: `TranslateCallTests/MainSetupModelTests.swift`

**Frames:**
- Main Window — Setup: `UVrO6` / `i9YcC`;
- State — Call app not open: `FvpIr` / `YELE8`;
- State — Permission missing: `oKwZz` / `yVagH`.

**Interfaces:**
- Consumes: `CallAppMonitor`, `SetupManager`, `LanguagePairManager`, `CallSessionModel`, `PermissionState`, `PairReadiness`, `Readiness`.
- Produces: `@MainActor final class MainSetupModel: ObservableObject`:
  - `init(monitor:setupManager:languagePairManager:session:isInstalled:permissions:)`:
    - `isInstalled: (Locale.Language, Locale.Language) async -> Bool = AppleTranslationService.isInstalled`;
    - `permissions: () -> PermissionState = PermissionState.current`;
  - `@Published` `permissions`, `pair: PairReadiness`, `readiness: Readiness`;
  - computed `selectedRow: CallAppRow?`, from the monitor's rows by `setupManager.selectedCaptureBundleID`;
  - `select(_ row: CallAppRow)`, `selectOther(bundleID: String?)` (nil = None), `open(_ row:) async`;
  - `refresh() async`, which re-reads permissions and BlackHole (`setupManager.checkBlackHole()`) and re-checks the pair per direction;
  - `primaryAction() async`:
    - `.start` / `.openAppAndStart` → `session.start(launching: selectedRow, monitor:)`;
    - `.stop` → `session.stop()`;
    - otherwise nothing.

  Readiness is recomputed on every change of the monitor rows, the session phase, the pair or the permissions (Combine `objectWillChange` of those objects, received on the main queue). `MainSetupView` calls `refresh()` on appear, on `NSApplication.didBecomeActiveNotification` and when the language pair changes.

- [ ] **Step 1: Write failing tests** in `TranslateCallTests/MainSetupModelTests.swift`. Use `FakeWorkspace` (Zoom installed, not running), a `SetupManager` on a test suite, `LanguagePairManager(defaults:languageLoader: { [] })`, and a `CallSessionModel` built like `CallSessionModelTests`' `SessionHarness`. Test names and assertions:
  - `selectWritesThroughToSetupManager`: `model.select(zoomRow)` sets `setupManager.selectedCaptureBundleID == "us.zoom.xos"`, and `model.selectedRow?.title == "Zoom"`.
  - `selectOtherNoneClearsTarget`: `model.selectOther(bundleID: nil)` sets `setupManager.captureTarget == nil`.
  - `pairCheckedPerDirection`: with `isInstalled` returning `true` only for (source → target), `await model.refresh()` gives `model.pair == .missing(language: <source display name>)` and `model.readiness.primary == .download(<source display name>)`.
  - `openAppAndStartWhenNotRunning`: with Zoom selected and both packs installed, `model.readiness.primary == .openAppAndStart("Zoom")`.
  - `deniedMicBlocksStart`: with `permissions: { PermissionState(microphone: .denied, screenRecording: .granted) }`, after `refresh()`, `readiness.cards.first == .microphoneOff` and `!readiness.primaryEnabled`.
- [ ] **Step 2:** Run `just test-only MainSetupModelTests`. Expected: FAIL (undefined).
- [ ] **Step 3:** Implement `MainSetupModel`. Then run `just test-only MainSetupModelTests`. Expected: PASS.
- [ ] **Step 4: `CallAppSection`** (frame rows "Call app"):
  - a `SectionHeader("Call app")`;
  - a `CardBox` with one row per `monitor.rows`:
    - the app icon: `NSWorkspace.shared.icon(forFile: row.appURL.path)` at 24 pt, else `Image(systemName: row.symbol)`;
    - the title, `.lineLimit(1)`;
    - a status line with a coloured dot: "Running" green, or "Not open" secondary;
    - a trailing "Open" button (`.bordered`, `.controlSize(.small)`) when not running;
    - a trailing `checkmark` when selected;
    - the selected row's background is `Theme.soft(Theme.accent)`;
  - a last row, "+ Other app…": a `Menu` listing `monitor.runningRegularApps()`, a divider, and "None — translate only my voice".

  Rows are buttons calling `model.select`. VoiceOver labels read "Zoom, not open, selected".
- [ ] **Step 5: `StateCards`** (copy from REQ-UI-31/32/32a):
  - `PermissionCard(kind: .microphone | .screenRecording)`:
    - a red card;
    - title "Your microphone is off for TranslateCall", or "They can't be heard";
    - the body copy from REQ-UI-32;
    - a link "Open System Settings" (`NSWorkspace.shared.open(PermissionState.microphoneSettingsURL / screenRecordingSettingsURL)`);
  - `CallAppNotOpenCard(appName:)`: orange; "\(app) isn't open"; "TranslateCall will open it for you when you start. Then join or start your meeting in \(app).";
  - `AudioDriverCard(onSetUp:)`: orange; "Audio driver missing"; "TranslateCall needs BlackHole 2ch to send your translated voice into the call."; a "Set up…" button.

  Cards wrap their body text.
- [ ] **Step 6:** Previews:
  - `CallAppSection` with fixture rows (Teams running and selected, Zoom not open, Meet · Chrome running, FaceTime not open);
  - each card;
  - light and dark.

  Compare with the frames (loop step 5).
- [ ] **Step 7:** Run `just build && just lint && just test-only MainSetupModelTests`. Commit:
```bash
git add TranslateCall/Features/Main/MainSetupModel.swift TranslateCall/Features/Main/CallAppSection.swift \
  TranslateCall/Features/Main/StateCards.swift TranslateCallTests/MainSetupModelTests.swift
git commit -m "feat(ui): setup model, call app list and pre-call cards (M9 UI core T15)"
```

---

### Task 16: Languages, Voice, primary button, footer; the setup window replaces `ContentView` (sonnet)

**Files:**
- Create: `TranslateCall/Features/Main/LanguageSection.swift`, `TranslateCall/Features/Main/VoiceSection.swift`, `TranslateCall/Features/Main/SetupFooter.swift`, `TranslateCall/Features/Main/MainSetupView.swift`
- Modify: `TranslateCall/App/TranslateCallApp.swift` (the `WindowGroup` hosts `MainSetupView`; the A26 `.onAppear` is kept verbatim), `TranslateCall/App/AppContainer.swift` (owns a `MainSetupModel`)

**Frames:**
- Main Window — Setup: `UVrO6` / `i9YcC`;
- State — Language not downloaded: `JjS39` / `Ik2ak`.

**Interfaces:**
- Consumes: Task 15, `SettingsOpener`, `LanguageOrdering`, `UISettingsKeys`, `TTSEngineSelector`, `VoiceProfileManager`.
- Produces: `MainSetupView`, which `TranslateCallApp`'s `WindowGroup(id: MainWindowOpener.windowID)` uses with the same environment objects, plus `.environmentObject(container.uiServices.callSession)` and `.environmentObject(container.mainSetupModel)`.

- [ ] **Step 1: `LanguageSection`:**
  - "I speak" / "They speak" `Picker`s, with sections from `LanguageOrdering.ordered(manager.supportedLanguages, displayName: manager.displayName(for:))`: the priority section, a `Divider()`, then the others. Each picker label shows a small caption over the language name;
  - a swap button (`arrow.left.arrow.right`) between them, calling `manager.swapLanguages()`;
  - the status line under them:
    - for `.ready`: a green checkmark and "Ready" on the left; on the right, "Models: Recommended" ("Models: Custom" when `!sttSelector.isAutomatic`) · a link "Advanced…" → `SettingsOpener.shared.open(tab: .advancedLegacy)`;
    - for `.missing(language)`: the download card instead. It says "\(language) needs a one-time download" and "After that it works offline". Its "Download" button sets a `TranslationSession.Configuration` for the missing direction, and the view's own `.translationTask(configuration)` calls `viewModel.downloadLanguages(using:)` (F8.5.4 REQ-TR-40), then `await model.refresh()`;
    - for `.unsupported`: "This pair isn't available";
  - the section is `.disabled` while `session.phase != .idle`.
- [ ] **Step 2: `VoiceSection`:**
  - a `CardBox` with a purple waveform icon, "Use my voice", the subtitle "They hear the translation in your own voice", and a `Toggle` bound to `ttsSelector.voiceCloningEnabled` through these actions:
    - on, with no active profile → open the voice-profile sheet;
    - on, with a profile → `ttsSelector.enableVoiceCloning()`;
    - off → `disableVoiceCloning()`;
  - when a profile is active: the line "Voice: \(profile.name) · recorded \(date, format: .dateTime.month(.abbreviated).day())" and "Record again" (opens the same sheet);
  - when `!QwenCloneConfiguration.supportsLocale(target locale)`: the toggle is disabled, with "Your voice isn't available in \(their language) yet";
  - while `ttsSelector.isVoiceCloneDownloading`: a row with a `ProgressView()` and "Downloading your voice model… (one time)".

  The sheet is today's `NavigationStack { VoiceProfileListView(isSessionActive:) }` with Done, moved from `ContentView`.
- [ ] **Step 3: `SetupFooter`:** on the left, the listening mode ("Headphones" `headphones` / "Speakers" `hifispeaker`); on the right, "Settings" `gearshape`. Both are borderless buttons calling `SettingsOpener.shared.open(tab: .general)`.
- [ ] **Step 4: `MainSetupView`:**
  - `VStack` order: permission cards (top) → `CallAppSection` → the call-app-not-open card and the audio driver card → `LanguageSection` → `VoiceSection` → the primary button → `SetupFooter`;
  - the primary button is full width, `.borderedProminent`, `.controlSize(.large)`, titled `model.readiness.primary.title`, `.disabled(!model.readiness.primaryEnabled)`, with a `play` / `stop` symbol, running `model.primaryAction()`;
  - `.frame(width: 420)`, height fitting;
  - `.toolbar { ToolbarItem(placement: .primaryAction) { Label("On-device", systemImage: "lock") … } }`, a small green mark;
  - title "TranslateCall".

  Moved from `ContentView` unchanged:
  - the `errorAlert` alert, presented through a binding that is nil while `viewModel.isStarting` (P14), with the `.openSettings` action;
  - the Edge TTS consent alert;
  - the setup-wizard sheet (opened on appear when `!setupManager.isSetupCompleted`, and from `AudioDriverCard`'s "Set up…");
  - `setupManager.checkBlackHole()` on appear and on `scenePhase == .active`.

  `model.refresh()` runs on appear and on `NSApplication.didBecomeActiveNotification`.
- [ ] **Step 5:** In `TranslateCallApp`, replace `ContentView()` with `MainSetupView()` and add the two environment objects. Keep the `.onAppear` block (A26 host `show()` → `MainWindowOpener` → `SettingsOpener` → `MenuBarController`) as it is. `AppContainer` gets `let mainSetupModel: MainSetupModel`, built after `uiServices`; if `init` goes over 50 lines, build it inside `UIServices` and expose it there.
- [ ] **Step 6:** Previews of `MainSetupView`:
  - ready;
  - language not downloaded;
  - call app not open;
  - permission missing;
  - voice clone unavailable.

  In light and dark, compared with the frames.
- [ ] **Step 7: Manual check.** Run `just build` and open the app.
  - The new window shows at launch (A26).
  - The Teams/Zoom rows show the live state.
  - "Open" launches Zoom.
  - Changing the pair re-checks it.
  - Start → the session starts. The old window is gone; the panel comes in Task 17.
- [ ] **Step 8:** Run `just lint && just test-only MainWindowOpenerTests TranslationHostWindowTests MainSetupModelTests`. Commit:
```bash
git add TranslateCall/Features/Main TranslateCall/App
git commit -m "feat(ui): new setup window with languages, voice and the readiness-driven Start (M9 UI core T16)"
```

---

### Task 17: Status panel, compact; showing and hiding it with the session (sonnet)

**Files:**
- Create: `TranslateCall/Features/StatusPanel/StatusPanelView.swift`, `TranslateCall/Features/StatusPanel/DirectionRow.swift`, `TranslateCall/Features/StatusPanel/PanelNotices.swift`
- Modify:
  - `TranslateCall/App/AppContainer.swift`: `StatusPanelController` owned by `UIServices` or a lazy property;
  - `TranslateCall/App/TranslateCallApp.swift`: remove the Task 2 DEBUG command;
  - `TranslateCall/Features/Main/MainSetupView.swift`: dismiss on start.

**Frames:**
- Status Panel — Compact: `vr2HP` / `WiCOt`;
- State — Panel: incoming audio lost: `ANfma` / `zRF0f`;
- State — Panel: speaker mode & skipped: `wMviH` / `xbv6s`;
- In Context: `BPf5j`.

**Interfaces:**
- Consumes: `CallSessionModel`, `DirectionCopy`, `Chip`, `StatusPanelController`, `UISettingsKeys`, `CallAppMonitor` (app name).
- Produces: `StatusPanelView(expanded: Binding<Bool>)` (Task 18 adds the expanded body) and `PanelPresenter` (`@MainActor`), which shows and hides the panel with `callSession.phase`.

- [ ] **Step 1: `DirectionRow`:**
  - "You" or "Them" (semibold), then "ES → DE" (secondary, from `Locale.Language.languageCode` uppercased);
  - when `session.latency.canProvide` and the setting is on, `latency.latestLatency(for:)?.latencyLabel` (tertiary, monospaced digits);
  - the `Chip` from `DirectionCopy.chip`, with these icons and tints:

    | State | Icon | Tint |
    |---|---|---|
    | speaking | `speaker.wave.2` | blue |
    | listening | `ear` | green |
    | hearing | `waveform` | green |
    | translating | `ellipsis` | blue |
    | paused | `pause` | secondary |
    | mic paused | `mic.slash` | secondary |
    | unavailable | `speaker.slash` | orange |
  - below: the last translation of that direction, from `session.transcript.last(where:)` (its `translation`, else `original`), `.lineLimit(2)`, in « » / „ “ quotes as in the frame;
  - **unavailable state:** the row's border is orange. It shows `DirectionCopy.unavailableLine`, a "Retry" link (`viewModel.retryIncoming()`) and "Choose another app…" (`NSApp.showMainWindow()`, REQ-UI-80b);
  - `IncomingStatus.disabled` shows `DirectionCopy.outgoingOnlyLine` and no chip;
  - `.accessibilityElement(children: .combine)` with `DirectionCopy.accessibilityLabel`.
- [ ] **Step 2: `PanelNotices`:** `session.notices`, each with an icon: `info.circle` for the speakers line, `forward.end` (orange) for the others. Text wraps.
- [ ] **Step 3: `StatusPanelView`:**
  - the header holds:
    - a dot coloured by `MenuBarDot.derive(phase:title:)` (green, orange, or grey when none);
    - `session.title.text` (semibold);
    - "\(appName) · \(elapsed)" (secondary), where `elapsed` comes from `TimelineView(.periodic(from: .now, by: 1))` over `CallSessionModel.elapsedText`, only while visible (NFR-UI-03);
    - a green `lock` mark (help "Everything runs on this Mac");
    - three square buttons: pause/resume (`pause` / `play`), stop (red, `stop`), expand (`chevron.down` / `chevron.up`);
  - then two `DirectionRow`s in `CardBox`es, then `PanelNotices`;
  - width 320, material background (`.background(.regularMaterial)`), corner radius 12;
  - buttons use `.buttonStyle(.plain)` with explicit hit areas, and every button has a `.help` and an accessibility label.
- [ ] **Step 4: `PanelPresenter`.** It owns a `StatusPanelController(content: NSHostingView(rootView: StatusPanelView(...)), size: fitting)`. The hosting view uses `sizingOptions = [.intrinsicContentSize]`, and the controller is resized to `hostingView.fittingSize` on each layout change.
  - It observes `session.$phase`: `.running` together with `UserDefaults.standard.bool(forKey: UISettingsKeys.showStatusPanel)` (registered default `true`) → `show()`; `.idle` → `hide()` (REQ-UI-40/47).
  - `MainSetupView` adds `.onChange(of: session.phase)`: when `.running` and the setting is on → `dismissWindow(id: MainWindowOpener.windowID)` (`@Environment(\.dismissWindow)`).
  - Stop never reopens the main window.
  - Delete `DebugStatusPanel` and the Debug menu.
- [ ] **Step 5:** Previews:
  - compact, translating (ES → DE fixtures from the frame);
  - incoming lost;
  - speakers + skipped notice;
  - paused;
  - partly working.

  In light and dark. Compare with the frames, the In Context frame included (placement).
- [ ] **Step 6: Manual check** with a real call (Teams):
  - Start → the panel appears top right and the main window closes;
  - typing in Teams' chat while the panel updates works (focus);
  - Pause, then Resume;
  - Stop → the panel hides and nothing else opens.
- [ ] **Step 7:** Run `just build && just lint`. Commit:
```bash
git add TranslateCall/Features/StatusPanel TranslateCall/App TranslateCall/Features/Main/MainSetupView.swift
git commit -m "feat(ui): compact status panel shown with the session (M9 UI core T17)"
```

---

### Task 18: Status panel, expanded — the transcript (sonnet)

**Files:**
- Create: `TranslateCall/Features/StatusPanel/TranscriptView.swift`
- Modify: `TranslateCall/Features/StatusPanel/StatusPanelView.swift`

**Frames:** Status Panel — Expanded: `DNobA` / `oU4FO`.

- [ ] **Step 1: `TranscriptView`:**
  - a `ScrollView` + `ScrollViewReader` over `session.transcript`, with one bubble per entry:
    - "Them" left-aligned, on the grouped background;
    - "You" right-aligned, on `Theme.soft(accent)`;
    - max width 250;
    - the original text (body), the translation (secondary, smaller), and a footer "Them · 12:02 · 0.8 s" (time `.dateTime.hour().minute()`; latency only when known);
    - skipped entries are dimmed with "Not translated";
  - a trailing "Translating…" capsule with three dots while `coordinator.isOutgoingTranslating || isIncomingTranslating`;
  - auto-scroll to the last id on change, unless the user scrolled up. Track that with `.onScrollGeometryChange(for: Bool.self)`: "within 24 pt of the bottom".
- [ ] **Step 2:** The expand button toggles `expanded`. Expanded, the body is `TranscriptView` (height 338, width 340) instead of the rows. `PanelPresenter` resizes the panel with `StatusPanelController.resize(to:)`, keeping the top edge.
- [ ] **Step 3:** Previews: the frame's three bubbles plus "Translating…", a skipped entry, 50 entries (scrolling). Light and dark.
- [ ] **Step 4:** Run `just build && just lint`. Commit:
```bash
git add TranslateCall/Features/StatusPanel
git commit -m "feat(ui): expanded status panel with the session transcript (M9 UI core T18)"
```

---

### Task 19: Menu bar — icon with dot, popover, right-click menu (sonnet)

**Files:**
- Create: `TranslateCall/Features/Main/AudioViewModel+Start.swift`
- Modify: `TranslateCall/Features/MenuBar/MenuBarController.swift`, `TranslateCall/Features/MenuBar/MenuBarPopoverView.swift` (rewritten), `TranslateCall/App/TranslateCallApp.swift` (the controller's init arguments)
- Test: `TranslateCallTests/MenuBarStartTests.swift`

**Frames:**
- Menu Bar — Idle: `bQKYO` / `xiVmb`;
- Menu Bar — Translating: `eBNlu` / `C2n5j8`.

**Interfaces:**
- Consumes: `CallSessionModel`, `MainSetupModel`, `MenuBarDot`, `SettingsOpener`.
- Produces:
  - `extension AudioViewModel { var needsEdgeConsentBeforeStart: Bool }`. It uses the same expression as `toggleCapture`: no system voice for the target locale and no consent given. It lives in a new file, so `AudioViewModel.swift` does not grow;
  - `nonisolated enum MenuBarStartPolicy { static func needsMainWindow(readiness: Readiness, needsEdgeConsent: Bool) -> Bool }`. It is true when `!readiness.primaryEnabled`, any card is present, or consent is needed (REQ-UI-36);
  - `MenuBarController.init(viewModel:session:setup:)`.

- [ ] **Step 1: Failing test** `TranslateCallTests/MenuBarStartTests.swift` (`@Suite("Menu bar start policy")`). Test `startNeedsWindowOnlyWhenSomethingMustBeShown`:
  - ready, no consent needed → `false`;
  - `.download("Deutsch")` → `true`;
  - cards `[.screenRecordingOff]` → `true`;
  - consent needed → `true`.

  Run `just test-only MenuBarStartTests`. Expected: FAIL.
- [ ] **Step 2:** Implement `MenuBarStartPolicy` in `MenuBarIcon.swift` and the extension. Run the test. Expected: PASS.
- [ ] **Step 3: Icon.** `MenuBarController.icon(dot: MenuBarDot) -> NSImage`:
  - the template `NSImage(systemSymbolName: MenuBarDot.symbolName)` at 15 pt;
  - for `.green`/`.orange`, draw it into a new 18×18 image with a 6 pt filled circle at the bottom-right (`NSColor.systemGreen`/`systemOrange`) and set `isTemplate = false`;
  - for `.none`, keep the template.

  Observe `session.$phase.combineLatest(session.$title)` → `updateIcon`. The accessibility description is "TranslateCall".
- [ ] **Step 4: Popover.** `MenuBarPopoverView(session:setup:viewModel:)`, width 280, height fitting (`NSHostingController.sizingOptions = .preferredContentSize`).
  - **Idle (REQ-UI-60):**
    - a grey dot and "Ready", or the first blocking reason: the primary title when it is disabled, else the first card's title;
    - "\(app) · \(my language) ↔ \(their language)";
    - the `lock` mark;
    - the primary button: when `MenuBarStartPolicy.needsMainWindow(...)`, `NSApp.showMainWindow()` then `setup.primaryAction()`; otherwise `setup.primaryAction()` directly;
    - a divider; "Open TranslateCall" (`NSApp.showMainWindow()`), "Settings…" (`SettingsOpener.shared.open(tab: .general)`), "Quit".
  - **Translating:**
    - the dot, the title and "\(app) · \(pair) · \(elapsed)";
    - two compact rows ("You  ES → DE" + chip text in its tint);
    - "Stop translating" (red tinted, full width);
    - a divider; "Show status panel" (`PanelPresenter.show()`), "Open TranslateCall", "Settings…", "Quit".
- [ ] **Step 5: Right-click menu:**
  - "Start Translation" / "Stop Translation" (unchanged rule);
  - "Pause" / "Resume", enabled only when `.running`;
  - "Skip My Next Sentence" (`session.skipNextSentence()`), enabled only when `.running`;
  - a separator; "Open Main Window"; "Settings…"; a separator; "Quit TranslateCall".
- [ ] **Step 6:** Previews of both popover states, light and dark, compared with the frames. Manual check: the dot is green while translating and orange while paused; the idle Start from the popover with a missing pack opens the main window.
- [ ] **Step 7:** Run `just build && just lint && just test-only MenuBarStartTests`. Commit:
```bash
git add TranslateCall/Features/MenuBar TranslateCall/Features/Main/AudioViewModel+Start.swift TranslateCall/App \
  TranslateCallTests/MenuBarStartTests.swift
git commit -m "feat(ui): menu bar icon with session dot, new popover and Pause/Skip items (M9 UI core T19)"
```

---

### Task 20: Settings — General (sonnet)

**Files:**
- Create: `TranslateCall/Features/Settings/GeneralSettingsView.swift`
- Modify: `TranslateCall/Features/Settings/SettingsView.swift` (the General tab)
- Test: `TranslateCallTests/GeneralSettingsTests.swift`

**Frames:** Settings — General: `XjnNV` / `m9CFL`.

**Interfaces:**
- Consumes: `ConversationSettings` (`listeningMode`, `pauseSeconds`, `pauseRange`, `pauseStep`), `AudioViewModel` (devices, `selectInput`, `selectOutput`), `CallSessionModel.latency`, `UISettingsKeys`.
- Produces:
  - `GeneralSettingsView`;
  - `nonisolated static func pauseValueLabel(_ seconds: Double) -> String`, giving "0.6 s pause";
  - `nonisolated enum DownloadedLanguages { static func list(source:supported:displayName:isInstalled:) async -> [String] }`. It returns the source's name plus every supported language `L` with `isInstalled(source, L)`, sorted (P17).

- [ ] **Step 1: Failing tests** `TranslateCallTests/GeneralSettingsTests.swift`:
  - `pauseLabel`: `GeneralSettingsView.pauseValueLabel(0.6) == "0.6 s pause"`, `(1.2) == "1.2 s pause"`;
  - `downloadedLanguages`: source `es`, supported `[de, en, fr]`, with `isInstalled` true for `de` and `en` → `["Deutsch", "English", "Español"]`, using a `displayName` closure that returns those names.

  Run `just test-only GeneralSettingsTests`. Expected: FAIL.
- [ ] **Step 2:** Implement the two helpers. Run the tests. Expected: PASS.
- [ ] **Step 3: View** (a `Form` with `.formStyle(.grouped)`, matching the frame):
  - **Audio:**
    - "I listen with": a segmented `Picker` (Headphones `headphones` / Speakers `hifispeaker`) bound to `listeningMode`;
    - "Microphone": `Picker(viewModel.inputDevices)` calling `selectInput`;
    - "Their voice plays on": `Picker(outputDevices)` calling `selectOutput`;
    - the footer "In speaker mode your microphone pauses while their translation plays, so it doesn't translate itself.";
  - **Rhythm:** "When to translate", with the subtitle "How long you pause before TranslateCall translates what you said"; a `Slider(value: pauseSeconds, in: pauseRange, step: pauseStep)` with minimum label "Faster replies" and maximum label "Wait for full sentences", and the value `pauseValueLabel` centred under it;
  - **While translating:**
    - `Toggle("Show the status panel", isOn: @AppStorage(UISettingsKeys.showStatusPanel) = true)`;
    - `Toggle("Show latency in the panel", isOn: @AppStorage(UISettingsKeys.showLatency) = true)` with the subtitle "Small grey number next to each direction", **only when** `session.latency.canProvide` (D-3: hidden in this feature);
  - **General:**
    - "Open at login": a `Toggle` over `SMAppService.mainApp`, reading `.status == .enabled` and calling `register()` / `unregister()`, with errors shown inline in red caption text;
    - "Downloaded languages": the list from `DownloadedLanguages.list`, run in `.task` with `AppleTranslationService.isInstalled` and joined with ", ", and "Manage…" opening `x-apple.systempreferences:com.apple.Localization-Settings.extension`.
- [ ] **Step 4:** Previews in light and dark, compared with the frame. Manual check: changing Headphones/Speakers takes effect live in a session (REQ-H-05); the slider applies to the next session.
- [ ] **Step 5:** Run `just build && just lint && just test-only GeneralSettingsTests`. Commit:
```bash
git add TranslateCall/Features/Settings TranslateCallTests/GeneralSettingsTests.swift
git commit -m "feat(ui): Settings General tab (M9 UI core T20)"
```

---

### Task 21: Settings — Advanced (legacy) (sonnet)

**Files:**
- Create: `TranslateCall/Features/Settings/LegacyAdvancedSettingsView.swift`, `TranslateCall/Features/Settings/Legacy/` (moved views)
- Modify: `TranslateCall/Features/Settings/SettingsView.swift`
- Move:
  - `Features/Main/STTMetricsView.swift` and `TTSMetricsView.swift` → `Features/Settings/Legacy/`;
  - the download sheets from `ContentView+DownloadSheets.swift` → `Features/Settings/Legacy/ModelDownloadSheets.swift`, as `struct ModelDownloadSheets: ViewModifier` with the four `@State` flags and the four `onChange` triggers;
  - the Kokoro voice list and picker (`LanguagePairView.kokoroVoices`) → `Legacy/KokoroVoicePicker.swift`;
  - the TTS monitor row from `ContentView` → `Legacy/TTSMonitorRow.swift`.
- Test: `TranslateCallTests/LegacyAdvancedSettingsTests.swift` (replaces `ConversationSettingsViewTests` in Task 22)

**Interfaces:**
- Consumes: the `STTEngineSelector`/`TTSEngineSelector` automatic API (Task 5), `VADProvider.activeEngine`, `SetupWizardView`, `VoiceProfileListView`.
- Produces:
  - `nonisolated enum LegacyEngineChoice<Engine: Hashable>: Hashable { case automatic, engine(Engine) }`;
  - `static func selection(isAutomatic: Bool, preferred: Engine) -> LegacyEngineChoice`;
  - `LegacyAdvancedSettingsView.vadLabel(_:)` and `guideURL`, ported unchanged from `ConversationSettingsView`.

- [ ] **Step 1: Failing tests** `LegacyAdvancedSettingsTests`:
  - `engineSelection`: `LegacyEngineChoice.selection(isAutomatic: true, preferred: STTEngine.parakeet) == .automatic`; `(false, .whisper) == .engine(.whisper)`;
  - `labels`: the existing `ConversationSettingsViewTests` expectations for `vadLabel` and `guideURL`, renamed to `LegacyAdvancedSettingsView`. The `pauseLabel` case is dropped: replaced by Task 20.

  Run `just test-only LegacyAdvancedSettingsTests`. Expected: FAIL.
- [ ] **Step 2: View** (a grouped `Form`):
  - **Speech recognition:** `Picker` over `LegacyEngineChoice<STTEngine>` ("Automatic (recommended)", divider, the engines). The setter calls `setAutomatic(true)` or `setPreferredEngine(engine)`; the download indicators follow `LanguagePairView`'s current engine row;
  - **Voice:** the same for `TTSEngine`, without `edgeTTS` unless `EdgeTTSConsentManager.consentGiven`, plus `KokoroVoicePicker` when the choice is Kokoro;
  - **Diagnostics:** `STTMetricsView()`, `TTSMetricsView()`, `TTSMonitorRow()` and `Text(vadLabel(vadProvider.activeEngine))`;
  - **Other:**
    - "Voice profiles…", which opens the existing profile sheet;
    - "Run setup again…", which opens `SetupWizardView` as a sheet;
    - a "Usage guide" `Link(guideURL)`;
  - attach `.modifier(ModelDownloadSheets())`.
- [ ] **Step 3:** Run the tests and `just build`. Expected: PASS. Previews: automatic and manual states.
- [ ] **Step 4: Manual check.** Pick Parakeet → "Models: Custom" on the main window; pick "Automatic (recommended)" → "Models: Recommended" (U9).
- [ ] **Step 5:** Run `just lint`. Commit:
```bash
git add TranslateCall/Features/Settings TranslateCall/Features/Main TranslateCallTests/LegacyAdvancedSettingsTests.swift
git commit -m "feat(ui): temporary Advanced (legacy) Settings tab with today's technical controls (M9 UI core T21)"
```

---

### Task 22: Remove the old window and dead views; "Skip my next sentence" (sonnet)

**Files:**
- Delete:
  - `TranslateCall/Features/ContentView.swift`, `ContentView+DownloadSheets.swift`;
  - `Features/Main/StatusBadgeView.swift`, `LevelMeterView.swift`, `CaptureButtonView.swift`, `TranscriptionView.swift`, `IncomingStatusBanner.swift`, `TTSNoticeLine.swift`, `DeviceSectionView.swift`, `ConversationSettingsView.swift`, `LanguagePairView.swift`.
- Modify:
  - `MenuBarController.swift`: remove `iconName(state:isCapturing:)`;
  - `TranslateCallApp.swift`: add the command;
  - `AudioViewModel.swift`: the doc comment that names `LanguagePairView` now names `LanguageSection`.
- Tests:
  - delete `IncomingStatusBannerTests.swift` (covered by `UICopyTests.unavailableLines`) and `ConversationSettingsViewTests.swift` (ported in Task 21);
  - in `AudioCoordinatorEchoGateTests.swift`, remove the `StatusBadgeView.presentation` and `MenuBarController.iconName` cases. Their states are covered by `DirectionStateTests` and `MenuBarDotTests`.

- [ ] **Step 1:** Run `grep -rnw "ContentView\|StatusBadgeView\|LevelMeterView\|CaptureButtonView\|TranscriptionView\|IncomingStatusBanner\|TTSNoticeLine\|DeviceSectionView\|ConversationSettingsView\|LanguagePairView\|iconName" TranslateCall TranslateCallTests`. Every hit is either deleted in this task or updated as listed.
- [ ] **Step 2:** Delete and update as listed (REQ-UI-80).
- [ ] **Step 3: Command (REQ-UI-80a).** In `TranslateCallApp.commands`, add `CommandMenu("Call")` with:
  - "Pause" / "Resume" (`⌘⇧P`);
  - "Skip My Next Sentence" (`⌘⇧M`, `session.skipNextSentence()`).

  Both are disabled unless `session.phase == .running`.
- [ ] **Step 4:** Run `just build && just lint && just test`. Expected: Build Succeeded, no lint output, unit tier passes (P16 flake rule as in Task 13).
- [ ] **Step 5: Commit**
```bash
git add -A TranslateCall TranslateCallTests
git commit -m "refactor(ui): remove the old main window and its views; Skip my next sentence command (M9 UI core T22)"
```

---

### Task 23: Docs, backlog, and the full gate (sonnet)

**Files:**
- Modify: `docs/ARCHITECTURE.md` (UI layer), the backlog
- Modify: this file (mark it done)

- [ ] **Step 1:** In `docs/ARCHITECTURE.md`, replace the UI section with:
  - the setup window (`MainSetupView` / `MainSetupModel` / `Readiness`);
  - the status panel (`StatusPanel` non-activating `NSPanel` + `CallSessionModel`);
  - the menu bar (`MenuBarController` + `MenuBarDot`);
  - Settings (`SettingsOpener`, General + Advanced (legacy));
  - automatic models (`ModelCatalog.json` → `ModelChoice` → selectors; `ModelPreloader`);
  - Pause (`PauseGate` before the VADs).
- [ ] **Step 2: Backlog.** Create `specs/m9-product/backlog.md` if it is missing, with the header used in `specs/m8.5-stabilization/backlog.md`. Add:
  - **A29:** `LanguagePairManagerTests` uses `UserDefaults.standard` in a parallel suite; it flaked once in 4 runs (P16);
  - **UI-L1:** wire `TraceLatencyProvider` once `spec/m9-benchmark` is on `main` (D-3);
  - **UI-L2:** "Advanced…" opens the legacy tab until feature 2.
- [ ] **Step 3:** Run `just pr`. Expected: build, lint, scan, unit and integration tiers all green; it publishes `local/just-pr`. A28 (the integration host exiting) or A27 (Edge 403, known issue) may show up: re-run once and report the outcome; do not mark tests as known issues without asking.
- [ ] **Step 4: Commit**
```bash
git add docs/ARCHITECTURE.md specs/m9-product
git commit -m "docs(m9): UI core architecture notes and backlog (M9 UI core T23)"
```

---

### Task 24: Manual checklist (user, before merge)

The user runs this on the Mac mini with a real Teams call (headphones), after `just pr` is green. Dark mode is checked with System Settings › Appearance.

- [ ] **U1:** A fresh launch shows the new main window. Light and dark follow the system.
- [ ] **U2:** With Teams not running, "Open Teams and start" launches Teams. Then the panel appears and the main window closes.
- [ ] **U3:** During a real call, the panel never takes focus:
  - typing in Teams chat works while the panel updates;
  - dragging the panel keeps Teams frontmost;
  - the panel stays visible with Teams in full screen.
- [ ] **U4:** Pause → no translation either way. Resume is immediate.
- [ ] **U5:** Quit Teams mid-call → "Partly working" / "Can't hear Teams" + Retry.
- [ ] **U6:** Speakers mode → the "Mic paused" chip and the standing notice.
- [ ] **U7:** A language not downloaded → the card, then Download, then "Ready".
- [ ] **U8:** Screen-recording permission revoked → the red card. Start still works for the outgoing side.
- [ ] **U9:** ⌘, opens Settings. General changes apply. The legacy tab's engine pickers work, and "Automatic" restores "Models: Recommended".
- [ ] **U10:** With everything closed, translation keeps running from the menu bar, and the popover's Stop works.
- [ ] **U11:** Dark mode on every new screen, compared with the prototype's dark frames.

Then: push + PR (template body, `🤖 Generated with [Claude Code](https://claude.com/claude-code)` at the end) and, after the user's OK, squash merge.

