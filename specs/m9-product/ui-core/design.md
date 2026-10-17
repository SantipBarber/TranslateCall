# M9 UI core — Design

> Status: APPROVED (2026-10-17). Implements `requirements.md` (REQ-UI-xx). The visual reference is `design/translatecall.pen`: read it only through the pencil MCP (`execute` + `TakeScreenshot` / `Get`), never with Read/Grep. The prototype uses Inter and Lucide as stand-ins; build with the system font and SF Symbols.

## 1. Prototype → SwiftUI map

| Prototype frame (light / dark node id) | SwiftUI | REQ |
|---|---|---|
| Main Window — Setup (`UVrO6` / `i9YcC`) | `MainSetupView` in the `WindowGroup("main")` | 01–10 |
| State — Language not downloaded (`JjS39` / `Ik2ak`) | `LanguageDownloadCard` inside `LanguageSection` | 30 |
| State — Call app not open (`FvpIr` / `YELE8`) | `CallAppNotOpenCard` | 31 |
| State — Permission missing (`oKwZz` / `yVagH`) | `PermissionCard` | 32 |
| Status Panel — Compact (`vr2HP` / `WiCOt`) | `StatusPanelView` (compact) in `StatusPanel` (NSPanel) | 41–43, 45, 46 |
| Status Panel — Expanded (`DNobA` / `oU4FO`) | `StatusPanelView` (expanded) → `TranscriptView` | 44 |
| State — Panel: incoming audio lost (`ANfma` / `zRF0f`) | `DirectionRow` in the unavailable state | 43 |
| State — Panel: speaker mode & skipped (`wMviH` / `xbv6s`) | `PanelNotices` | 45 |
| In Context — Panel over a video call (`BPf5j`) | (placement reference only) | 41 |
| Menu Bar — Idle / Translating (`bQKYO`, `eBNlu` / `xiVmb`, `C2n5j8`) | `MenuBarPopoverView` (rewritten) | 60–61 |
| Settings — General (`XjnNV` / `m9CFL`) | `GeneralSettingsView` | 71 |

Implementers screenshot the frame they build (light and dark) before writing the view, and compare it with a screenshot of the running view (Xcode preview or the app) before the task is reviewed.

## 2. File layout

The project uses synchronized folders: new files need no `project.pbxproj` edit.

```
TranslateCall/
  Core/Models/          ModelCatalog.swift, ModelCatalog.json (bundled resource), ModelChoice.swift
  Core/Session/         DirectionState.swift, TranscriptEntry.swift, PauseGate.swift, LatencyProvider.swift
  Core/Setup/           CallApp.swift (catalog of known apps), CallAppMonitor.swift (NSWorkspace), Permissions.swift
  Features/Setup/       (existing wizard stays) 
  Features/Main/        MainSetupView.swift, CallAppSection.swift, LanguageSection.swift, VoiceSection.swift,
                        StateCards.swift, Readiness.swift, MainSetupModel.swift
  Features/StatusPanel/ StatusPanel.swift (NSPanel + controller), StatusPanelView.swift, DirectionRow.swift,
                        TranscriptView.swift, PanelNotices.swift
  Features/MenuBar/     MenuBarController.swift (kept, icon + popover wiring), MenuBarPopoverView.swift (rewritten)
  Features/Settings/    SettingsView.swift, GeneralSettingsView.swift, LegacyAdvancedSettingsView.swift, SettingsTab.swift
  UI/                   Theme.swift (accent, semantic colours, spacing, corner radii), Chip.swift, SectionHeader.swift
  Resources/            Localizable.xcstrings
```

The engine part of `LanguagePairView` and all of `ContentView` are deleted (REQ-UI-80). Views kept for the legacy tab move under `Features/Settings/Legacy/`:
- `STTMetricsView`, `TTSMetricsView`;
- the engine pickers extracted from `LanguagePairView`;
- the TTS monitor row;
- the download sheets from `ContentView+DownloadSheets.swift`.

## 3. Automatic model choice (REQ-UI-20…24)

### 3.1 Catalog

`ModelCatalog.json`, bundled. Every list is ordered, and the first ready engine wins:

