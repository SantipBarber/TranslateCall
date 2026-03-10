# F5.3 – Beta Distribution: Tasks

**Milestone**: M5 – Beta Release
**Feature**: F5.3 – Beta Distribution
**Status**: DRAFT – Pending Gate 3 Review
**Date**: 2026-03-10

---

## Task Summary

| ID | Title | Files | Depends |
|----|-------|-------|---------|
| T1 | Version bump — `MARKETING_VERSION = 0.5.0` | `project.pbxproj` | — |
| T2 | Copyright key in `Info.plist` build settings | `project.pbxproj` | T1 |
| T3 | "Send Feedback…" menu item + system info helper | `App/TranslateCallApp.swift` | — |
| T4 | `ExportOptions.plist` for Developer ID export | `scripts/ExportOptions.plist` | — |
| T5 | `build-release.sh` end-to-end release script | `scripts/build-release.sh` | T4 |
| T6 | `release-notes.md` template | `scripts/release-notes.md` | — |
| T7 | Entitlements verification + hardened runtime smoke test | `TranslateCall.entitlements` | T1 |
| T8 | Full build → notarize → DMG run (manual, requires cert) | — | T1–T7 |
| T9 | GitHub Release: tag + upload DMG | — | T8 |
| T10 | ROADMAP update + memory update + M5 complete commit | — | T1–T9 |

---

## T1 — Version Bump

**File**: `TranslateCall.xcodeproj/project.pbxproj` (MODIFY)

### Checklist

- [ ] Find the `MARKETING_VERSION` key in `project.pbxproj` (appears in both Debug and Release build configurations)
- [ ] Set `MARKETING_VERSION = 0.5.0;` in all configurations (Debug, Release) for the main app target
- [ ] Find `CURRENT_PROJECT_VERSION` and set to `1` (or increment if already set)
- [ ] Verify: open Xcode → Target → General → Identity → Version shows `0.5.0`, Build shows `1`
- [ ] Build passes

---

## T2 — Copyright + About Panel Keys

**File**: `TranslateCall.xcodeproj/project.pbxproj` (MODIFY)

### Checklist

- [ ] Add `INFOPLIST_KEY_NSHumanReadableCopyright = "© 2026 TranslateCall";` to build settings (same pattern as existing `INFOPLIST_KEY_*` keys)
- [ ] Verify: open macOS "Get Info" on the built app bundle → Copyright shows `© 2026 TranslateCall`
- [ ] Verify: `NSApp.orderFrontStandardAboutPanel(nil)` (trigger from "About TranslateCall" menu) shows:
  - App name: TranslateCall
  - Version: 0.5.0 (1)
  - Copyright: © 2026 TranslateCall
- [ ] Build passes

---

## T3 — "Send Feedback…" Menu Item

**File**: `TranslateCall/App/TranslateCallApp.swift` (MODIFY)

### Checklist

> **Note**: Replace `OWNER` with the actual GitHub username/org before committing.

- [ ] Add `.commands { }` modifier to the `WindowGroup` scene
- [ ] Inside `.commands`, add `CommandGroup(after: .help)` with a `Button("Send Feedback…")`
- [ ] Implement `openFeedbackURL()` function (or method) in `TranslateCallApp`:
  - Build `bodyTemplate` string with: `**App Version**: \(appVersion)`, `**macOS**: \(osVersion)`, `**Hardware**: \(hwModel)`, plus blank sections for Description, Steps, Expected, Actual
  - URL-encode the body: `.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`
  - Construct URL: `"https://github.com/OWNER/TranslateCall/issues/new?body=\(encoded)"`
  - Open via `NSWorkspace.shared.open(url)`
- [ ] Implement `var appVersion: String`: reads `CFBundleShortVersionString` + `CFBundleVersion` from `Bundle.main.infoDictionary`
- [ ] Implement `buildSystemInfo()`:
  - `osVersion`: `ProcessInfo.processInfo.operatingSystemVersionString`
  - `hardwareModel`: via `sysctlbyname("hw.model", ...)` — use two-call pattern (size query then buffer fill)
  - Import `Darwin` for `sysctlbyname`
- [ ] Verify: "Help → Send Feedback…" opens GitHub Issues page in default browser with pre-filled template
- [ ] Verify: no crash if URL is nil or encoding fails (guard with fallback to plain issues URL)
- [ ] Build passes

---

## T4 — `ExportOptions.plist`

**File**: `scripts/ExportOptions.plist` (CREATE)

### Checklist

