#!/usr/bin/env bash
# Qwen reference-length probe (REQ-QS-30): Release build like the bench, then the opt-in probe suite.
# Reads build/qwen-probe/refs/<n>s.wav + <n>s.txt (plus the active voice profile as 31s); writes
# build/qwen-probe/<timestamp>/<n>s/<lang>-s<k>-<cold|warm>.wav and summary.md.
set -Eeuo pipefail
cd "$(git rev-parse --show-toplevel)"

phase=checks
failed() {
  local code=$?
  trap - ERR
  {
    echo
    echo "✗ just qwen-probe failed in phase: $phase (exit $code)"
    echo "  logs: build/logs/qwen-probe-build.log (build), build/logs/qwen-probe.log (test)"
    echo "  xcresult: build/logs/qwen-probe.xcresult"
  } >&2
  exit "$code"
}
trap failed ERR
die() { echo "✗ $*" >&2; exit 2; }

read -r -a xcb <<<"$(just --evaluate xcb)"
# Same Release settings as bench.sh (same DerivedData, so no second build from scratch).
xcb+=(-configuration Release ENABLE_TESTABILITY=YES)

# The probe needs the user's active voice profile (UserDefaults of the app) and the Qwen model on disk
# (ModelCache.mlxAudioDirectory + hasMLXWeights); it must never start a silent download.
profile_id=$(defaults read "$HOME/Library/Preferences/com.spbarber.TranslateCall" tlk.voiceCloning.activeProfileId 2>/dev/null || true)
[[ -n "$profile_id" ]] || die "no active voice profile (tlk.voiceCloning.activeProfileId): create or select your voice in the app first."
repo=$(sed -n 's/.*modelRepo: String = "\(.*\)".*/\1/p' TranslateCall/Core/VoiceCloning/QwenCloneConfiguration.swift)
model_dir=$HOME/.cache/huggingface/hub/mlx-audio/${repo//\//_}
if [[ ! -s "$model_dir/config.json" ]] || ! compgen -G "$model_dir/*.safetensors" >/dev/null \
   || [[ -z "$(find "$model_dir" -maxdepth 1 -name '*.safetensors' -size +0 | head -1)" ]]; then
  die "Qwen model $repo is not on disk ($model_dir): download it from the app first (the probe does not download)."
fi

refs=$PWD/build/qwen-probe/refs
mkdir -p build/logs "$refs"
out=$PWD/build/qwen-probe/$(date -u +%Y-%m-%dT%H-%M-%SZ)

phase=build
echo "━━ build ━━"
"${xcb[@]}" build-for-testing -testPlan Bench 2>&1 | tee build/logs/qwen-probe-build.log | xcbeautify

phase=test
echo "━━ probe ━━"
rm -rf build/logs/qwen-probe.xcresult
TEST_RUNNER_TC_QWEN_PROBE=1 TEST_RUNNER_TC_QWEN_PROBE_MODE=${TC_QWEN_PROBE_MODE:-} TEST_RUNNER_TC_QWEN_PROBE_REFS=${TC_QWEN_PROBE_REFS:-$refs} \
TEST_RUNNER_TC_QWEN_PROBE_OUT=$out \
  "${xcb[@]}" test-without-building -testPlan Bench -only-testing:TranslateCallTests/QwenCloneProbeTests \
  -resultBundlePath build/logs/qwen-probe.xcresult 2>&1 | tee build/logs/qwen-probe.log | xcbeautify

phase=summary
if [[ "${TC_QWEN_PROBE_MODE:-}" == pitch ]]; then echo "wavs: $out"; exit 0; fi
[[ -s "$out/summary.md" ]] || die "the probe did not write $out/summary.md (see build/logs/qwen-probe.log)."
echo "summary: $out/summary.md"