```json
{
  "version": 1,
  "stt":          { "en": ["parakeet", "whisper", "appleSpeech"], "default": ["whisper", "appleSpeech"] },
  "ttsOutgoing":  { "en": ["voiceClone", "kokoro", "avSpeech"],   "default": ["voiceClone", "avSpeech"] },
  "ttsIncoming":  { "en": ["kokoro", "avSpeech"],                 "default": ["avSpeech"] }
}
```

- `ModelCatalog` is `Decodable` and `Sendable`, with `static let bundled` loaded once. A missing or corrupt file is a programmer error: `assertionFailure` plus a built-in fallback equal to the JSON above.
- Language codes are the `Locale.Language.languageCode` identifiers (`en`, `es`, `de`, …).
- `es` and `de` use `default`. This follows the research and the current product: Whisper for non-English STT when it is on disk, and the voice clone for the outgoing voice when it is active.

### 3.2 Resolution

```swift
nonisolated struct ModelAvailability: Sendable, Equatable {
    var parakeetReady, whisperReady, kokoroReady, voiceCloneActive: Bool
    var hasSystemVoice: (Locale) -> Bool   // injected; Equatable ignores it
}
nonisolated enum ModelChoice {
    static func stt(for locale: Locale, catalog: ModelCatalog, availability: ModelAvailability) -> STTEngine
    static func tts(for locale: Locale, direction: Direction, catalog: ModelCatalog, availability: ModelAvailability) -> TTSEngine
}
```

An engine is eligible when two conditions hold:
- `engine.supports(locale:)` (existing);
- it is ready per the snapshot. Apple Speech and AVSpeech are always ready. The voice clone needs `voiceCloneActive`, the existing `TTSEngineSelector.voiceCloningActive`.

If no listed engine is eligible, the result is `.appleSpeech` / `.avSpeech`. `edgeTTS` is never in the catalog. Edge keeps entering only through the existing `systemOrEdgePrimary` fallback, which requires prior consent (REQ-UI-22).

### 3.3 Integration with the selectors

- `STTEngineSelector` and `TTSEngineSelector` each gain `var isAutomatic: Bool`, persisted under the shared key `tlk.models.automatic` (default `true`; one flag for both stages), and a `catalog` dependency (default `.bundled`).
- In `makeOutgoingService` / `makeIncomingService`:
  - when `isAutomatic`, the engine comes from `ModelChoice`. The existing factory branch for that engine builds the service, so the Kokoro voice, the profile store and the fallbacks are unchanged;
  - when not automatic, the code path is exactly today's.
- `setPreferredEngine(_:)` sets `isAutomatic = false`. A new `setAutomatic()` sets it back to `true`.
- **Ready means on disk (D-6).** Today readiness flags turn true only after an explicit load, and only a manual engine pick triggers that load (Whisper auto-loads only when it is the preferred engine; Parakeet and Kokoro never load on their own). Automatic mode therefore needs new code:
  - `isModelCached() -> Bool` on `ParakeetModelManager`, `WhisperModelManager` and `KokoroModelManager`. `QwenCloneModelManager.isModelCached()` already exists. Each one checks the model files in its cache folder, without loading anything.
  - `ModelAvailability` is built from these on-disk checks, not from the loaded flags.
  - **Preload:** a new `ModelPreloader` (`@MainActor`, owned by `AppContainer`, never run in the test host) runs at launch and on every language-pair change. It resolves the catalog for the current pair and loads the chosen cached models in the background (`ensureReady` / `loadIfNeeded`), so Start is fast. It respects MLX exclusivity: it never loads Kokoro while the voice clone is the outgoing choice, and vice versa. It unloads a previously preloaded model that the new pair no longer uses. It never downloads anything.
  - If a preload has not finished when Start is pressed, the service loads on first use, as today (for example Parakeet loads lazily in `ParakeetSpeechService`).
- Incoming TTS today ignores Kokoro. With the catalog, incoming English may use Kokoro when it is ready. Kokoro is an MLX model, and only one MLX TTS may be loaded at a time (NF-04). If the voice clone is active and the outgoing direction uses it, Kokoro is treated as not ready for incoming, so both directions never hold an MLX model at once.
- The main window's "Models: Recommended" reads `isAutomatic` on both selectors. When either is manual it reads "Models: Custom".

## 4. Session state for the UI

### 4.1 Coordinator additions (`AudioCoordinator`)