- [ ] Create `scripts/` directory if not present
- [ ] Create `ExportOptions.plist` with:
  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
  <plist version="1.0">
  <dict>
      <key>method</key>          <string>developer-id</string>
      <key>signingStyle</key>    <string>automatic</string>
      <key>hardened-runtime</key> <true/>
  </dict>
  </plist>
  ```
  (Note: `teamID` is passed via env var in the script, not hardcoded here)
- [ ] Verify: plist is valid XML — `plutil -lint scripts/ExportOptions.plist`

---

## T5 — `build-release.sh`

**File**: `scripts/build-release.sh` (CREATE)

### Checklist

- [ ] Create file with `#!/usr/bin/env bash` + `set -euo pipefail`
- [ ] Configuration section: `APP_NAME`, `VERSION`, `BUILD_DIR`, `ARCHIVE_PATH`, `EXPORT_PATH`, `DMG_NAME`, `DMG_PATH`
- [ ] Env var validation: `: "${TEAM_ID:?...}"`, `: "${NOTARYTOOL_PROFILE:?...}"` — fail fast with descriptive message
- [ ] Tool availability check: `command -v xcrun >/dev/null || { echo "ERROR: ..."; exit 1; }`
- [ ] Step 1 — Archive: `xcodebuild archive -scheme TranslateCall -configuration Release -archivePath "$ARCHIVE_PATH" CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID"`
- [ ] Step 2 — Export: `xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" -exportOptionsPlist "scripts/ExportOptions.plist" DEVELOPMENT_TEAM="$TEAM_ID"`
- [ ] Verify exported `.app` exists: `[ -d "$APP_PATH" ] || { echo "ERROR: ..."; exit 1; }`
- [ ] Step 3 — Notarize:
  - `ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"` (zip for submission)
  - `xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait --timeout 600`
  - `xcrun stapler staple "$APP_PATH"`
  - `xcrun stapler validate "$APP_PATH"` (verify stapling succeeded)
- [ ] Step 4 — Create DMG:
  - `mkdir -p "$STAGING_DIR"`, `cp -R "$APP_PATH" "$STAGING_DIR/"`, `ln -sf /Applications "$STAGING_DIR/Applications"`
  - `hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"`
- [ ] Echo final message with DMG path and size
- [ ] Echo "Next steps" instructions for tagging and GitHub release
- [ ] `chmod +x scripts/build-release.sh`
- [ ] Verify: script syntax check — `bash -n scripts/build-release.sh`

---

## T6 — Release Notes Template

**File**: `scripts/release-notes.md` (CREATE)

### Checklist

- [ ] Create `scripts/release-notes.md` with the full release notes template from requirements §7
- [ ] Replace all `OWNER` placeholders with actual GitHub username/org
- [ ] Verify: template is valid Markdown (renders correctly on GitHub)

---

## T7 — Entitlements Verification

**File**: `TranslateCall/TranslateCall.entitlements` (VERIFY only, no changes expected)

### Checklist

- [ ] Read current `TranslateCall.entitlements` file
- [ ] Verify it contains:
  - [ ] `com.apple.security.device.audio-input = true`
  - [ ] `com.apple.security.speech-recognition = true`
  - [ ] `com.apple.security.screen-capture = true`
  - [ ] Does NOT contain `com.apple.security.app-sandbox` (sandbox must be absent for virtual audio routing)
- [ ] If any entitlement is missing: add it and note in commit
- [ ] Hardened runtime smoke test (local, with development cert):
  ```bash
  codesign --sign "Apple Development" \
      --entitlements TranslateCall/TranslateCall.entitlements \
      --options runtime \
      --force --deep \
      build/.../TranslateCall.app
  codesign --verify --deep --strict build/.../TranslateCall.app
  spctl --assess --verbose build/.../TranslateCall.app
  ```
  - [ ] `codesign --verify` exits 0
  - [ ] `spctl` exits 0 (or reports "source=Developer ID" once signed with Developer ID cert)
- [ ] Build and run: verify all features still work (microphone, speech recognition, screen capture)

---

## T8 — Full Release Build (Manual — Requires Developer ID Cert)

**Prerequisite**: Developer ID Application certificate in Keychain + notarytool credential profile configured.

### Checklist

