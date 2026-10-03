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