All additions are on the main actor and published, next to the existing state:

| Addition | Set where | Purpose |
|---|---|---|
| `isOutgoingTranslating`, `isIncomingTranslating: Bool` | `true` at the start of `handleOutgoingTranslation` / `handleIncomingTranslation` (after the empty and suppress guards), `false` after `speak` is enqueued or on failure | chip "Translating…" |
| `isIncomingSpeechActive: Bool` | new `observeIncomingVADState(vad)` in `activateIncoming`, mirroring `observeVADState` | chip "Hearing them" |
| `isPaused: Bool` (`private(set)`) | `pause()` / `resume()` | D-5 |
| `transcript: [TranscriptEntry]` (`private(set)`) | appended in the translation handlers | expanded panel |
| `sessionStartedAt: Date?` (`private(set)`) | set when `isOutgoingActive` becomes true, cleared in `stop()` | elapsed time |

`TranscriptEntry`:

```swift
nonisolated struct TranscriptEntry: Identifiable, Sendable, Equatable {
    enum Direction: Sendable { case outgoing, incoming }
    let id: UUID; let direction: Direction; let original: String
    var translation: String?          // nil while translating, or when the sentence was skipped
    var skipped: Bool                 // translation failed or TTS skipped it; shown dimmed with a note
    let date: Date
    var latency: Duration?            // filled from LatencyProvider when available
}
```

- An entry is appended with `translation == nil` when STT delivers the text. It is completed when the translation returns, or marked `skipped` when it fails.
- `transcript` is capped at 200 entries by dropping the oldest. It is cleared at `start()`. It is not cleared at `stop()`, so the last session stays readable until the next Start; nothing shows it after Stop in this feature, but feature 2 or later may.
- `stop()` also resets `isPaused`, both translating flags and `isIncomingSpeechActive`.
- `errorAlert` stays for pre-call errors. Mid-call errors are handled by `AudioViewModel` (REQ-UI-82): when `isOutgoingActive` is true, it does not present them as alerts but routes them to a `panelNotice` (§5.3).

### 4.2 Pause (REQ-UI-50…52)

`PauseGate` is a `nonisolated final class`, `Sendable`, built on `Mutex<Bool>`, with the same shape as `MicEchoGate`:
- `func gate(_ stream: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<AVAudioPCMBuffer>` replaces each buffer with zeros of the same format and length while paused;
- `setPaused(_:)`.

One gate is built per session and sits in both chains:
- outgoing: `mic → PauseGate → MicEchoGate → VAD`;
- incoming: `system capture → PauseGate → VAD`.

Pausing never touches `MicEchoGate`, so the echo gate's tail logic is unaffected.

```swift
func pause() async   // guard isOutgoingActive, !isPaused; isPaused = true; pauseGate.setPaused(true);
                     // await outgoingTTS?.stopSpeaking(); await incomingTTS?.stopSpeaking()
func resume()        // guard isPaused; isPaused = false; pauseGate.setPaused(false)
```

- The translation handlers return early when `isPaused`, so text that STT delivers during the pause is dropped (REQ-UI-50).
- An utterance in progress at pause time is closed by the VAD's silence rule. Its text arrives while paused and is dropped.
- `retryIncoming` during a pause re-activates incoming behind the same gate, so it stays silent until Resume.

### 4.3 Direction state (REQ-UI-43)

```swift
nonisolated enum DirectionState: Equatable, Sendable {
    case unavailable(IncomingStopReason)   // incoming only
    case paused, micPaused, speaking, translating, hearing, listening
    static func outgoing(paused: Bool, micPaused: Bool, speaking: Bool, translating: Bool, speech: Bool) -> Self
    static func incoming(status: IncomingStatus, paused: Bool, speaking: Bool, translating: Bool, speech: Bool) -> Self
}
```

The priority order is the one in REQ-UI-43.
- Incoming `.idle`, `.starting` and `.active` derive normally.
- Incoming `.disabled` (no call app) derives a separate presentation: the "Them" row shows "Only your voice is translated" and no chip. A `DirectionState` value is not needed for it, so the view handles it from `IncomingStatus` directly.
- The header title is derived from the two direction states plus `isPaused` and `isStarting`: "Starting…", "Paused", "Partly working" (incoming unavailable) or "Translating".

