"""Tests for tcbench.ingest."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from tcbench import groundtruth, ingest, manifest as manifest_mod

SR = 16000
REPO = Path(__file__).resolve().parents[3]


def _sheet(path: Path, rows: list[dict]) -> None:
    lines = ["| id | purpose | text | reference translation |", "|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['id']} | {r['purpose']} | {r['text']} | {r['reference']} |")
    path.write_text("\n".join(lines), encoding="utf-8")


def _wav(path: Path, seconds: float = 2.0, amplitude: float = 0.5, gaps: list[tuple[float, float]] | None = None) -> None:
    """Write a synthetic float WAV. gaps is a list of (start_s, duration_s) silent regions."""
    total = int(seconds * SR)
    samples = np.zeros(total, np.float32)
    t = np.arange(total) / SR
    tone = (amplitude * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    if gaps:
        regions: list[tuple[float, float]] = []
        cur = 0.0
        for start, dur in sorted(gaps):
            if start > cur:
                regions.append((cur, start))
            cur = max(cur, start + dur)
        if cur < seconds:
            regions.append((cur, seconds))
        for a, b in regions:
            lo, hi = int(a * SR), int(b * SR)
            samples[lo:hi] = tone[lo:hi]
    else:
        samples = tone
    sf.write(path, samples, SR, format="WAV", subtype="FLOAT")


def _manifest(path: Path) -> None:
    manifest_mod.dump({"schema": 1, "clips": [], "mtOnly": []}, path)


def test_matches_files_to_prompts(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (200.0, 1800.0))
    sheet = tmp_path / "sheet.md"
    _sheet(
        sheet,
        [
            {"id": "en-01", "purpose": "short", "text": "Yes, exactly.", "reference": "Sí, exacto."},
            {"id": "en-02", "purpose": "short", "text": "Got it.", "reference": "Entendido."},
        ],
    )
    _wav(tmp_path / "en-01.wav", seconds=2.0)
    _wav(tmp_path / "en-02.wav", seconds=2.0)
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)

    problems = ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")

    assert problems == []
    m = json.loads(manifest_path.read_text())
    assert len(m["clips"]) == 2
    ids = {c["id"] for c in m["clips"]}
    assert ids == {"own-en-en-01", "own-en-en-02"}
    assert all(c["speaker"] == "own-user" for c in m["clips"])


def test_flags_clipping(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (200.0, 1800.0))
    sheet = tmp_path / "sheet.md"
    _sheet(sheet, [{"id": "en-01", "purpose": "short", "text": "Yes.", "reference": "Sí."}])
    # amplitude 1.0 guarantees >0.1 % of samples have |x| >= 0.999
    _wav(tmp_path / "en-01.wav", seconds=1.0, amplitude=1.0)
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)

    problems = ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")

    assert any("clipping" in p and "en-01.wav" in p for p in problems)


def test_flags_silence(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: None)
    sheet = tmp_path / "sheet.md"
    _sheet(sheet, [{"id": "en-01", "purpose": "short", "text": "Yes.", "reference": "Sí."}])
    _wav(tmp_path / "en-01.wav", seconds=1.0)
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)

    problems = ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")

    assert any("silence only" in p and "en-01.wav" in p for p in problems)


def test_pause_marks_matched(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (100.0, 2500.0))
    sheet = tmp_path / "sheet.md"
    _sheet(sheet, [{"id": "en-20", "purpose": "hesitation", "text": "Friday ‖ or Monday.", "reference": "Viernes o lunes."}])
    # one internal 0.4 s silence
    _wav(tmp_path / "en-20.wav", seconds=3.0, gaps=[(1.0, 0.4)])
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)

    problems = ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")

    assert not any("pause" in p for p in problems)


def test_length_ratio_flag(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (0.0, 500.0))
    sheet = tmp_path / "sheet.md"
    _sheet(
        sheet,
        [
            {
                "id": "en-09",
                "purpose": "long",
                "text": "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty",
                "reference": "reference text here",
            }
        ],
    )
    _wav(tmp_path / "en-09.wav", seconds=1.0)
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)

    problems = ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")

    assert any("length ratio" in p for p in problems)


def test_missing_prompt_reported(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (200.0, 1800.0))
    sheet = tmp_path / "sheet.md"
    _sheet(sheet, [{"id": "en-01", "purpose": "short", "text": "Yes.", "reference": "Sí."}])
    _wav(tmp_path / "en-01.wav", seconds=2.0)
    _wav(tmp_path / "orphan.wav", seconds=2.0)
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)

    problems = ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")

    assert any("no prompt for file" in p and "orphan.wav" in p for p in problems)


def test_read_sheet_counts() -> None:
    es = ingest.read_sheet(REPO / "bench" / "prompts" / "es-ES.md")
    en = ingest.read_sheet(REPO / "bench" / "prompts" / "en.md")
    assert len(es) == 40
    assert len(en) == 40
    purposes = {"short", "long", "hesitation", "turn-end", "turn-pause", "multi-sentence"}
    assert {r["purpose"] for r in es} == purposes
    assert {r["purpose"] for r in en} == purposes


def test_entries_have_manifest_keys(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (200.0, 1800.0))
    sheet = tmp_path / "sheet.md"
    _sheet(sheet, [{"id": "en-01", "purpose": "short", "text": "Yes.", "reference": "Sí."}])
    _wav(tmp_path / "en-01.wav", seconds=2.0)
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)

    ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")

    expected = set(json.load(open(REPO / "bench" / "manifests" / "phase1.json"))["clips"][0].keys())
    m = json.loads(manifest_path.read_text())
    assert len(m["clips"]) == 1
    assert set(m["clips"][0]) == expected
