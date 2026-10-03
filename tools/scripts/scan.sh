#!/usr/bin/env bash
# opengrep: rule self-tests → WARNING report → ERROR gate (REQ-W-51). Used by `just scan` and CI.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
OG=tools/bin/opengrep
RULES=.opengrep/rules
[[ -x $OG ]] || { echo "✗ opengrep missing — run: just setup" >&2; exit 1; }

# Rule self-tests: each rules/<name>.yml is tested against rules/<name>.swift.
# `opengrep test` exits 0 when it finds no tests, so require the success line explicitly.
out=$($OG test "$RULES" 2>&1) || { echo "$out" >&2; echo "✗ opengrep rule tests failed" >&2; exit 1; }
grep -q "All tests passed" <<<"$out" || { echo "$out" >&2; echo "✗ opengrep rule tests did not run" >&2; exit 1; }
echo "✓ opengrep rule tests"

echo "── warnings (tracked debt, not blocking) ──"
$OG scan --quiet --config "$RULES" --severity WARNING --exclude "$RULES" TranslateCall
echo "── errors (blocking) ──"
$OG scan --quiet --config "$RULES" --severity ERROR --error --exclude "$RULES" TranslateCall
echo "✓ no blocking findings"
