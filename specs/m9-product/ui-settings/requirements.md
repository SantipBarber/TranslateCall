# M9 UI settings — Requirements

> Status: APPROVED (2026-10-17) — brainstorm decisions S-1…S-8 and the builder-check answers folded in.
> Inputs: `specs/m9-product/ui-redesign/design-brief.md` (sections "Privacy" and "Advanced model choice per language pair"), `specs/m9-product/ui-redesign/roadmap.md` (feature 2), `specs/m9-product/ui-core/` (feature 1, merged in da25057), `specs/m9-product/backlog.md`, `design/translatecall.pen` (pencil MCP only).

## Overview

Feature 1 shipped the everyday flow with automatic model choice and left the technical controls in a temporary "Advanced (legacy)" Settings tab. This feature replaces that tab with the prototype's definitive screens:
- **Settings › Voices:** the user's cloned voices and the standard voice per language;
- **Settings › Advanced:** models per language pair, cloud opt-in, voice detector, diagnostics, logs and setup;
- **the "Advanced…" models sheet:** per language pair, the model for each stage, with downloads in place and cloud consent.

The legacy tab, the global manual engine mode and the modal download sheets are removed.

## Decisions taken (brainstorm 2026-10-17)

| ID | Decision |
|----|----------|
| S-1 | **Per-pair choices only; no global manual mode.** Each language pair stores an optional choice per stage (speech recognition, voice). A stage with no choice uses the catalog's recommendation. A chosen engine that is not usable (not on disk, cloud not allowed or not consented, unavailable, language not supported) falls back to the catalog. The preloader follows the same rule. "Models: Custom" shows only when the current pair has a choice. The shared flag `tlk.models.automatic` and the selectors' `preferredEngine` are removed. |
| S-2 | **"Tested" marks and timings are optional catalog data.** The catalog gains optional per-pair, per-engine `tested` and `latencyMs` fields. The sheet shows them only when present; today the catalog has none, so only "Recommended" and the On-device/Cloud chips show. Tests and previews use a sample catalog with data. |
| S-3 | **The cloud UI is built in full; Edge shows as unavailable.** "Allow cloud models", the Cloud chip, per-engine consent on first pick and the "cloud active" signal are built. The catalog marks Edge TTS `unavailable` (A27, 403), so its row is disabled with "Temporarily unavailable". Fixing A27 is a separate, time-boxed fix PR that only flips that flag. |
| S-4 | **Downloads in the sheet's row, through one facade.** A `ModelDownloads` facade over the four managers reports per model: not on this Mac (approximate size), downloading (progress when known), ready, or failed. Progress is indeterminate for every model (Whisper's percentage is not wired today; see design §5). Picking a model that is not on disk downloads it in the row (with Cancel) and selects it when done. Closing the sheet does not stop a download. No model deletion in this feature. |
| S-5 | **Backlog folded in:** UI-L2; all of UI-B9; the ModelPreloader part of UI-B4 (a failed load marked loaded; no re-preload on choice or availability changes); the UI-B5 test gaps for the selectors and `ModelCache`. UI-B1…B3 stay in the backlog. |
| S-6 | **"Use my voice" owns the user's voice; the sheet picks the standard voice.** The sheet's voice section is "Voice when 'Use my voice' is off": Apple voices, Kokoro (English only) and Edge (cloud). "My voice" is not a choice in the sheet; an info line says when it is used. The pair's voice choice applies to both directions; while "Use my voice" is on, it only changes the voice the user hears (incoming). |
| S-7 | **No downloads during a call.** While a session runs, the sheet's download buttons are disabled with "Available after the call"; picking models already on disk still works and applies at the next Start (downloads also load the model, which could hold two MLX models at once). |
| S-8 | **"Export logs…" covers the current launch.** The text reads "Logs since TranslateCall started"; no own log file. |

## Functional Requirements

### FR-ST.1 — Per-pair model choices

**REQ-ST-01**: The app SHALL store, per unordered language pair (ES ↔ DE is the same pair as DE ↔ ES), an optional speech-recognition engine and an optional voice engine. A pair with neither stored is "Recommended".

**REQ-ST-02**: Engine resolution for each direction SHALL be:
1. the pair's choice for that stage, if it is usable for that direction's language;
2. otherwise the catalog's first usable engine for that language (feature 1 rules);
3. otherwise Apple Speech / the system voice.