### 4.4 Latency slot (REQ-UI-46, D-3)

```swift
protocol LatencyProvider: AnyObject, Sendable {
    /// Latest end-of-speech → first-audio latency for a direction, or nil when unknown.
    func latestLatency(for direction: TranscriptEntry.Direction) -> Duration?
    var canProvide: Bool { get }   // false → label and the "Show latency" setting are hidden
}
final class NoLatencyProvider: LatencyProvider { … }   // production, until the trace sink lands
```

`AppContainer` owns the provider and injects it into the panel model. The follow-up task after the benchmark merge does two things:
- implements `TraceLatencyProvider` over the latency thread's ring-buffer `TraceSink`, using `speechEnd ≈ vadEnd − trailingSilenceMs` (benchmark design §2.3);
- passes that sink to `AudioCoordinator`.

## 5. View models

### 5.1 `AudioViewModel` (extended, still the coordinator adapter)

The coordinator additions in §4.1 are bound one-to-one. New actions:
- `pause()` / `resume()` / `togglePause()`;
- `start(launchingCallApp:)`, which wraps today's `toggleCapture` start branch together with the REQ-UI-34 launch-and-wait. The wait goes through `CallAppMonitor.waitUntilRunning(bundleID:timeout:)`.

Derived: `outgoingState`, `incomingState`, `panelTitle` and `elapsed` (computed from `sessionStartedAt`; the view ticks with `TimelineView(.periodic(from:by: 1))` only while visible, NFR-UI-03).

### 5.2 `MainSetupModel` (new, `@MainActor ObservableObject`)

It owns what only the setup window and the popover need:
- `callApps: [CallAppRow]` from `CallAppMonitor`;
- `selectedCallApp`, which writes through to `SetupManager`;
- `permissions: PermissionState`, re-read on `NSApplication.didBecomeActiveNotification`;
- the pair status from `LanguagePairManager`;
- `readiness: Readiness`, the pure function of §5.4.

### 5.3 Panel notices

`PanelNotices` shows up to two lines, as an array assembled in `AudioViewModel.panelNotices`:
- the standing speakers line, when `listeningMode == .speakers`;
- the latest of `ttsNotice` or `panelNotice`. `panelNotice` holds mid-call errors (§4.1), clears after 8 s, and the newest notice wins.

### 5.4 Readiness (REQ-UI-33)

```swift
nonisolated struct Readiness: Equatable {
    enum Primary: Equatable { case start, openAppAndStart(String), download(String), stop, starting }
    var primary: Primary; var primaryEnabled: Bool
    var cards: [Card]   // ordered: .permission(kind) at top, .callAppNotOpen(name) under the app list
    static func derive(mic: PermissionStatus, screen: PermissionStatus, pair: LanguagePairStatus,
                       missingLanguage: String?, app: CallAppRow?, phase: SessionPhase) -> Readiness
}
```

The rules:
- mic denied → the permission card, and Start is disabled;
- screen recording denied → the card only;
- pair `.supported` (not installed) → `.download(missingLanguage)`, disabled;
- `.unsupported` → disabled, with the language row reading "This pair isn't available";
- app installed but not running → `.openAppAndStart`;
- session running → `.stop`;
- starting → `.starting`, disabled.

- BlackHole not present → the "Audio driver missing" card, without blocking Start (call 13).

The pair inputs come from checking each direction with `AppleTranslationService.isInstalled`, as F8.5.4 does, never from `LanguagePairManager.pairStatus`, which checks one direction only. `missingLanguage` is the display name of the language whose pack is missing (the target language if both are missing).

## 6. Call apps (REQ-UI-02…04, 31, 34)

`CallApp` is a static catalog of known call apps:
- fields: `id`, `displayName`, `bundleIDs: [String]` (all known IDs, newest first), `sfSymbolFallback` and `kind` (`.native`, or `.browser(url)` for Meet);
- entries:
  - Teams: `com.microsoft.teams2`, `com.microsoft.teams`;
  - Zoom: `us.zoom.xos`;
  - FaceTime: `com.apple.FaceTime`;
  - Webex: `Cisco-Systems.Spark`, `com.cisco.webexmeetingsapp`;
  - Slack: `com.tinyspeck.slackmacgap`;
  - Discord: `com.hnc.Discord`, `com.discord`;
  - Meet: browser, `https://meet.google.com`.
