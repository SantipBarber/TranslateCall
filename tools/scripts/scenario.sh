#!/usr/bin/env bash
# Scenario tests (M9 scenario-tests design §3.3): the production pipeline in real time with an acoustic
# path, checked by rules. Usage: scenario.sh <name[,name…]|all>   Exits 1 when a rule fails.
# TC_SCENARIO_REFERENCE=<file>.wav (24 kHz mono + <file>.txt) clones that recording instead of the active profile.
set -Eeuo pipefail
cd "$(git rev-parse --show-toplevel)"

names=${1:?usage: just scenario <name|all>}
read -r -a xcb <<<"$(just --evaluate xcb)"
# Release, like the bench: Debug runs the voice clone ~2.3x slower.
xcb+=(-configuration Release ENABLE_TESTABILITY=YES)

commit=$(git rev-parse --short HEAD)
out=build/scenarios/$(date -u +%Y-%m-%dT%H-%M-%SZ)-$commit
mkdir -p "$out" build/logs
cache=${TC_BENCH_CACHE:-$HOME/Library/Caches/TranslateCallBench}
manifest=$PWD/bench/manifests/phase1.json

uv run --locked --project tools/bench tcbench fetch --set pr --manifest "$manifest" >/dev/null

echo "━━ build ━━"
"${xcb[@]}" build-for-testing -testPlan Bench 2>&1 | tee build/logs/scenario-build.log | xcbeautify --quiet

echo "━━ run $names ━━"
rm -rf build/logs/scenario.xcresult
set +e
TEST_RUNNER_TC_SCENARIO=$names TEST_RUNNER_TC_SCENARIO_REFERENCE=${TC_SCENARIO_REFERENCE:-} TEST_RUNNER_TC_BENCH_OUT=$PWD/$out TEST_RUNNER_TC_BENCH_CACHE=$cache \
TEST_RUNNER_TC_BENCH_MANIFEST=$manifest TEST_RUNNER_TC_COMMIT=$commit \
  "${xcb[@]}" test-without-building -testPlan Bench -only-testing:TranslateCallTests/BenchTests/ScenarioTests \
  -resultBundlePath build/logs/scenario.xcresult >build/logs/scenario.log 2>&1
code=$?
set -e

echo "━━ verdict ━━"
grep -h '^SCENARIO ' build/logs/scenario.log || echo "(no scenario output — see build/logs/scenario.log)"
echo "run dir: $out   log: build/logs/scenario.log"
exit "$code"