"Usable" means: supports the language; on disk (D-6); for Parakeet, outgoing only; for Kokoro, not while the voice clone is the outgoing voice (NF-04); for a cloud engine, cloud allowed + consent given + not marked unavailable.

**REQ-ST-03**: An engine that supports only some languages (Parakeet, Kokoro: English) SHALL apply to the directions in that language; the other direction follows the catalog.

**REQ-ST-04**: While "Use my voice" is on and the voice clone is ready, the outgoing voice SHALL be the voice clone, whatever the pair's voice choice. The pair's voice choice then applies to incoming only.

**REQ-ST-05**: The main window SHALL read "Models: Custom" when the current pair has any stored choice, else "Models: Recommended".

**REQ-ST-06**: The global manual mode SHALL be removed: the key `tlk.models.automatic`, `preferredEngine` / `setPreferredEngine` / `setAutomatic` on both selectors and the keys `tlk.stt.engine` / `tlk.tts.engine` are no longer read. Existing values are ignored (they already were since feature 1).

### FR-ST.2 — The "Advanced…" models sheet

**REQ-ST-10**: "Advanced…" in the main window's language section SHALL open the sheet "Models for <A> ↔ <B>" for the current pair, as a sheet on the main window (prototype `yReTP` / `XpYEw`). Settings › Advanced SHALL open the same sheet for the pair the user clicks.

**REQ-ST-11**: The sheet SHALL list three stages, each with its engines as radio rows:
- **Speech recognition:** Whisper, Apple Speech, Parakeet;
- **Translation:** Apple Translation, a single row, not selectable;
- **Voice when "Use my voice" is off:** Apple voices, Kokoro, Microsoft Edge voices (only while cloud models are allowed).

**REQ-ST-12**: Each row SHALL show the engine name, then a chip line: "Recommended" on the catalog's pick for this pair, "On-device" or "Cloud", and "Tested <A> · <B>" plus "~<n> s" only when the catalog has that data (S-2).

**REQ-ST-13**: A row SHALL be disabled with a one-line reason when the engine supports neither language of the pair ("Not available for this pair."). An engine that supports one language only SHALL be selectable with the note "Used for <language> only.".

**REQ-ST-14**: A row whose model is not on this Mac SHALL show "Download · ≈<size>". Picking it starts the download in the row (progress, Cancel; no Cancel for the voice clone); when it finishes the row becomes selected. A failed download shows "Download failed" with "Try again". (S-4) While a session runs, download buttons are disabled with "Available after the call" (S-7).

**REQ-ST-15**: Picking a cloud engine for which consent has not been given SHALL ask for consent inside the sheet, with the prototype's text ("The translated text is sent to Microsoft to create the voice."). Declining leaves the previous choice.

**REQ-ST-16**: A cloud engine marked unavailable in the catalog SHALL be shown disabled with "Temporarily unavailable." (S-3).

**REQ-ST-17**: Selections SHALL be staged: **Done** stores them, **Cancel** discards them, **Reset to recommended** clears the staged choices for both stages. Downloads started in the sheet continue after Cancel or close.

**REQ-ST-18**: When "Use my voice" is on, the voice stage SHALL show the line "Your voice is used for <their language> while 'Use my voice' is on." (S-6)

### FR-ST.3 — Settings › Voices

**REQ-ST-20**: The Voices tab SHALL follow the prototype (`o3A5RO` / `G3LK2`):
- **Your voices:** one row per saved voice profile (name; "recorded <date> · <duration>"); "In use" on the active profile and "Use" on the others; a play button that plays the recording; a "…" menu with Rename… and Delete… (Delete asks to confirm). Below, "Record a new voice…". The footer reads "The voice used when 'Use my voice' is on. Voices are stored only on this Mac.";
- **Without my voice:** one "Standard voice for <language>" row per language of the current pair.

**REQ-ST-21**: "Record a new voice…" SHALL open today's voice-profile flow until feature 4.