- The existing `VideoCallApp` (wizard copy) is kept as it is for the wizard and is mapped from `CallApp.id`. Feature 3 merges the two.

`CallAppMonitor` is a `@MainActor ObservableObject` behind a `WorkspaceProviding` protocol, so tests use a fake.

| Method or output | Implementation |
|---|---|
| `installedURL(bundleIDs)` | `NSWorkspace.urlForApplication(withBundleIdentifier:)` |
| `isRunning` | `NSWorkspace.runningApplications`, updated live from `didLaunchApplicationNotification` and `didTerminateApplicationNotification` |
| `defaultBrowser` | `urlForApplication(toOpen: https URL)` |
| `open(app)` | `NSWorkspace.openApplication(at:configuration:)`; for Meet, `NSWorkspace.open(url)` |
| `runningRegularApps` | input for "Other app…" |
| `waitUntilRunning(bundleID:timeout:)` | used by REQ-UI-34 |
| `rows: [CallAppRow]` (output) | installed apps only, in catalog order; the persisted selection is added even if it is not in the catalog (an "Other app…" choice) |

Neither the selection nor the running state uses ScreenCaptureKit any more, so no screen-recording permission is needed to list apps. `SetupManager.availableCaptureApps` stays for the wizard only. The persisted key (`tlk.captureApp.bundleID`) and `SetupManager.captureTarget` are unchanged. Two things are new code:
- the setter `selectCaptureApp(bundleID: String?)`, because today's setter takes an `SCRunningApplication?` and cannot select an app that is not running;
- a `@Published selectedCaptureBundleID`, read from defaults at init and observed by `AudioViewModel` for the mid-call retry (call 14).

Icons come from `NSWorkspace.icon(forFile:)` of the installed app, or of the browser for Meet. The SF Symbol is the fallback.

## 7. Windows

### 7.1 Main window

The `WindowGroup(id: "main")` now hosts `MainSetupView`, which keeps the A26 `.onAppear` wiring verbatim:
- `translationHost.show()`;
- the `MainWindowOpener` hand-off;
- `MenuBarController` creation.

Window traits:
- `.windowResizability(.contentSize)`;
- `.frame(width: 420)` with a height that fits the content;
- the toolbar shows the "On-device" mark as a trailing `ToolbarItem`, with the title "TranslateCall".

On a successful start (`isOutgoingActive` becomes true), the view dismisses its window with `@Environment(\.dismissWindow)` when "Show the status panel" is on. When the panel is off, the window stays, so there is always a visible surface besides the menu bar.

### 7.2 Status panel

`StatusPanel: NSPanel` uses:
- `styleMask [.nonactivatingPanel, .borderless, .fullSizeContentView]`, with `isFloatingPanel = true` and `level = .floating`;
- `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`;
- `hidesOnDeactivate = false`, `isMovableByWindowBackground = true`, `becomesKeyOnlyIfNeeded = true`;
- `canBecomeKey` / `canBecomeMain` overridden to `false`;
- `setFrameAutosaveName("StatusPanel")`;
- the content in an `NSHostingView` with a material background (`NSVisualEffectView`, `.hudWindow` or `.popover`) and a 12 pt corner radius.

Because the panel can never become key, its buttons act on mouse-down without activating the app (`acceptsFirstMouse` through the hosting view). `StatusPanelController` (owned by `AppContainer`):
- shows the panel when the session goes active and the setting is on;
- hides it on stop;
- resizes it for compact or expanded, anchored at the top edge.

Default frame: the top-right of `NSScreen.main.visibleFrame`, inset 16 pt, applied only when no autosaved frame exists.

### 7.3 Settings scene

The `Settings { SettingsView() }` scene is added to `TranslateCallApp`.
- **Tabs:** a `TabView` with `.tabItem` and the `SettingsTab` enum; the selection is in `@AppStorage("ui.settings.tab")`.
- **Opening programmatically:** the main window, the panel model and the menu bar controller call `SettingsOpener.open(tab:)`. That helper:
  - sets the stored tab;
  - calls `@Environment(\.openSettings)`, captured from a SwiftUI view through a handler like the `MainWindowOpener` one;
  - activates the app with `NSApp.activate()`.
