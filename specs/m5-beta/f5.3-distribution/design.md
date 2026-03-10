# F5.3 – Beta Distribution: Design

**Milestone**: M5 – Beta Release
**Feature**: F5.3 – Beta Distribution
**Status**: DRAFT – Pending Gate 2 Review
**Date**: 2026-03-10

---

## 1. Architecture Overview

F5.3 introduces minimal code changes. Most work is operational (scripts, certificates, packaging):

```
project.pbxproj                     ← D1: version bump
  MARKETING_VERSION = 0.5.0
  CURRENT_PROJECT_VERSION = 1

App/TranslateCallApp.swift           ← D3: menu item for feedback
  └─ "Send Feedback" → openFeedbackURL()

scripts/
  └─ build-release.sh                ← D2: archive → sign → notarize → DMG

TranslateCall.entitlements           ← verify all entitlements included for distribution
ExportOptions.plist                  ← D2: export profile for Developer ID distribution
```

---

## 2. D1 — Version Bump

### In Xcode Project

Set both version strings in `project.pbxproj` under all build configurations:

```
MARKETING_VERSION = 0.5.0;
CURRENT_PROJECT_VERSION = 1;
```

These map to:
- `CFBundleShortVersionString` = `$(MARKETING_VERSION)` → `"0.5.0"`
- `CFBundleVersion` = `$(CURRENT_PROJECT_VERSION)` → `"1"`

The standard macOS About window (`NSApp.orderFrontStandardAboutPanel`) reads these automatically.

### Version Scheme Going Forward

```
MARKETING_VERSION: major.minor.patch (SemVer)
  0.5.0 = M5 Beta
  0.6.0 = M6 Enhanced STT/TTS
  1.0.0 = M9 Public Launch

CURRENT_PROJECT_VERSION: monotonically increasing integer
  Increment for each submitted/distributed build
```

---

## 3. D2 — Notarized DMG

### Prerequisites

Before running `build-release.sh`, the following must be set up on the developer machine:

1. **Developer ID Application certificate** in Keychain — `Developer ID Application: Your Name (TEAMID)`
2. **App Store Connect API key** in `~/.config/notarytool/` — used by `xcrun notarytool` for authentication
3. **`notarytool` credential profile** stored via:
   ```
   xcrun notarytool store-credentials "TranslateCallProfile" \
       --key /path/to/AuthKey_KEYID.p8 \
       --key-id KEYID \
       --issuer ISSUER_UUID
   ```

### `ExportOptions.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$(TEAM_ID)</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>hardened-runtime</key>
    <true/>
    <key>entitlementsFile</key>
    <string>TranslateCall/TranslateCall.entitlements</string>
</dict>
</plist>
```

Save as `scripts/ExportOptions.plist`.

### `build-release.sh`

```bash
#!/usr/bin/env bash
# TranslateCall Beta Release Build Script
# Usage: TEAM_ID=XXXXXXXX NOTARYTOOL_PROFILE=TranslateCallProfile ./scripts/build-release.sh

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
APP_NAME="TranslateCall"
VERSION="0.5.0"
BUILD_DIR="build/release"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_NAME="${APP_NAME}-${VERSION}-beta.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

# ─── Validate environment ─────────────────────────────────────────────────────
: "${TEAM_ID:?ERROR: Set TEAM_ID env var (e.g., TEAM_ID=XXXXXXXX)}"
: "${NOTARYTOOL_PROFILE:?ERROR: Set NOTARYTOOL_PROFILE env var (e.g., NOTARYTOOL_PROFILE=TranslateCallProfile)}"

command -v xcrun  >/dev/null || { echo "ERROR: xcrun not found"; exit 1; }
command -v hdiutil >/dev/null || { echo "ERROR: hdiutil not found"; exit 1; }

mkdir -p "$BUILD_DIR"

# ─── Step 1: Archive ──────────────────────────────────────────────────────────
echo "→ Archiving $APP_NAME..."
xcodebuild archive \
    -scheme "$APP_NAME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    | grep -E "(error:|warning:|Archive Succeeded|Build Succeeded)"

# ─── Step 2: Export (Developer ID) ───────────────────────────────────────────
echo "→ Exporting with Developer ID..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "scripts/ExportOptions.plist" \
    DEVELOPMENT_TEAM="$TEAM_ID"

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "ERROR: App not found at $APP_PATH"; exit 1; }

# ─── Step 3: Notarize ─────────────────────────────────────────────────────────
echo "→ Zipping for notarization..."
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "→ Submitting to Apple notarization service (may take 2–10 minutes)..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait \
    --timeout 600

echo "→ Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# ─── Step 4: Create DMG ───────────────────────────────────────────────────────
echo "→ Creating DMG..."
STAGING_DIR="$BUILD_DIR/dmg-staging"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -sf /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Sign the DMG itself
codesign --sign "Developer ID Application: $DEVELOPER_NAME ($TEAM_ID)" "$DMG_PATH" 2>/dev/null || \
    echo "  (DMG signing skipped — optional for notarized apps)"

