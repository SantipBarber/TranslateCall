# M9 UI core — Requirements

> Status: APPROVED (2026-10-17) — brainstorm decisions D-1…D-6 and the builder-check answers folded in.
> Inputs: `specs/m9-product/ui-redesign/design-brief.md` (intent, user decisions, text-fitting rules), `specs/m9-product/ui-redesign/roadmap.md` (feature split), `design/translatecall.pen` (visual reference, pencil MCP only).

## Overview

TranslateCall's main window today is a 480×760 pt stack that exposes the machinery: device pickers, STT/TTS engine pickers, the VAD, metrics and a level meter. The user wants Teams-like simplicity for any call app (brief, "Intent"):
- pick the call app, my language and their language, then Start;
- the app chooses the models by itself;
- a small panel that floats over the call shows that translation is alive, without getting in the way.

This feature is the first of four (roadmap). It delivers the everyday flow end to end:
- the setup window;
- automatic model choice;
- the in-call status panel, compact and expanded;
- the menu bar popover;
- the pre-call and in-call states;
- a Settings scene with the definitive General tab.

The technical controls move, unchanged, to a temporary "Advanced (legacy)" Settings tab until feature 2.

## Decisions taken (brainstorm 2026-10-17)

| ID | Decision |
|----|----------|
| D-1 | **Four sequential features**, each with its own spec and PR (roadmap). This spec covers feature 1, "UI core". |
| D-2 | **Automatic model choice from a static catalog** of ordered preferences per language and stage, shipped as a bundled JSON file. The benchmark can later rewrite it without code changes. The engine is resolved per direction from what is installed. The UI shows no "Tested" marks and no timings until real benchmark data exists. Per-pair overrides come in feature 2. |
| D-3 | **Latency label slot only.** A `LatencyProvider` protocol; the production provider returns `nil` until the latency thread's trace sink is on `main`. While it returns `nil`, the label is hidden and the "Show latency in the panel" setting is not shown. |
| D-4 | **Settings scene (⌘,) now**, with the prototype's General tab and a temporary "Advanced (legacy)" tab that reuses today's technical views as they are. The current setup wizard and voice-profile screens stay, opened from the new entry points, until features 3 and 4. |
| D-5 | **Pause = both directions paused, engines kept warm.** No audio is processed either way; Resume is immediate. The panel shows "Paused". |
| D-6 | **A model counts as ready when it is downloaded on disk.** At launch and on every language-pair change, the models the catalog would choose for that pair are preloaded in the background, with only one MLX model loaded at a time. Nothing is ever downloaded automatically. |

## Functional Requirements

### FR-UI.1 — Main window: call setup

**REQ-UI-01**: The main window SHALL be the prototype's "Main Window — Setup": fixed width 420 pt, height fitting its content, and no scrolling at the default text size. It SHALL contain, top to bottom:
1. a title bar with an "On-device" mark;
2. the **Call app** section;
3. the **Languages** section;
4. the **Voice** section;
5. the primary button;
6. a footer showing the listening mode and a Settings button.

**REQ-UI-02 (call apps)**: The Call app section SHALL list the known call apps that are installed on this Mac:
- Microsoft Teams, Zoom, Google Meet (in the default browser), FaceTime, Webex, Slack and Discord;
- each row shows the app icon, its name, a "Running" / "Not open" state that updates live, and an "Open" button when the app is not running;
- the selected row is highlighted with a checkmark;
- "Other app…" lets the user pick any running regular app, or "None — translate only my voice" (outgoing only).

**REQ-UI-03**: Selecting a row SHALL persist the capture target, as today (`tlk.captureApp.bundleID`). For Google Meet the target SHALL be the default browser's bundle ID, and the row title SHALL read "Google Meet · <Browser>".

**REQ-UI-04**: "Open" SHALL launch the app. For Google Meet it SHALL open `https://meet.google.com` in the default browser. Launching SHALL NOT start translation.

