#!/usr/bin/env bash
# Regenerate audio fixtures from manifest.json with macOS `say` (REQ-W-31).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
DIR=TranslateCallTests/Fixtures/Audio
MANIFEST=$DIR/manifest.json
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
voices=$(say -v '?')

# One "id<TAB>voice<TAB>text" line per entry.
python3 -c 'import json,sys; [print("\t".join((e["id"], e["voice"], e["text"]))) for e in json.load(open(sys.argv[1]))]' "$MANIFEST" |
while IFS=$'\t' read -r id voice text; do
  grep -q "^$voice " <<<"$voices" \
    || { echo "✗ voice '$voice' not installed (System Settings → search \"Voices\")" >&2; exit 1; }
  say -v "$voice" -o "$TMP/$id.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/$id.aiff" "$DIR/$id.wav"
  printf '%s\n' "$text" > "$DIR/$id.txt"
  dur=$(afinfo "$DIR/$id.wav" | awk '/estimated duration/ {print $3}')
  awk -v d="$dur" 'BEGIN { exit !(d <= 8) }' || { echo "✗ $id is ${dur}s (> 8 s, REQ-W-30)" >&2; exit 1; }
  echo "✓ $id (${dur}s)"
done