- The panel and the popover live outside SwiftUI scenes. They reach it through the captured handler, the same pattern as `MainWindowOpener`.

## 8. Menu bar

`MenuBarController` keeps the `NSStatusItem`, the popover and the right-click menu.
- **Icon:** the SF Symbol `translate`, with a small dot overlay drawn into an `NSImage` (template base plus a coloured dot) according to the session state (REQ-UI-61).
- **Popover:** `MenuBarPopoverView` is rewritten per the prototype. It reads `AudioViewModel` and `MainSetupModel`, and its height fits the content (two layouts).
- **Right-click menu:** gains "Pause" / "Resume".

## 9. Strings and theme

- `Localizable.xcstrings` is created. All `Text("…")` literals become catalog keys automatically through SwiftUI's `LocalizedStringKey`. Strings built in model code use `String(localized:)`.
- `Theme` holds:
  - the accent: the system accent colour, with no custom brand colour (brief);
  - the semantic status colours: green → `.green`, orange → `.orange`, red → `.red`, purple (voice) → `.purple`;
  - the chip backgrounds: the same colours at 15 % opacity;
  - the corner radii (6 / 8 / 12) and the paddings (8 / 12 / 16).

  The prototype's variables (`accent`, `green-soft`, …) map onto these. No hex values appear in views.

## 10. Testing

**Unit tests (Swift Testing, `TranslateCallTests`, existing tags and naming)**

| Suite | Covers |
|---|---|
| `ModelCatalogTests` | Decoding the bundled JSON; the fallback on a corrupt file; resolution for en/es/de/uk and each availability combination; Edge never chosen; the MLX exclusivity rule (§3.3) |
| `STTEngineSelectorTests`, `TTSEngineSelectorTests` (extended) | automatic vs manual; `setPreferredEngine` → manual; `setAutomatic` |
| `ReadinessTests` | Each rule in §5.4 |
| `DirectionStateTests` | The priority order for every flag combination (parameterized) |
| `PauseGateTests` | Zeros of the same format and length while paused; pass-through otherwise; the toggle takes effect on the next buffer |
| `AudioCoordinatorPauseTests` | Pause stops both TTS; text delivered while paused is not translated; Resume restores processing; Stop while paused resets; Retry while paused stays silent |
| `AudioCoordinatorTranscriptTests` | Append on STT, completion on translation, `skipped` on failure, cap at 200, cleared at start, translating flags |
| `CallAppMonitorTests` | Rows for installed apps only; live running updates; Meet mapped to the default browser; the persisted "other" app kept; `waitUntilRunning` timeout (fake workspace, test clock) |
| `PanelNoticesTests` | Composition and the 8 s expiry |
| `ModelPreloaderTests` | Preloads the catalog picks for the pair; MLX exclusivity; unloads models the new pair no longer uses; never downloads (fake managers) |
| `ModelCacheTests` | `isModelCached()` on temp folders: complete, partial and missing |
| `AudioViewModelTests` (extended) | A mid-call `errorAlert` goes to `panelNotice`, not to the alert |

No UI-test target is added, consistent with the repo today. Views are checked through:
- Xcode previews, provided for every new view in light and dark, with fixtures for each state of the prototype;
- side-by-side screenshots against the pencil frames during review;
- the manual checklist.

**Manual checklist (user, before merge)**
- U1: a fresh launch shows the new main window. The light/dark switch follows the system.
- U2: Teams not running → "Open Teams and start" launches Teams, then the panel appears and the main window closes.
- U3: during a real call, the panel never takes focus. Typing in Teams chat works while the panel updates, and dragging the panel keeps Teams frontmost. The panel stays visible with Teams in full screen.
- U4: Pause → no translation either way, then Resume is immediate.
- U5: quit Teams mid-call → "Partly working" / "Can't hear Teams" + Retry.
- U6: speakers mode → the "Mic paused" chip and the standing notice.
- U7: a language not downloaded → the card, Download, then "Ready".
- U8: the screen-recording permission revoked → the red card, and Start still works for the outgoing side.
- U9: ⌘, opens Settings. General changes apply. The legacy tab engine pickers work, and "Automatic" restores "Models: Recommended".
- U10: everything closed → translation keeps running from the menu bar. The popover's Stop works.
- U11: dark mode on every new screen, compared with the prototype's dark frames.