**REQ-UI-05 (languages)**: The Languages section SHALL show "I speak" and "They speak" pickers with a swap button between them. Below them, a status line SHALL show the pair state:
- "Ready" with a checkmark when both directions' packs are installed;
- otherwise the download card (REQ-UI-30);
- on the right: "Models: Recommended · Advanced…". In this feature "Advanced…" opens Settings on the "Advanced (legacy)" tab.

**REQ-UI-06**: The priority languages (Español, English, Deutsch) SHALL be listed first in both pickers, followed by a divider and the other supported languages in alphabetical order of their display name.

**REQ-UI-07 (voice)**: The Voice section SHALL show a "Use my voice" switch with the subtitle "They hear the translation in your own voice".
- **With an active profile:** a line "Voice: <profile name> · recorded <date>" and a "Record again" link.
- **Without a profile:** the switch is off, and turning it on opens today's voice-profile screen (D-4).
- **Target language not supported by the voice clone:** the switch is disabled with a one-line reason (brief, "Use my voice availability").

**REQ-UI-08 (primary button)**: The primary button SHALL reflect the readiness rule (REQ-UI-33) and read:
- "Start translating" when ready;
- "Open <App> and start" when the selected call app is installed but not running;
- "Download <Language> to start" (disabled) while a pack is missing;
- "Stop translating" while a session runs.

**REQ-UI-09**: The footer SHALL show the current listening mode ("Headphones" / "Speakers") with its SF Symbol, and a Settings button. Both open Settings on the General tab.

**REQ-UI-10**: The window SHALL use system materials, the system font, SF Symbols, standard controls and automatic light/dark appearance. Colours SHALL come from semantic system colours plus one accent; no hard-coded colour is allowed outside a single `Theme` namespace.

### FR-UI.2 — Automatic model choice

**REQ-UI-20**: A `ModelCatalog` SHALL hold, for each language (by BCP-47 language code, with a `default` entry), an ordered list of preferred engines:
- per stage: speech recognition (STT) and voice (TTS);
- for TTS, separately for the outgoing direction (towards the call) and the incoming direction (towards the user);
- loaded from a bundled `ModelCatalog.json`.

Translation is always Apple Translation and needs no entry.

**REQ-UI-21**: When model choice is automatic (the default), each direction's STT and TTS engine SHALL be the first engine in the catalog list that supports the locale and is ready on this Mac:
- ready means downloaded on disk (D-6); this feature never starts a model download on its own;
- for the voice clone, ready also requires that it is enabled and has an active profile.

**REQ-UI-21a (preload)**: At launch and on every language-pair change, the app SHALL preload in the background the cached models chosen for the current pair:
- at most one MLX model (Kokoro or the voice clone) SHALL be loaded at a time;
- a previously preloaded model the new pair no longer uses SHALL be unloaded;
- preloading SHALL never run in the test host;
- a Start before the preload ends SHALL still work, with the model loading on first use.

If none is ready, the direction SHALL use Apple Speech for STT and the system voice for TTS. That is today's fallback chain, Edge included: Edge is used only when consent was already given.

**REQ-UI-22**: Automatic choice SHALL never select a cloud engine that the user has not consented to (brief, "Privacy").

**REQ-UI-23**: Choosing an engine explicitly in the "Advanced (legacy)" tab SHALL switch model choice to manual, which means today's behaviour with the chosen engine. An "Automatic (recommended)" option SHALL switch back. The mode SHALL persist (`tlk.models.automatic`, default `true` for new and existing users).

**REQ-UI-24**: The catalog lookup SHALL be a pure function of (stage, direction, locale, availability snapshot), unit-tested without any model on disk.

### FR-UI.3 — Pre-call states (no modal alerts)

**REQ-UI-30 (language not downloaded)**: When either direction's pack is not installed, the Languages status line SHALL become a card:
- "<Language> needs a one-time download";
- "After that it works offline";
- a "Download" button that runs today's `prepareTranslation()` flow (F8.5.4 REQ-TR-40).

