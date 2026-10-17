"""`tcbench fetch`: materialise manifest clips into the local cache as 16 kHz mono 16-bit WAV (REQ-BH-02, 05, 06)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from . import audio as audio_mod
from .sources import ALLOWED_LICENCES, audio_source


def _fail(msg: str) -> None:
    print(f"tcbench fetch: {msg}", file=sys.stderr)
    raise SystemExit(1)


def load_licences(path: Path) -> dict:
    if not path.exists():
        _fail(f"licence list {path} not found; refusing every source")
    return {e["id"]: e for e in json.loads(path.read_text(encoding="utf-8"))["sources"]}


def run(manifest_path, cache_dir, set_name: str = "pr", limit: int | None = None, providers=None, licences_path=None) -> None:
    """Idempotent. `providers` maps dataset name -> object with raw_audio(original_ids) (tests inject stubs)."""
    manifest_path, cache_dir = Path(manifest_path), Path(cache_dir)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    licences = load_licences(Path(licences_path) if licences_path else manifest_path.parent.parent / "licences.json")
    clips = [c for c in manifest["clips"] if set_name == "full" or set_name in c["tiers"]]
    if limit is not None:
        clips = clips[:limit]

    for ds in sorted({c["source"]["dataset"] for c in clips}):
        entry = licences.get(ds)
        if entry is None or entry["licence"] not in ALLOWED_LICENCES:
            _fail(f"source {ds!r} is not in the licence allow-list (bench/licences.json); refusing to fetch it")

    todo = []
    for c in clips:
        target = cache_dir / c["audio"]
        if target.exists():
            if audio_mod.sha256(target) != c["sha256"]:
                _fail(f"clip {c['id']} ({c['source']['dataset']}): cached file {target} does not match sha256 in the manifest; delete it to refetch")
        else:
            todo.append(c)

    if not todo:
        print(f"up to date: {len(clips)} clips in {cache_dir} (set {set_name})")
        return

    by_ds: dict[str, list[dict]] = {}
    for c in todo:
        by_ds.setdefault(c["source"]["dataset"], []).append(c)
    for ds, group in sorted(by_ds.items()):
        print(f"fetching {len(group)} clips from {ds} ...", flush=True)
        try:
            provider = (providers or {}).get(ds) or audio_source(ds, cache_dir)
            raw = provider.raw_audio([c["source"]["originalId"] for c in group])
        except SystemExit:
            raise
        except Exception as e:  # noqa: BLE001 - name the source, whatever failed
            _fail(f"download error for source {ds!r}: {type(e).__name__}: {e}")
        for c in group:
            target = cache_dir / c["audio"]
            partial = target.with_suffix(".wav.part")
            try:
                audio_mod.write_wav16(partial, audio_mod.normalize(raw[c["source"]["originalId"]]))
            except Exception as e:  # noqa: BLE001
                partial.unlink(missing_ok=True)
                _fail(f"clip {c['id']} ({ds}): cannot decode audio: {e}")
            if audio_mod.sha256(partial) != c["sha256"]:
                partial.unlink(missing_ok=True)
                _fail(f"clip {c['id']} ({ds}): sha256 mismatch after normalisation; the source or the toolchain changed")
            partial.replace(target)
    print(f"fetched {len(todo)} clips ({len(clips) - len(todo)} already cached) into {cache_dir}")