## 11. Risks

| Risk | Mitigation |
|---|---|
| A26 regression (main window not opening at launch) when `ContentView` is replaced | Keep the `.onAppear` wiring and `MainWindowOpener` untouched. `MainWindowOpenerTests` and `TranslationHostWindowTests` must stay green. U1 is in the checklist. |
| `openSettings` from AppKit contexts (status item, NSPanel) | A captured-handler pattern like `MainWindowOpener`. The first task builds and verifies it before any view work depends on it. |
| A non-activating panel still stealing focus in some apps | Verified manually first (U3), in the panel task itself, with Teams and Zoom. The fallback is `.utilityWindow` with `orderFrontRegardless`. |
| Catalog-driven Kokoro for incoming clashing with the voice clone (MLX) | The exclusivity rule in §3.3, unit-tested. |
| String Catalog extraction churn | Created once, in the first view task; build settings already prefer catalogs. |

## 12. Claude's calls (not confirmed by the user — check while reading)

1. The spec folder is `specs/m9-product/ui-core/`. The roadmap lives in `ui-redesign/roadmap.md`.
2. One shared `tlk.models.automatic` flag for STT and TTS, default automatic also for existing users. Previous manual engine choices are ignored until the user picks an engine again in the legacy tab. Because readiness means "on disk" (D-6), existing users keep using the models they already downloaded.
3. Automatic choice never starts a model download. A fresh install therefore runs on Apple Speech + AVSpeech until models are downloaded through the legacy tab (feature 2 adds proper downloads). The one exception is the user's own action: turning on "Use my voice" without the Qwen model starts its download, with an inline progress row in the Voice section, as `enableVoiceCloning()` does today.
4. Incoming English may now use Kokoro when it is ready, which today never happens.
5. Stop does not reopen the main window, and the Dock icon stays as it is today.
6. "No sound for 20 s" detection from the prototype's lost-audio frame is dropped. "Can't hear <App>" shows only when capture actually stopped.
7. The language download card shows no size or progress: Apple's `prepareTranslation` sheet gives neither.
8. Discord stays in the call-app list (it is in today's `VideoCallApp`), alongside the brief's list.
9. Mid-call `errorAlert`s become panel notices (8 s).
10. The transcript is kept after Stop until the next Start, but no screen shows it in this feature.
11. **Pre-call modals with no window open:** Start from the popover opens the main window first whenever something must be shown before the call (the Edge consent prompt, a pre-call `errorAlert`). Every pre-call alert and sheet is presented by `MainSetupView`. Errors raised by `start()` itself (VAD, STT or TTS failing while starting) become panel notices when the session does go active, and alerts on the main window when it does not.
12. **The model download sheets** (Parakeet, Kokoro, Whisper, voice clone) move to the "Advanced (legacy)" Settings tab, which hosts their `onChange` triggers. The voice-clone download started from "Use my voice" shows inline instead (call 3).
13. **BlackHole missing:** a "Audio driver missing" card with "Set up…", which opens today's wizard. It does not block Start, as today. `Readiness.derive` gains a `blackHolePresent` input.
14. **"Choose another app…" in the panel** reopens the main window. Picking an app mid-call re-targets incoming exactly as today (`captureAppChanged`). `SetupManager` gains `selectCaptureApp(bundleID:)`, and the retry hook observes the persisted bundle ID instead of `$selectedCaptureApp`.
15. **"Record again"** opens today's voice-profile list sheet (until feature 4).
16. **Mute Turn** becomes "Skip my next sentence": an app-menu command (⌘⇧M, works while TranslateCall is active) and an item in the status item's right-click menu. It is not in the panel.
17. **`skipped` entries** mark only translation failures. TTS skips stay transient notices, because `ttsEvents` carry no sentence identity.
18. **"Ready" checks each direction separately** with `AppleTranslationService.isInstalled` (as `start()` does), not `LanguagePairManager.pairStatus`, which checks one direction only.
19. **With "Show the status panel" off, the main window stays open after Start** (§7.1). REQ-UI-40 was amended on 2026-10-17 to say so; before, it made the menu bar the only in-call surface.