The availability SHALL be re-checked when the download sheet closes and when the app becomes active.

**REQ-UI-31 (call app not open)**: When the selected call app is not running, an orange card SHALL appear under the Call app list:
- "<App> isn't open";
- "TranslateCall will open it for you when you start. Then join or start your meeting in <App>."

**REQ-UI-32 (permission missing)**: When the microphone or the Screen & System Audio Recording permission is not granted, a red card SHALL appear at the top of the window:
- microphone: "Your microphone is off for TranslateCall";
- screen recording: "They can't be heard — Screen & System Audio Recording is off for TranslateCall, so it can't hear the other person in your call";
- with an "Open System Settings" link to the matching privacy pane.

Permissions SHALL be re-checked when the app becomes active.

**REQ-UI-32a (audio driver missing)**: When BlackHole is not present, a card "Audio driver missing" SHALL appear with a "Set up…" button that opens today's setup wizard. It SHALL NOT block Start, as today.

**REQ-UI-33 (readiness rule)**: A pure function SHALL derive the primary button (title, enabled, action) and the visible cards from:
- permission states;
- BlackHole presence;
- the pair status, checked per direction (as `start()` does), not with the one-direction `pairStatus`;
- the selected call app: none, running, installed but not running, or no longer installed;
- the session phase.

A missing microphone permission SHALL block Start. A missing screen-recording permission SHALL NOT block it: the outgoing side still works, as today.

**REQ-UI-34**: "Open <App> and start" SHALL launch the app, wait until it is running (at most 15 s), then start. If it is not running in time, the session SHALL still start: incoming shows "Can't hear <App>" in the panel, with Retry.

**REQ-UI-35**: The existing Edge TTS consent prompt before Start (no system voice for the target language) SHALL stay. It is the only modal shown before a call.

**REQ-UI-36 (where pre-call messages show)**: Every pre-call alert or prompt SHALL be presented by the main window. A Start from the menu bar that needs to show one SHALL open the main window first. Errors raised while starting SHALL become panel notices when the session goes active, and alerts on the main window when it does not.

### FR-UI.4 — In-call status panel

**REQ-UI-40**: After a successful Start, the main window SHALL close and the status panel SHALL appear, if "Show the status panel" is on (default on). When the setting is off, the panel SHALL not appear and the menu bar remains the only in-call surface.

**REQ-UI-41**: The status panel SHALL:
- be a floating, non-activating panel: it never becomes key or main and never takes focus or keystrokes from the call app;
- be shown on all Spaces and over full-screen apps;
- be draggable by its background;
- remember its position across launches;
- default to the top-right corner of the main screen's visible frame, inset 16 pt.

**REQ-UI-42 (compact)**: The compact panel (prototype "Status Panel — Compact", 320 pt wide) SHALL show a header and two direction rows.

The header holds:
- a state dot and title: "Translating", "Paused", "Starting…", or "Partly working" when one direction is unavailable;
- the call app name and the elapsed call time (mm:ss);
- an on-device lock mark;
- Pause/Resume, Stop, and expand/collapse.

Each direction row holds:
- the direction label: "You  ES → DE" and "Them  DE → ES";
- the latency label (REQ-UI-46);
- a state chip;
- the last translated line, at most 2 lines with an ellipsis.

**REQ-UI-43 (direction state)**: Each direction's chip SHALL show exactly one state, derived by a pure function from the coordinator's published state, in this priority order:
1. unavailable — incoming only: "Can't hear <App>" with Retry and "Choose another app…";
2. paused — "Paused";
3. mic paused — outgoing only, in speakers mode: "Mic paused";
4. speaking — "Speaking";
5. translating — "Translating…";
6. hearing speech — "Hearing you" / "Hearing them";
7. idle — "Listening".

