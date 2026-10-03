#!/usr/bin/env bash
# Run selected unit tests quickly. Usage: test-only.sh <Suite>[/<test()>] ...
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
args=(); for t in "$@"; do args+=("-only-testing:TranslateCallTests/$t"); done
xcodebuild -project TranslateCall.xcodeproj -scheme TranslateCall -destination platform=macOS \
  -derivedDataPath build/DerivedData test -testPlan Unit "${args[@]}" 2>&1 | xcbeautify --quiet
