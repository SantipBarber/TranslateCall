# F1.1 - Project Setup & Build Configuration
## Technical Design

**Feature**: F1.1
**Milestone**: M1 - Foundation
**Status**: COMPLETED — 2026-03-06
**Last Updated**: 2026-03-06

---

## Architecture Decisions

### AD-1: Swift 6.0 + Strict Concurrency

**Decision**: Enable `SWIFT_STRICT_CONCURRENCY = complete` from day one.

**Rationale**: TranslateCall's audio pipeline is inherently concurrent (audio capture, VAD, STT, Translation, TTS run on separate threads/actors). Swift 6 strict concurrency catches data races at compile time. Retrofitting concurrency safety later is significantly harder than starting clean.

**Consequences**: All code must use `async/await`, `actors`, or explicit `Sendable` conformances. No escaping closures crossing actor boundaries without annotation.

### AD-2: SPM Only (No CocoaPods/Carthage)

**Decision**: Use Swift Package Manager exclusively.

**Rationale**: SPM is first-class in Xcode, supports Apple Silicon natively, integrates with CI without extra tooling, and is the only option fully supported by Swift 6.

**Consequences**: FluidAudio must be available as a Swift Package. If a dependency is not on SPM, we evaluate alternatives before adding other package managers.

### AD-3: App Sandbox Enabled

**Decision**: Enable App Sandbox from the start.

**Rationale**: Required for Mac App Store distribution (M9). Enabling it late forces a large entitlement audit. The only entitlements needed now are microphone access.

**Consequences**: Some audio APIs behave differently in sandbox (e.g., `AVCaptureDevice` requires explicit entitlement). This is acceptable and expected.

### AD-4: PrivacyInfo.xcprivacy

**Decision**: Add `PrivacyInfo.xcprivacy` now, declaring zero data collection.

**Rationale**: Apple requires a privacy manifest for apps using certain APIs (including audio). Starting with it prevents App Store rejection at M9.

---

## File Structure

```
TranslateCall/                          ← repo root
├── TranslateCall.xcodeproj
├── TranslateCall/                      ← app source
│   ├── App/
│   │   ├── TranslateCallApp.swift      ← @main entry point
│   │   └── AppDelegate.swift           ← NSApplicationDelegate (future hooks)
│   ├── Features/                       ← feature modules (F1.3+)
│   ├── Core/                           ← shared utilities
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   └── PrivacyInfo.xcprivacy
│   └── Supporting Files/
│       └── Info.plist
├── TranslateCallTests/                 ← unit tests (empty at F1.1)
├── specs/                              ← SDD specs (this file lives here)
├── docs/
├── .github/
│   └── workflows/
│       └── ci.yml
├── .swiftlint.yml
├── .swiftformat
└── README.md
```

---

## Dependency Design

### FluidAudio

```swift
// Package.swift (or via Xcode SPM UI)
.package(
    url: "https://github.com/fluidaudio/fluidaudio",
    from: "1.0.0"   // pin to latest stable at integration time
)
```

FluidAudio provides:
- `SileroVAD` — Voice Activity Detection (used in F2.1)
- `ParakeetSTT` — Speech-to-Text (used in F2.2 / M6)

At F1.1 we add the dependency but do not use it yet. This validates that SPM resolves it cleanly before we depend on it in M2.

---

## Entitlements Design

**File**: `TranslateCall/TranslateCall.entitlements`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
<plist version="1.0">
<dict>
    <!-- Sandbox: required for App Store -->
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <!-- Microphone: required for audio capture -->
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

---

## Info.plist Keys

| Key | Value | Purpose |
|-----|-------|---------|
| `NSMicrophoneUsageDescription` | "TranslateCall needs microphone access to capture your voice for translation." | Permission dialog text (required) |
| `LSMinimumSystemVersion` | `14.0` | macOS Sonoma minimum |
| `LSUIElement` | `false` (for now) | Menu bar only mode — set to `true` in M5 |

---

## SwiftLint Configuration

**File**: `.swiftlint.yml`

```yaml
disabled_rules:
  - trailing_whitespace   # handled by SwiftFormat

opt_in_rules:
  - force_unwrapping
  - implicitly_unwrapped_optional
  - prefer_self_type_over_type_of_self
  - sorted_imports

included:
  - TranslateCall

excluded:
  - TranslateCall/.build
  - TranslateCallTests

line_length:
  warning: 120
  error: 160

type_body_length:
  warning: 200
  error: 300
```

**Build Phase**: `"${PODS_ROOT}/SwiftLint/swiftlint"` → replaced with SPM-based SwiftLint run script:

```bash
if which swiftlint > /dev/null; then
  swiftlint
else
  echo "warning: SwiftLint not installed — brew install swiftlint"
fi
```

---

## GitHub Actions CI Design

**File**: `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app
      - name: Resolve dependencies
        run: xcodebuild -resolvePackageDependencies -project TranslateCall.xcodeproj -scheme TranslateCall
      - name: Build
        run: xcodebuild build -project TranslateCall.xcodeproj -scheme TranslateCall -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
      - name: Test
        run: xcodebuild test -project TranslateCall.xcodeproj -scheme TranslateCall -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

**Notes**:
- `CODE_SIGN_IDENTITY=""` disables code signing in CI (no certificates needed)
- `macos-15` runner provides Xcode 16 with Swift 6 support
- Tests are run even if empty — the command succeeds with zero tests

---

## PrivacyInfo Design

**File**: `TranslateCall/Resources/PrivacyInfo.xcprivacy`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
<plist version="1.0">
<dict>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryMicrophone</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>1.1</string>
            </array>
        </dict>
    </array>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
</dict>
</plist>
```