**REQ-UI-44 (expanded)**: The expanded panel (prototype "Status Panel — Expanded", 340 pt wide, about 380 pt tall) SHALL replace the direction rows with a scrolling transcript of this session:
- one bubble per sentence: "Them" on the left, "You" on the right;
- each bubble holds the original text, its translation, and the speaker · time · latency;
- a "Translating…" bubble while a sentence is being translated;
- auto-scroll to the newest entry unless the user has scrolled up.

The transcript SHALL keep at most the last 200 sentences.

**REQ-UI-45 (notices)**: Under the direction rows, the panel SHALL show at most two notice lines:
- in speakers mode, the standing line "Your mic pauses while their translation plays (speakers on)";
- the latest transient notice (today's `ttsNotice`, e.g. a sentence too long to voice or a translation skipped) while it lasts.

**REQ-UI-46 (latency slot)**: Each direction row SHALL reserve space for a latency label such as "0.9 s". The value comes from an injected `LatencyProvider`. The label SHALL be hidden when the provider returns `nil` (D-3).

**REQ-UI-47**: Stop SHALL end the session and close the panel. The main window SHALL NOT reopen by itself.

### FR-UI.5 — Pause

**REQ-UI-50**: While paused, both directions SHALL process no audio:
- mic and call audio reach their VADs as silence of the same format and length, the same technique as `MicEchoGate`, so an utterance in progress ends by the normal silence rule;
- any TTS playing or queued SHALL stop;
- transcriptions that arrive while paused SHALL be dropped, not translated.

**REQ-UI-51**: Resume SHALL restore normal processing from the next audio buffer, without reloading models or reopening sessions.

**REQ-UI-52**: Pause/Resume SHALL be available in the panel and the menu bar popover. Pausing SHALL NOT change the mic echo gate's own state. Stop while paused SHALL work as usual.

### FR-UI.6 — Menu bar popover

**REQ-UI-60**: The status item's popover SHALL follow the prototype's "Menu Bar — Idle" and "Menu Bar — Translating".
- **Idle:** state "Ready" (or the first blocking reason from REQ-UI-33), with "<App> · <my language> ↔ <their language>"; the primary button; Open TranslateCall; Settings…; Quit.
- **Translating:** state and elapsed time; the two direction rows with their chips; "Stop translating"; Show status panel; Open TranslateCall; Settings…; Quit.

**REQ-UI-61**: The status item icon SHALL show a translate glyph, with a green dot while a session runs and an orange dot while paused or partly working.

### FR-UI.7 — Settings scene

**REQ-UI-70**: The app SHALL have a SwiftUI `Settings` scene (⌘,, app menu "Settings…") with toolbar tabs "General" and "Advanced (legacy)". The tabs SHALL be openable programmatically on a given tab, from the main window footer, from "Advanced…" and from the menu bar.

**REQ-UI-71 (General)**: The General tab SHALL follow the prototype's "Settings — General".
- **Audio:**
  - "I listen with" (Headphones / Speakers), bound to the existing `ConversationSettings.listeningMode`;
  - Microphone and "Their voice plays on" pickers, bound to the existing device selection;
  - a hint saying that in speakers mode the mic pauses while their translation plays.
- **Rhythm:** "When to translate", a slider bound to `ConversationSettings.pauseSeconds` (0.4–1.2 s), labelled "Faster replies" ↔ "Wait for full sentences", with the value shown ("0.6 s pause").
- **While translating:** "Show the status panel"; "Show latency in the panel", present only while the latency provider can produce values (D-3).
- **General:**
  - "Open at login" (`SMAppService.mainApp`);
  - "Downloaded languages", listing the installed packs, with "Manage…" opening the system Translation Languages settings.

**REQ-UI-72 (Advanced, legacy)**: The temporary tab SHALL host, unchanged in behaviour:
- the STT and TTS engine pickers, each with an "Automatic (recommended)" option (REQ-UI-23);
- the Kokoro voice picker and the model download sheets;
- the STT/TTS metrics;
- the VAD engine label;
- the TTS monitor row;
- "Voice profiles…";
- "Run setup again…", which opens today's wizard.

### FR-UI.8 — Removal and continuity

**REQ-UI-80**: `ContentView` and the views used only by it SHALL be removed or moved into the legacy tab: `StatusBadgeView`, `LevelMeterView`, `CaptureButtonView`, `TranscriptionView`, `IncomingStatusBanner`, `TTSNoticeLine`, `DeviceSectionView`, `ConversationSettingsView` and the engine part of `LanguagePairView`. Their tested logic, such as static label helpers, SHALL be kept or ported with its tests.

**REQ-UI-80a**: Mute Turn SHALL become "Skip my next sentence", available as an app-menu command (⌘⇧M) and in the status item's right-click menu.

**REQ-UI-80b**: "Choose another app…" in the panel SHALL reopen the main window. Picking a call app mid-call SHALL re-target incoming as today. `SetupManager` SHALL accept a selection by bundle ID, so that an app that is not running can be selected.

**REQ-UI-81**: First launch SHALL still open today's setup wizard when setup is not completed. It is a sheet on the new main window until feature 3 replaces it.

**REQ-UI-82**: Everything F8.5.4 and A26 guarantee SHALL keep working:
- translation runs with every window closed;
- the main window opens at launch, from the Dock and from the menu bar;
- the translation host window stays off-screen;
- no modal alert appears during a call. `errorAlert` raised mid-call SHALL be shown as a panel notice instead of an alert.

**REQ-UI-83**: All user-facing strings SHALL be in English and go through a String Catalog (`Localizable.xcstrings`), so that later localisation needs no code change.

## Non-Functional Requirements

**NFR-UI-01 (text fitting)**: The brief's text-fitting rules apply:
- single-line labels truncate with an ellipsis and never push siblings out of their row;
- the panel's last line is limited to 2 lines;
- body copy wraps.

Each screen SHALL be checked at the default and the largest macOS text size with the longest supported language names ("Ukrainian", "Portuguese (Brazil)") and app names.

**NFR-UI-02 (focus)**: Showing, updating or dragging the status panel SHALL never change the frontmost app. This is verified manually with Teams/Zoom in front (checklist).

**NFR-UI-03 (performance)**: Panel updates SHALL not cost the pipeline anything measurable. UI state is derived on the main actor from published values; the transcript keeps at most 200 entries; the elapsed-time label ticks once per second, only while the panel or the popover is visible.

**NFR-UI-04 (accessibility)**: Every control SHALL have an accessibility label. The direction state chips SHALL be readable by VoiceOver ("You, Spanish to German, speaking"). Colour SHALL never be the only carrier of a state: every chip has text and an icon.

**NFR-UI-05 (tests)**: Every pure rule SHALL be covered by Swift Testing unit tests in `TranslateCallTests`:
- catalog lookup;
- readiness;
- direction state;
- transcript capping;
- the pause gate;
- call app list and state.

Coordinator changes (pause, translating flags, incoming VAD state, transcript events) SHALL be unit-tested with the existing mocks. `just pr` SHALL stay green.

**NFR-UI-06 (dark mode)**: Every screen SHALL match its dark twin in the prototype through semantic colours only.

## Out of scope (later features or threads)

- Per-pair model overrides, the definitive "Advanced…" models sheet, the Voices and definitive Advanced Settings tabs, and cloud consent in Settings: feature 2.
- The new first-run assistant: feature 3.
- The teleprompter voice-clone flow: feature 4.
- The latency value itself, which comes from the latency thread (D-3); the latency pipeline work in general.
- Hiding the Dock icon while only the panel is shown.
- Detection of "no sound from the call app for N s". Incoming is shown as unavailable only when capture actually stopped (`IncomingStatus.stopped`), not on silence. Silence is normal when the other side listens.
- A Spain/Latin America Spanish variant selector (backlog).
