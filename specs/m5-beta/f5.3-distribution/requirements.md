# F5.3 – Beta Distribution

**Milestone**: M5 – Beta Release
**Feature**: F5.3 – Beta Distribution
**Status**: DRAFT – Pending Gate 1 Review
**Date**: 2026-03-10
**Depends on**: F5.1 (stability), F5.2 (UX polish)

---

## 1. Context & Motivation

With F5.1 and F5.2 complete, TranslateCall is stable and polished enough for external testers. F5.3 prepares the app for distribution outside the Mac App Store — a signed, notarized DMG that macOS Gatekeeper accepts without security warnings — and establishes a minimal feedback mechanism so beta testers can report issues.

The M5 beta targets a small group of invited testers (target: 10–50 people), not a public release. The distribution channel is a direct download link (e.g., GitHub Release or a shared URL). Automated update delivery and TestFlight are deferred to a later milestone.

---

## 2. Scope

**In scope for F5.3**:
- **D1: App version bump** — Set `CFBundleShortVersionString = 0.5.0`, `CFBundleVersion` = monotonically increasing integer; document version scheme
- **D2: Notarized DMG** — Create a signed and notarized DMG via `xcodebuild archive` + `xcrun notarytool` + `xcrun stapler` + `hdiutil`; document the step-by-step process as a repeatable script
- **D3: In-app feedback** — Add an "About TranslateCall" window with version info, GitHub Issues link, and basic system info snapshot (macOS version, processor) for bug reports
- **D4: GitHub Release** — Tag `v0.5.0-beta` on git, upload the notarized DMG to a GitHub Release with release notes template

**Out of scope for F5.3**:
- TestFlight distribution (requires App Store Connect submission review)
- Auto-update (Sparkle framework — M6)
- Mac App Store submission (M9)
- Crash collection service (no external dependencies in M5)
- Telemetry or usage analytics (never — privacy-first)

---

## 3. Functional Requirements

### 3.1 App Version

**FR-5.3.1** The app SHALL set `CFBundleShortVersionString` to `"0.5.0"` in `project.pbxproj`.

**FR-5.3.2** The app SHALL set `CFBundleVersion` to `"1"` (monotonically increasing integer; incremented per build) in `project.pbxproj`.

**FR-5.3.3** The app version SHALL be visible in:
- macOS "Get Info" dialog (via `CFBundleShortVersionString`)
- The "About TranslateCall" window (D3)
- The menu bar popover header (already implemented in F5.2)

### 3.2 Notarized DMG

**FR-5.3.4** The distributed DMG SHALL be code-signed with an Apple Developer ID certificate (not ad-hoc, not development).

**FR-5.3.5** The distributed DMG SHALL be notarized by Apple's notarization service so macOS Gatekeeper clears it without a security warning.

**FR-5.3.6** The DMG SHALL be stapled with the notarization ticket so it passes Gatekeeper offline.

**FR-5.3.7** The DMG SHALL contain the `TranslateCall.app` bundle and a symlink to `/Applications` for drag-to-install UX.

**FR-5.3.8** A shell script `scripts/build-release.sh` SHALL document and automate steps D1–D4 (archive → export → notarize → staple → create DMG). The script MAY require manual env vars (`DEVELOPER_ID`, `NOTARYTOOL_PROFILE`) but SHALL NOT hardcode credentials.

**FR-5.3.9** The build script SHALL fail fast with a descriptive error if required env vars or tools are missing.

### 3.3 About Window & Feedback

**FR-5.3.10** WHEN the user selects "About TranslateCall" from the application menu THEN a standard macOS About window SHALL appear with:
- App icon
- App name: "TranslateCall"
- Version: `0.5.0 (1)`
- Copyright: "© 2026 TranslateCall"
- A "Send Feedback" button that opens the GitHub Issues page in the default browser

**FR-5.3.11** The "Send Feedback" button SHALL open a pre-filled GitHub New Issue URL that includes a body template with:
- macOS version (`ProcessInfo.processInfo.operatingSystemVersionString`)
- Processor model (from `sysctl hw.model`)
- App version

**FR-5.3.12** WHEN the user selects "Help → TranslateCall Help" from the menu THEN the browser SHALL open the project README or documentation URL.

> Note: If macOS automatically generates an About window from `Info.plist` keys (`NSHumanReadableCopyright`, `CFBundleShortVersionString`), use that standard mechanism rather than a custom SwiftUI view. Only build a custom view if needed to add the feedback button.

### 3.4 GitHub Release

**FR-5.3.13** A git tag `v0.5.0-beta` SHALL be created on the `main` branch after all F5.1–F5.3 commits are merged.

**FR-5.3.14** A GitHub Release SHALL be created for `v0.5.0-beta` containing:
- The notarized `.dmg` file as a release asset
- A release notes body following the template in §6

**FR-5.3.15** The release SHALL be marked as "Pre-release" (not a production release) on GitHub.

