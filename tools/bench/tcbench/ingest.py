"""Ingest the user's own recordings into the manifest (REQ-BH-41)."""

from __future__ import annotations

import datetime
import json
import subprocess
import tempfile
from pathlib import Path

import numpy as np

from . import audio as audio_mod
from . import groundtruth
from . import manifest as manifest_mod
from . import sources

ACCEPTED_SUFFIXES = {".wav", ".m4a", ".aiff"}


def read_sheet(path) -> list[dict]:
    """Parse a prompt sheet Markdown table into rows with id, purpose, text, marks and reference."""
    rows = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line.strip().startswith("|"):
            continue
        cols = [c.strip() for c in line.split("|")[1:-1]]
        if len(cols) < 4:
            continue
        id_ = cols[0]
        if id_.lower() == "id" or id_.startswith("-"):
            continue
        text = cols[2]
        rows.append(
            {
                "id": id_,
                "purpose": cols[1],
                "text": text.replace("‖", "").strip(),
                "marks": text.count("‖"),
                "reference": cols[3],
            }
        )
    return rows


def _target_lang(variant: str) -> str:
    if variant == "es-ES":
        return "en"
    if variant == "en":
        return "es"
    raise ValueError(f"unsupported variant: {variant!r}")


def _source_lang(variant: str) -> str:
    return "es" if variant == "es-ES" else variant


def _words(text: str) -> int:
    return len(text.split())


def _normalize_file(path: Path) -> np.ndarray:
    """Decode a recording, falling back to afconvert for m4a on macOS."""
    try:
        return audio_mod.normalize(path)
    except Exception as exc:
        if path.suffix.lower() != ".m4a":
            raise
        if subprocess.run(["which", "afconvert"], capture_output=True).returncode != 0:
            raise RuntimeError(
                f"cannot decode {path.name}: soundfile failed and m4a requires afconvert (macOS)"
            ) from exc
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td) / "converted.wav"
            subprocess.run(
                ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", str(path), str(tmp)],
                check=True,
                capture_output=True,
            )
            return audio_mod.normalize(tmp)


def _count_pauses(samples: np.ndarray, span_ms: tuple[float, float]) -> int:
    """Count internal silences longer than 250 ms using the ground-truth frame-energy helper."""
    sr = audio_mod.TARGET_SR
    db = groundtruth._frame_db(samples, sr)
    n = len(db)
    start_idx = int(span_ms[0] // groundtruth.HOP_MS)
    end_idx = min(int(np.ceil(span_ms[1] / groundtruth.HOP_MS)), n)
    if end_idx <= start_idx:
        return 0
    outside = np.concatenate([db[:start_idx], db[end_idx:]])
    floor = float(np.percentile(outside if len(outside) >= 20 else db, groundtruth.FLOOR_PERCENTILE))
    peak = float(db.max())
    threshold = max(floor + groundtruth.FLOOR_MARGIN_DB, peak - groundtruth.MAX_BELOW_PEAK_DB)
    below = db < threshold
    count = 0
    i = start_idx
    while i < end_idx:
        if below[i]:
            j = i
            while j < end_idx and below[j]:
                j += 1
            if j - i > 25:  # > 250 ms
                count += 1
            i = j
        else:
            i += 1
    return count


def _process_one(
    prompt: dict,
    file: Path,
    variant: str,
    native: bool,
    cache_dir: Path,
    problems: list[str],
) -> dict | None:
    name = file.name
    try:
        samples = _normalize_file(file)
    except Exception as exc:
        problems.append(f"{name}: decode error: {exc}")
        return None

    if len(samples) == 0:
        problems.append(f"{name}: empty file")
        return None

    clipped = int(np.sum(np.abs(samples) >= 0.999))
    if clipped / len(samples) > 0.001:
        problems.append(f"{name}: clipping ({clipped} samples >= 0.999)")

    why: dict = {}
    first = groundtruth.speech_span(samples, why=why)
    if first is None:
        problems.append(f"{name}: silence only")
        return None

    gain = audio_mod.level_gain_db(samples, first)
    q = audio_mod.apply_gain_q16(samples, gain)
    final_samples = audio_mod.from_int16(q)
    why = {}
    span = groundtruth.speech_span(final_samples, why=why)
    if span is None:
        problems.append(f"{name}: silence only")
        return None

    length_s = (span[1] - span[0]) / 1000.0
    words = _words(prompt["text"])
    expected_s = words / 2.5
    if length_s < 0.5 * expected_s or length_s > 2.0 * expected_s:
        problems.append(
            f"{name}: length ratio {length_s:.2f}s outside 0.5-2.0 x {expected_s:.2f}s for {words} words"
        )

    pauses = _count_pauses(final_samples, span)
    marks = prompt["marks"]
    if abs(pauses - marks) > 1:
        problems.append(f"{name}: pause count mismatch (detected {pauses}, expected {marks})")

    clip_id = f"own-{variant}-{prompt['id']}"
    out_path = cache_dir / "own" / variant / f"{clip_id}.wav"
    audio_mod.write_wav16(out_path, q)
    sha = audio_mod.sha256(out_path)

    return {
        "id": clip_id,
        "source": {"dataset": "own", "revision": datetime.date.today().isoformat(), "originalId": name},
        "lang": _source_lang(variant),
        "variant": variant,
        "speaker": "own-user",
        "nativeSpeaker": native,
        "transcript": prompt["text"],
        "translations": {_target_lang(variant): prompt["reference"]},
        "speechStartMs": span[0],
        "speechEndMs": span[1],
        "tags": [prompt["purpose"], "own"],
        "tiers": ["full"],  # "pr" is added later based on sorted ids
        "sha256": sha,
        "licence": "own-recording",
        "audio": f"own/{variant}/{clip_id}.wav",
        "gainDb": gain,
    }


def run(
    folder: Path,
    sheet: Path,
    variant: str,
    native: bool,
    manifest_path: Path,
    cache_dir: Path | None = None,
) -> list[str]:
    """Ingest user recordings from ``folder`` into the manifest.

    Returns a list of problem strings, each including the offending file name.
    """
    folder = Path(folder)
    sheet = Path(sheet)
    manifest_path = Path(manifest_path)
    if cache_dir is None:
        cache_dir = sources.default_cache_dir()
    else:
        cache_dir = Path(cache_dir)

    prompts = {r["id"]: r for r in read_sheet(sheet)}
    files = {
        p.stem: p
        for p in folder.iterdir()
        if p.is_file() and p.suffix.lower() in ACCEPTED_SUFFIXES
    }

    problems: list[str] = []
    entries: list[dict] = []

    for prompt_id, prompt in prompts.items():
        file = files.pop(prompt_id, None)
        if file is None:
            problems.append(f"no file for prompt {prompt_id}")
            continue
        entry = _process_one(prompt, file, variant, native, cache_dir, problems)
        if entry is not None:
            entries.append(entry)

    for name in sorted(p.name for p in files.values()):
        problems.append(f"no prompt for file {name}")

    entries.sort(key=lambda e: e["id"])
    for e in entries[:8]:
        e["tiers"] = ["pr", "full"]

    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {"schema": 1, "clips": [], "mtOnly": []}
    prefix = f"own-{variant}-"
    kept = [c for c in manifest.get("clips", []) if not c["id"].startswith(prefix)]
    manifest["clips"] = kept + entries
    manifest_mod.dump(manifest, manifest_path)

    return problems
