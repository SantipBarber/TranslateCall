set shell := ["bash", "-euo", "pipefail", "-c"]

derived := "build/DerivedData"
xcb := "xcodebuild -project TranslateCall.xcodeproj -scheme TranslateCall -destination platform=macOS -derivedDataPath " + derived

# List recipes
default:
    @just --list

# Install / verify tooling (opengrep, uv, swiftlint, xcbeautify, Metal Toolchain)
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
    {{xcb}} test -testPlan Unit -skip-testing:TranslateCallTests/IntegrationTests -skip-testing:TranslateCallTests/BenchTests -resultBundlePath build/logs/unit.xcresult 2>&1 | tee build/logs/test-unit.log | xcbeautify

# Integration tier (real frameworks + audio fixtures)
test-integration:
    rm -rf build/logs/integration.xcresult
    mkdir -p build/logs build/reports
    {{xcb}} test -testPlan Integration -only-testing:TranslateCallTests/IntegrationTests \
      -resultBundlePath build/logs/integration.xcresult 2>&1 | tee build/logs/test-integration.log | xcbeautify

# SwiftLint, strict (warnings fail)
lint:
    swiftlint lint --strict --quiet

# opengrep static analysis (ERROR fails, WARNING reported)
scan:
    tools/scripts/scan.sh

# Self-tests of the PR gate scripts (no network: throwaway clones, stubbed GitHub)
test-tooling:
    tools/scripts/test-pr-guards.sh
    tools/scripts/test-pr-gate.sh

# Python benchmark tooling tests (tools/bench; no network)
test-bench-tools:
    uv run --locked --project tools/bench pytest -q

# Download + normalise manifest clips into ~/Library/Caches/TranslateCallBench (override: TC_BENCH_CACHE). set: pr | full
bench-fetch set="pr":
    uv run --locked --project tools/bench tcbench fetch --set {{quote(set)}}

# Regenerate bench/manifests/phase1.json (needs the optional 'vad' extra: silero-vad)
bench-manifest:
    uv run --locked --extra vad --project tools/bench tcbench manifest

# Benchmark: fetch → build → real-time Swift tier → analyze → report → compare. set: pr | full;
# (bench.sh reads the xcodebuild invocation from `xcb` above: one source.)
# profile: all | basic | best; lines: comma-separated slugs, e.g. outgoing-es-419-en,incoming-en-es (empty = all)
bench set="pr" profile="all" edge="0" lines="":
    tools/scripts/bench.sh {{quote(set)}} {{quote(profile)}} {{quote(edge)}} {{quote(lines)}}

# Import recordings of a variant for the benchmark (e.g. native speakers)
bench-ingest dir variant native="false":
    uv run --locked --project tools/bench tcbench ingest {{quote(dir)}} --variant {{quote(variant)}} --native {{quote(native)}}

# Compare a run (default: the latest) with bench/baseline.json
bench-compare run="build/bench/runs/latest":
    uv run --locked --project tools/bench tcbench compare {{quote(run)}}

# Rewrite report.html of a run (default: the latest)
bench-report run="build/bench/runs/latest":
    uv run --locked --project tools/bench tcbench report {{quote(run)}}

# Promote a run to bench/baseline.json
bench-baseline run reason:
    uv run --locked --project tools/bench tcbench baseline {{quote(run)}} --reason {{quote(reason)}}

# Everything GitHub runs: lint + scan + tooling self-tests + bench tooling tests
check: lint scan test-tooling test-bench-tools

# Run selected unit tests, e.g. `just test-only WordErrorRateTests FileAudioSourceTests`
test-only +suites:
    tools/scripts/test-only.sh {{suites}}

# Regenerate audio fixtures (needs voices Mónica, Samantha, Lesya)
fixtures:
    tools/scripts/fixtures.sh

# Full PR gate: build → check → test → test-integration → bench → status on SHA → push → PR
pr:
    tools/scripts/pr.sh
