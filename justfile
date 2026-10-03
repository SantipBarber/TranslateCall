set shell := ["bash", "-euo", "pipefail", "-c"]

derived := "build/DerivedData"
xcb := "xcodebuild -project TranslateCall.xcodeproj -scheme TranslateCall -destination platform=macOS -derivedDataPath " + derived

# List recipes
default:
    @just --list

# Install / verify tooling (opengrep, swiftlint, xcbeautify, Metal Toolchain)
setup:
    tools/scripts/setup.sh

# Debug build of the app
build:
    mkdir -p build/logs
    {{xcb}} build 2>&1 | tee build/logs/build.log | xcbeautify

# Unit tier (fast, no network/mic/models).
# Tier selection lives here: xctestplan selectedTests/skippedTests don't match Swift Testing suites (Xcode 27).
test:
    rm -rf build/logs/unit.xcresult
    mkdir -p build/logs
    {{xcb}} test -testPlan Unit -skip-testing:TranslateCallTests/IntegrationTests -resultBundlePath build/logs/unit.xcresult 2>&1 | tee build/logs/test-unit.log | xcbeautify

# Integration tier (real frameworks + audio fixtures)
test-integration:
    rm -rf build/logs/integration.xcresult
    mkdir -p build/logs build/reports
    {{xcb}} test -testPlan Integration -only-testing:TranslateCallTests/IntegrationTests -resultBundlePath build/logs/integration.xcresult 2>&1 | tee build/logs/test-integration.log | xcbeautify

# SwiftLint, strict (warnings fail)
lint:
    swiftlint lint --strict --quiet

# opengrep static analysis (ERROR fails, WARNING reported)
scan:
    tools/scripts/scan.sh

# Everything GitHub runs: lint + scan
check: lint scan

# Run selected unit tests, e.g. `just test-only WordErrorRateTests FileAudioSourceTests`
test-only +suites:
    tools/scripts/test-only.sh {{suites}}
