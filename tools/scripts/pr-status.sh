#!/usr/bin/env bash
# Publish commit status `local/just-pr` (REQ-W-42).
# Usage: pr-status.sh <pending|success|failure|error> <description> <sha>
set -euo pipefail
state=$1; desc=$2; sha=$3
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh api -X POST "repos/$repo/statuses/$sha" \
  -f state="$state" -f context="local/just-pr" -f description="${desc:0:140}" >/dev/null
echo "• status local/just-pr=$state on ${sha:0:7}"
