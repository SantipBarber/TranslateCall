#!/usr/bin/env bash
# Qwen reference-length probe (REQ-QS-30): Release build like the bench, then the opt-in probe suite.
# Reads build/qwen-probe/refs/<n>s.wav + <n>s.txt (plus the active voice profile as 31s); writes
# build/qwen-probe/<timestamp>/<n>s/<lang>-<k>.wav and summary.md.
set -Eeuo pipefail
cd "$(git rev-parse --show-toplevel)"

read -r -a xcb <<<"$(just --evaluate xcb)"
# Same Release settings as bench.sh (same DerivedData, so no second build from scratch).
xcb+=(-configuration Release ENABLE_TESTABILITY=YES)

mkdir -p build/logs build/qwen-probe/refs
echo "━━ build ━━"
"${xcb[@]}" build-for-testing -testPlan Bench 2>&1 | tee build/logs/qwen-probe-build.log | xcbeautify

echo "━━ probe ━━"
rm -rf build/logs/qwen-probe.xcresult
TEST_RUNNER_TC_QWEN_PROBE=1 TEST_RUNNER_TC_QWEN_PROBE_REFS=$PWD/build/qwen-probe/refs \
  "${xcb[@]}" test-without-building -testPlan Bench -only-testing:TranslateCallTests/QwenCloneProbeTests \
  -resultBundlePath build/logs/qwen-probe.xcresult 2>&1 | tee build/logs/qwen-probe.log | xcbeautify

summary=$(ls -td build/qwen-probe/*/ | grep -v /refs/ | head -1)summary.md
echo "summary: $summary"