**REQ-ST-22**: The standard voice picker SHALL list the voices of the engine in effect for that language in the current pair, plus "Automatic" (default):
- Apple voices: the installed `AVSpeechSynthesisVoice`s of that language, with their quality;
- Kokoro: its voices (today's `KokoroVoicePicker` list);
- Edge: its fixed voice, shown read-only.

The pick SHALL be stored per language and used at the next Start.

### FR-ST.4 — Settings › Advanced

**REQ-ST-30**: The Advanced tab SHALL follow the prototype (`PFRn8` / `T2mCTh`), with four sections:
1. **Models per language pair:** one row per pair, "Recommended" or "Custom · <engine>" (orange), and a chevron that opens the sheet. Footer as in the prototype;
2. **Cloud:** the "Allow cloud models" switch with the prototype's description;
3. **Speech detection:** a "Voice detector" picker: "Silero (recommended)", "Basic (energy)";
4. **Diagnostics:** the "Show speech and voice metrics" switch; "Logs" with "Export logs…"; "Setup" with "Run setup again…".

**REQ-ST-31**: The pairs listed SHALL be: the three priority pairs (ES ↔ EN, DE ↔ EN, ES ↔ DE), the current pair and every pair with a stored choice, without duplicates.

**REQ-ST-32**: "Allow cloud models" SHALL default to off. Off: no cloud engine appears in the sheet and no cloud engine is used, including the existing Edge fallback for languages without a system voice; stored cloud choices are kept but ignored. On: cloud engines appear, each asking for consent the first time it is picked (REQ-ST-15). An install where Edge consent was already given starts with the switch on.

**REQ-ST-33**: The voice detector choice SHALL apply at the next Start. Silero keeps today's energy fallback when its model can't load.

**REQ-ST-34**: With "Show speech and voice metrics" on, the tab SHALL show today's STT and TTS metrics and the TTS monitor below the switch.

**REQ-ST-35**: "Export logs…" SHALL save the app's own log entries (its OSLog subsystem) since the current launch to a text file the user picks with a save panel. The row's description reads "Logs since TranslateCall started." (S-8)

**REQ-ST-36**: "Run setup again…" SHALL open today's setup wizard until feature 3.

### FR-ST.5 — Cloud signal

**REQ-ST-40**: When a cloud engine will be used for the current pair, the main window's models line SHALL read "Models: Custom · Cloud", and the existing in-call cloud indicators stay as they are.

### FR-ST.6 — Removal and continuity

**REQ-ST-50**: The "Advanced (legacy)" tab, `LegacyAdvancedSettingsView`, `LegacyEngineChoice` and `Legacy/ModelDownloadSheets` SHALL be removed. The metrics views, the TTS monitor row and the Kokoro voice picker move to their new homes.

**REQ-ST-51**: Settings SHALL have three tabs: General, Voices, Advanced. A stored tab value that no longer exists (`advancedLegacy`) SHALL open Advanced.

**REQ-ST-52**: The "Usage guide" link SHALL move to the Help menu ("TranslateCall Help").

### FR-ST.7 — Backlog items (S-5)

**REQ-ST-60 (UI-B9)**:
- the Open-at-login status is re-read when Settings appears and when the app becomes active;
- the per-language pack checks in General run concurrently;
- the microphone picker has a valid tag for "System default" (no nil-tag warning);
- `SettingsView` binds the tab as `SettingsTab`, not a raw `String`.

**REQ-ST-61 (UI-B4, preloader part)**:
- a failed preload is not recorded as loaded and is retried on the next trigger;
- the preloader re-runs on: a pair change, a stored-choice change, "Use my voice" or the active profile changing, a download finishing, and the cloud switch changing.

## Non-Functional Requirements

**NFR-ST-01**: No model is ever downloaded without a user action in the sheet, the voice section or "Use my voice" (D-6).

**NFR-ST-02**: Nothing in this feature runs a cloud engine without the switch on and consent given (brief, "Privacy").

**NFR-ST-03**: Every new view has Xcode previews in light and dark, with fixtures for each state of the prototype, and is compared with the pencil frames before review.

**NFR-ST-04**: Text fitting follows the brief's rules; single-line labels truncate, notes wrap.

**NFR-ST-05**: Line budgets hold (SwiftLint 400-line file limit). New behaviour goes in new files or extensions, never in `AudioCoordinator+Pipeline.swift`.

## Out of scope

- Fixing Edge TTS (A27): a separate fix PR.
- Model deletion and a "Models on this Mac" list.
- Real progress for Parakeet, Kokoro and the voice clone downloads.
- Choosing the Whisper model size.
- UI-B1…B3 (pause and concurrency), UI-L1 (latency).
- The teleprompter recording flow (feature 4) and the first-run assistant (feature 3).