echo ""
echo "✅ Release build complete: $DMG_PATH"
echo "   Size: $(du -sh "$DMG_PATH" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Test the DMG on a fresh macOS machine"
echo "  2. git tag v${VERSION}-beta && git push origin v${VERSION}-beta"
echo "  3. gh release create v${VERSION}-beta $DMG_PATH --prerelease --notes-file scripts/release-notes.md"
```

> **Note**: `DEVELOPER_NAME` is used for optional DMG signing — add it as an env var or derive from the cert. DMG signing is optional since the notarized `.app` inside is already trusted.

---

## 4. D3 — About Window & Feedback

### Standard `orderFrontStandardAboutPanel`

macOS provides a standard About window automatically from `Info.plist` keys:
- `NSHumanReadableCopyright` → `"© 2026 TranslateCall"`
- `CFBundleShortVersionString` → shown as version
- `NSAboutPanelOptionApplicationIcon` → auto from app icon

The standard panel is triggered by `NSApp.orderFrontStandardAboutPanel(nil)` which macOS hooks to "About TranslateCall" in the application menu automatically.

No custom view is needed for the basic About panel.

### Feedback Integration

Add a "Send Feedback…" item to the **Help** menu:

```swift
// App/TranslateCallApp.swift (MODIFY)

var body: some Scene {
    // ... existing WindowGroup ...

    // NEW: Commands block for menu customization
    .commands {
        CommandGroup(after: .help) {
            Button("Send Feedback…") {
                openFeedbackURL()
            }
        }
    }
}

private func openFeedbackURL() {
    let sysInfo = buildSystemInfo()
    let bodyTemplate = """
        **App Version**: \(appVersion)
        **macOS**: \(sysInfo.osVersion)
        **Hardware**: \(sysInfo.hardwareModel)

        **Description**:
        <!-- Describe the bug or feedback -->

        **Steps to reproduce**:
        1.
        2.
        3.

        **Expected behavior**:

        **Actual behavior**:
        """
    let encoded = bodyTemplate.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let urlString = "https://github.com/OWNER/TranslateCall/issues/new?body=\(encoded)"
    if let url = URL(string: urlString) {
        NSWorkspace.shared.open(url)
    }
}

private var appVersion: String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    return "\(version) (\(build))"
}

private struct SystemInfo {
    let osVersion: String
    let hardwareModel: String
}

private func buildSystemInfo() -> SystemInfo {
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    var hwModel = "Unknown"
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    hwModel = String(cString: buffer)
    return SystemInfo(osVersion: osVersion, hardwareModel: hwModel)
}
```

> Replace `OWNER` with the actual GitHub username/org before release.

### `NSHumanReadableCopyright` in `project.pbxproj`

Add via `INFOPLIST_KEY_NSHumanReadableCopyright = "© 2026 TranslateCall";` in the `pbxproj` Build Settings (same pattern as other `INFOPLIST_KEY_*` keys already in the project).

---

## 5. D4 — GitHub Release

### Tagging and Release Process

After the DMG is built and tested:

```bash
# 1. Tag the release commit
git tag -s v0.5.0-beta -m "M5 Beta Release — bidirectional translation with setup wizard"
git push origin v0.5.0-beta

# 2. Create GitHub Release with DMG
gh release create v0.5.0-beta \
    "build/release/TranslateCall-0.5.0-beta.dmg" \
    --title "TranslateCall v0.5.0 Beta" \
    --notes-file scripts/release-notes.md \
    --prerelease
```

### `scripts/release-notes.md`

A template file committed to the repo (content from requirements §7 release notes template).

---

## 6. File Map

| File | Change | Notes |
|------|--------|-------|
| `TranslateCall.xcodeproj/project.pbxproj` | **MODIFY** | Set `MARKETING_VERSION = 0.5.0`, `CURRENT_PROJECT_VERSION = 1` |
| `App/TranslateCallApp.swift` | **MODIFY** | Add `.commands {}` with "Send Feedback…" menu item + helper functions |
| `scripts/build-release.sh` | **CREATE** | End-to-end release build script |
| `scripts/ExportOptions.plist` | **CREATE** | Xcode export options for Developer ID distribution |
| `scripts/release-notes.md` | **CREATE** | Release notes template for GitHub Release |

---

## 7. Entitlements Verification

Before notarization, verify all entitlements in `TranslateCall.entitlements` are correctly set for hardened runtime:

| Entitlement | Value | Purpose |
|-------------|-------|---------|
| `com.apple.security.device.audio-input` | `true` | Microphone capture |
| `com.apple.security.speech-recognition` | `true` | Apple Speech STT |
| `com.apple.security.screen-capture` | `true` | SCShareableContent for incoming audio |
| `com.apple.security.app-sandbox` | — | **NOT set** — sandbox incompatible with virtual audio routing |

> **Note**: Hardened runtime (`--options runtime` in codesign / `hardened-runtime: true` in ExportOptions) IS compatible with the above entitlements. The app does NOT use the App Sandbox (which would conflict with BlackHole routing).

---

## 8. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| No Developer ID cert available | Medium | High (blocks D2) | Verify with owner before starting F5.3; if unavailable, ship internal DMG with ad-hoc signing only |
| Notarization rejection (entitlement missing) | Low | Medium | Pre-validate with `codesign --verify --deep --strict` before submitting |
| `notarytool submit` timeout (>10 min) | Low | Low | Retry; Apple's pipeline is usually fast |
| GitHub Issues URL too long (encoded body) | Low | Low | Truncate body template or use a URL shortener; GitHub supports long URLs |
| `sysctlbyname("hw.model")` returns empty on some Macs | Very Low | Low | Fallback to `"Unknown"` already in code |

---

*End of F5.3 Design — Gate 2 Review Pending*
