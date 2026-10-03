#!/usr/bin/env bash
# Install / verify development tooling. Usage: setup.sh [--ci]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source tools/versions.env

CI_MODE=false; [[ "${1:-}" == "--ci" ]] && CI_MODE=true
fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }
info() { echo "• $*"; }

install_opengrep() {
  local asset sha
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) asset=opengrep_osx_arm64;     sha=$OPENGREP_SHA256_OSX_ARM64 ;;
    Linux-x86_64) asset=opengrep_manylinux_x86; sha=$OPENGREP_SHA256_LINUX_X86 ;;
    *) fail "Unsupported platform $(uname -s)-$(uname -m) for opengrep" ;;
  esac
  sha=${OPENGREP_SHA_OVERRIDE:-$sha}   # test hook for the checksum guard
  mkdir -p tools/bin
  if [[ -x tools/bin/opengrep && "$(tools/bin/opengrep --version 2>/dev/null)" == *"$OPENGREP_VERSION"* ]]; then
    ok "opengrep $OPENGREP_VERSION"; return
  fi
  curl -fsSL -o tools/bin/opengrep.tmp \
    "https://github.com/opengrep/opengrep/releases/download/v${OPENGREP_VERSION}/${asset}"
  echo "${sha}  tools/bin/opengrep.tmp" | shasum -a 256 -c - >/dev/null 2>&1 \
    || { rm -f tools/bin/opengrep.tmp; fail "opengrep checksum mismatch — refusing to install"; }
  mv tools/bin/opengrep.tmp tools/bin/opengrep && chmod +x tools/bin/opengrep
  ok "opengrep $OPENGREP_VERSION installed"
}

install_opengrep
$CI_MODE && exit 0

command -v brew >/dev/null || fail "Homebrew required: https://brew.sh"
for tool in swiftlint xcbeautify; do
  command -v "$tool" >/dev/null || brew install "$tool"
done
[[ "$(swiftlint version)" == "$SWIFTLINT_VERSION" ]] \
  || fail "swiftlint $(swiftlint version) ≠ pinned $SWIFTLINT_VERSION (brew upgrade swiftlint or update tools/versions.env in a PR)"
ok "swiftlint $SWIFTLINT_VERSION"
[[ "$(xcbeautify --version)" == *"$XCBEAUTIFY_VERSION"* ]] \
  || fail "xcbeautify $(xcbeautify --version) ≠ pinned $XCBEAUTIFY_VERSION"
ok "xcbeautify $XCBEAUTIFY_VERSION"

# Capture before matching: `cmd | grep -q` can SIGPIPE `cmd` and trip pipefail.
xcode=$(xcodebuild -version); xcode=${xcode%%$'\n'*}
[[ "$xcode" == "Xcode $XCODE_VERSION" ]] || fail "Xcode $XCODE_VERSION required (found: $xcode)"
ok "Xcode $XCODE_VERSION"
# `xcrun -f metal` finds a stub even without the toolchain; only running it proves it is installed.
if ! xcrun metal --version >/dev/null 2>&1; then
  info "Installing Metal Toolchain (needed by mlx-swift)…"
  xcodebuild -downloadComponent MetalToolchain
fi
ok "Metal Toolchain"

# Informational only (needed by `just fixtures` / manual call tests)
audio=$(system_profiler SPAudioDataType 2>/dev/null || true)  # informational probe only
if [[ "$audio" == *"BlackHole 2ch"* ]]; then ok "BlackHole 2ch"; else info "BlackHole 2ch not found (brew install blackhole-2ch) — only needed for live calls"; fi
voices=$(say -v '?')
for v in "Mónica" "Samantha" "Lesya"; do
  if grep -q "^$v " <<<"$voices"; then ok "voice $v"; else info "voice $v missing — install it from System Settings (search \"Voices\"); needed by just fixtures"; fi
done