---

## 4. Non-Functional Requirements

**NFR-5.3.1** The build script SHALL be idempotent: running it twice SHALL produce the same DMG (same app binary, same version number).

**NFR-5.3.2** The notarization step SHALL complete within 10 minutes using Apple's current notarization pipeline.

**NFR-5.3.3** The feedback URL SHALL NOT contain any user-specific data — only system info that the user explicitly copies into an issue.

**NFR-5.3.4** No crash reporting or telemetry framework SHALL be introduced in F5.3. Privacy is a core value of TranslateCall.

---

## 5. Constraints

**C-5.3.1** Notarization requires a paid Apple Developer Program membership and a Developer ID Application certificate. If these are not available at build time, D2 is blocked — document this dependency clearly.

**C-5.3.2** The build script uses `xcrun notarytool` (available Xcode 13+) — NOT the deprecated `altool`. Xcode 26 is assumed.

**C-5.3.3** The app currently uses `Apple Development` certificate (sufficient for local testing). Distribution requires a separate `Developer ID Application` certificate.

**C-5.3.4** Translation framework entitlements (`com.apple.security.screen-capture`, `com.apple.security.speech-recognition`) must be declared in the export `.plist` for notarization to succeed.

**C-5.3.5** GitHub CLI (`gh`) must be installed for the automated release creation step.

---

## 6. Acceptance Criteria

| ID | Criterion | Test Method |
|----|-----------|-------------|
| AC-5.3.1 | `CFBundleShortVersionString == "0.5.0"` | `defaults read /path/to/TranslateCall.app/Contents/Info CFBundleShortVersionString` |
| AC-5.3.2 | DMG opens on a fresh Mac without Gatekeeper warning | Manual: transfer DMG to a test Mac, open — no "unidentified developer" dialog |
| AC-5.3.3 | DMG contains app + Applications symlink | Manual: open DMG, verify both items |
| AC-5.3.4 | About window shows version and feedback button | Manual |
| AC-5.3.5 | Feedback button opens GitHub Issues with pre-filled template | Manual |
| AC-5.3.6 | `build-release.sh` runs end-to-end without manual steps | Manual on developer machine with credentials |
| AC-5.3.7 | GitHub Release tagged `v0.5.0-beta` with DMG asset | `gh release view v0.5.0-beta` |
| AC-5.3.8 | Release marked as Pre-release | GitHub UI |

---

## 7. Release Notes Template

```markdown
## TranslateCall v0.5.0-beta

**First public beta release** of TranslateCall — real-time simultaneous translation for video calls on macOS.

### What's new in this release

- Complete bidirectional translation pipeline (outgoing + incoming)
- Setup wizard for first-time BlackHole and video call configuration
- Menu bar status item for quick access during calls
- Language selection now persists across app restarts
- Keyboard shortcut `Cmd+Shift+T` to start/stop translation

### Requirements

- macOS 15.0 (Sequoia) or later
- Apple Silicon or Intel Mac
- [BlackHole 2ch](https://existential.audio/blackhole/) virtual audio driver
- Zoom, Microsoft Teams, Google Meet, or Discord

### Known limitations

- Incoming translation requires your video call app's audio to be capturable via Screen Recording
- Translation quality depends on Apple's on-device language models (must be downloaded)
- No auto-update yet — check back for new releases

### Feedback

Found a bug? [Open an issue on GitHub](https://github.com/OWNER/TranslateCall/issues/new)

### Privacy

TranslateCall processes all audio entirely on your device. No audio, text, or translation data is ever sent to any server.
```

---

## 8. Open Questions

| # | Question | Owner | Status |
|---|----------|-------|--------|
| OQ-1 | Is a Developer ID Application certificate currently available? | Owner | **Blocking for D2 — must confirm before starting F5.3** |
| OQ-2 | Should the About window be custom SwiftUI or standard AppKit `NSApp.orderFrontStandardAboutPanel()`? | Engineering | **Tentative: standard `orderFrontStandardAboutPanel` + feedback button via separate menu item** |
| OQ-3 | Should the GitHub Release be on an existing repo or a new one? | Owner | **Existing repo (TranslateCall)** |
| OQ-4 | Should the DMG be password-protected or open? | Security | **Open — public beta does not require protection** |

---

## 9. Dependencies

| Component | Dependency Type | Notes |
|-----------|----------------|-------|
| F5.1, F5.2 | Prerequisite | All bugs fixed and UX features implemented before packaging |
| Xcode Developer ID cert | External | Required for signing; must be in Keychain before `build-release.sh` runs |
| `xcrun notarytool` | External tool | Requires App Store Connect API key or Apple ID with app-specific password |
| `hdiutil` | System tool | Pre-installed on macOS |
| `gh` (GitHub CLI) | External tool | For automated GitHub Release creation; can be done manually |

---

*End of F5.3 Requirements — Gate 1 Review Pending*