- [ ] Confirm `TEAM_ID` env var is set to the correct Apple Team ID
- [ ] Confirm `NOTARYTOOL_PROFILE` env var matches the stored credential profile name
- [ ] Run: `TEAM_ID=XXXXXXXX NOTARYTOOL_PROFILE=TranslateCallProfile ./scripts/build-release.sh`
- [ ] Script completes without error (all 4 steps succeed)
- [ ] Verify DMG at `build/release/TranslateCall-0.5.0-beta.dmg`
- [ ] Mount DMG: verify it contains `TranslateCall.app` and `Applications` symlink
- [ ] Verify code signature: `codesign -dvvv build/release/TranslateCall-0.5.0-beta.dmg` — confirms Developer ID
- [ ] **Gatekeeper test** (critical): copy DMG to a second Mac and open it — should open without "unidentified developer" dialog
- [ ] Launch app from DMG on second Mac: verify core features work (does not need to run a full call — just verify no crash and pipeline starts)

> **If Developer ID cert is unavailable**: Skip T8 and T9. Ship an ad-hoc signed DMG for internal testing only. Mark F5.3 as PARTIAL in ROADMAP. Create a GitHub Issue to track obtaining the cert.

---

## T9 — GitHub Release

**Requires**: `gh` CLI installed and authenticated, T8 completed.

### Checklist

- [ ] Ensure all F5.1, F5.2, and F5.3 code commits are on `main`
- [ ] Tag the release commit:
  ```bash
  git tag -s v0.5.0-beta -m "M5 Beta Release — bidirectional translation with setup wizard"
  git push origin v0.5.0-beta
  ```
- [ ] Create GitHub Release:
  ```bash
  gh release create v0.5.0-beta \
      "build/release/TranslateCall-0.5.0-beta.dmg#TranslateCall-0.5.0-beta.dmg" \
      --title "TranslateCall v0.5.0 Beta" \
      --notes-file scripts/release-notes.md \
      --prerelease
  ```
- [ ] Verify: `gh release view v0.5.0-beta` shows:
  - [ ] Title: `TranslateCall v0.5.0 Beta`
  - [ ] Asset: `TranslateCall-0.5.0-beta.dmg`
  - [ ] Tag: `v0.5.0-beta`
  - [ ] Marked as pre-release
- [ ] Copy release URL and share with beta testers

---

## T10 — ROADMAP Update + M5 Complete

### Checklist

- [ ] Update `ROADMAP.md`:
  - Mark F5.1 COMPLETED (date)
  - Mark F5.2 COMPLETED (date)
  - Mark F5.3 COMPLETED (date)
  - Mark M5 COMPLETED (date) in milestone overview
  - Update `**Status**` header at top: `M5 COMPLETED — Starting M6`
- [ ] Update `memory/MEMORY.md`:
  - Add F5.1 key decisions (LanguagePairManager Optional, captureAppsLoaded guard, languageLoader injection)
  - Add F5.2 key decisions (MenuBarController NSObject pattern, device UID persistence, suppressNextOutgoingTurn)
  - Add F5.3 key decisions (build-release.sh, ExportOptions.plist, feedback URL pattern)
  - Update Project Status section: M5 COMPLETED
  - Move any overflowing detailed notes to separate topic files (MEMORY.md is at 224 lines — over limit)
- [ ] Final commit: `git commit -m "Implement F5.3 — version bump, feedback menu, release scripts (M5 complete)"`

---

## Implementation Notes

### `sysctlbyname` Import

`sysctlbyname` is in the `Darwin` module, which is imported transitively via Foundation on macOS. No explicit `import Darwin` needed in most cases. If the compiler complains, add `import Darwin`.

### `.commands` and Menu Bar App

If the app is eventually converted to a pure menu bar app (no Dock icon — LSUIElement = true), the `.commands` modifier on `WindowGroup` may not behave as expected (no menu bar to show commands). For M5 with a Dock icon present, `.commands` works correctly.

### `hdiutil` UDZO Format

`UDZO` (compressed) is the standard format for distributable DMGs. It reduces file size significantly (typically 30–50% smaller than `UDRW`). The resulting DMG is read-only, which is correct for distribution.

### Notarization Wait Time

`xcrun notarytool submit --wait` blocks until Apple's service responds. In practice this takes 2–8 minutes. The `--timeout 600` flag provides a 10-minute timeout. If it times out, check status with:
```bash
xcrun notarytool log SUBMISSION_ID --keychain-profile "$NOTARYTOOL_PROFILE"
```

### Trimming MEMORY.md

MEMORY.md is currently at 224 lines (limit 200). Before the final commit in T10, move the F4.2 and F4.3 detailed notes to a separate `specs-notes.md` or `implementation-notes.md` file in the memory directory, and replace them with a one-line summary + link in MEMORY.md.

---

*End of F5.3 Tasks — Gate 3 Review Pending*
