#!/usr/bin/env bash
# Benchmark harness entry point (M9 REQ-BH-60): fetch → build → run in real time → analyse → report → compare.
# Usage: bench.sh [set=pr|full] [profile=all|basic|best] [edge=0|1] [lines=<comma-separated run-line slugs>]
# lines: outgoing-es-ES-en, outgoing-es-419-en, outgoing-en-es, incoming-en-es (empty = all).
# Exits with `tcbench compare`'s exit code (0 when there is no baseline yet).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

set_name=${1:-pr}
profile=${2:-all}
edge=${3:-0}
lines=${4:-}
[[ "$set_name" == pr || "$set_name" == full ]] || { echo "✗ set must be pr or full, got $set_name" >&2; exit 2; }
[[ "$edge" == 0 || "$edge" == 1 ]] || { echo "✗ edge must be 0 or 1, got $edge" >&2; exit 2; }
[[ "$profile" == all || "$profile" == basic || "$profile" == best ]] || { echo "✗ profile must be all, basic or best, got $profile" >&2; exit 2; }

tcbench() { uv run --locked --project tools/bench tcbench "$@"; }
# One source for the xcodebuild invocation: the justfile's `xcb` variable (word-split; no spaces in its paths).
read -r -a xcb <<<"$(just --evaluate xcb)"

# Other builds skew the latencies. Warn (stderr), keep going. Processes descended from this script are not "other".
descends_from_me() {
  local pid=$1
  while [[ "$pid" -gt 1 ]]; do
    [[ "$pid" == "$$" ]] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
    [[ -n "$pid" ]] || return 1
  done
  return 1
}
busy=()
for name in xcodebuild swift-frontend; do
  for pid in $(pgrep -x "$name" || true); do
    descends_from_me "$pid" || busy+=("$name($pid)")
  done
done
if (( ${#busy[@]} > 0 )); then
  echo "⚠ other builds are running (${busy[*]}) — latencies will be inflated. Close them for a clean run." >&2
fi

phase=prepare
out=""
failed() {
  local code=$?
  trap - ERR
  {
    echo
    echo "✗ just bench failed in phase: $phase (exit $code)"
    if [[ -n "$out" && -d "$out" ]]; then
      mv "$out" "$out-failed" && out="$out-failed"
      echo "  run dir:  $out  (renamed -failed; ignored by report trend and latest)"
    fi
    echo "  log:      build/logs/bench.log (build: build/logs/bench-build.log)"
    echo "  xcresult: build/logs/bench.xcresult"
    if [[ "$phase" == test && -d build/logs/bench.xcresult ]]; then
      echo "  failed tests:"
      xcrun xcresulttool get test-results tests --path build/logs/bench.xcresult --format json 2>/dev/null |
        python3 -c '
import json, sys
def walk(n, path):
    path = path + [n.get("name", "")]
    if n.get("nodeType") == "Test Case" and n.get("result") == "Failed":
        print("    - " + n["name"])
        for c in n.get("children", []):
            if c.get("nodeType") == "Failure Message": print("        " + c["name"].replace("\n", " ")[:400])
    for c in n.get("children", []): walk(c, path)
for n in json.load(sys.stdin).get("testNodes", []): walk(n, [])
' || echo "    (could not read the xcresult)"
    fi
  } >&2
  exit "$code"
}
trap failed ERR

echo "━━ prepare ━━"
phase=fetch
tcbench fetch --set "$set_name"
phase=estimate
uv run --locked --project tools/bench python -m tcbench.estimate "$set_name" "$profile" "$lines"

commit=$(git rev-parse --short HEAD)
run_id=$(date -u +%Y-%m-%dT%H-%M-%SZ)-$commit
out=build/bench/runs/$run_id
mkdir -p build/bench/runs build/logs
mkdir "$out"   # never reused
dirty=0; [[ -z "$(git status --porcelain)" ]] || dirty=1
cache=${TC_BENCH_CACHE:-$HOME/Library/Caches/TranslateCallBench}
xcode=$(xcodebuild -version | awk 'NR==1 {print $2}')

echo "━━ build ━━"
phase=build
"${xcb[@]}" build-for-testing -testPlan Bench 2>&1 | tee build/logs/bench-build.log | xcbeautify

echo "━━ run $run_id ━━"
phase=test
rm -rf build/logs/bench.xcresult
TEST_RUNNER_TC_BENCH_SET=$set_name TEST_RUNNER_TC_BENCH_PROFILE=$profile TEST_RUNNER_TC_BENCH_EDGE=$edge \
TEST_RUNNER_TC_BENCH_LINES=$lines TEST_RUNNER_TC_BENCH_OUT=$PWD/$out TEST_RUNNER_TC_BENCH_CACHE=$cache \
TEST_RUNNER_TC_BENCH_MANIFEST=${TC_BENCH_MANIFEST:-$PWD/bench/manifests/phase1.json} \
TEST_RUNNER_TC_COMMIT=$commit TEST_RUNNER_TC_DIRTY=$dirty TEST_RUNNER_TC_XCODE=$xcode \
  "${xcb[@]}" test-without-building -testPlan Bench -only-testing:TranslateCallTests/BenchTests/BenchRunLineTests \
  -resultBundlePath build/logs/bench.xcresult 2>&1 | tee build/logs/bench.log | xcbeautify

echo "━━ analyse ━━"
phase=analyze
if [[ "$set_name" == full ]]; then
  uv run --locked --extra comet --project tools/bench tcbench analyze "$out" --comet
else
  tcbench analyze "$out"
fi
phase=report
tcbench report "$out"
ln -sfn "$run_id" build/bench/runs/latest

echo "━━ verdict ━━"
phase=compare
if [[ ! -f bench/baseline.json ]]; then
  echo "no baseline yet — promote this run with: just bench-baseline $out \"<reason>\""
  exit 0
fi
tcbench compare "$out" || exit $?   # a regression verdict is not a failed run
