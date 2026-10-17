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


def _gap_samples(
    seconds: float = 3.0,
    amplitude: float = 0.5,
    gaps: list[tuple[float, float]] | None = None,
    lead_s: float = 0.5,
    tail_s: float = 0.5,
) -> np.ndarray:
    """Return synthetic float32 samples with lead/tail silence. gaps is a list of (start_s, duration_s) silent regions inside the speech region."""
    total = int(seconds * SR)
    samples = np.zeros(total, np.float32)
    t = np.arange(total) / SR
    tone = (amplitude * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    speech_start = int(lead_s * SR)
    speech_end = int((seconds - tail_s) * SR)
    if speech_end <= speech_start:
        return samples
    regions: list[tuple[int, int]] = [(speech_start, speech_end)]
    for start, dur in sorted(gaps or []):
        gap_start = int(start * SR)
        gap_end = int((start + dur) * SR)
        new_regions = []
        for lo, hi in regions:
            if gap_end <= lo or gap_start >= hi:
                new_regions.append((lo, hi))
            else:
                if lo < gap_start:
                    new_regions.append((lo, gap_start))
                if gap_end < hi:
                    new_regions.append((gap_end, hi))
        regions = new_regions
    for lo, hi in regions:
        samples[lo:hi] = tone[lo:hi]
    return samples


def _wav(
    path: Path,
    seconds: float = 2.0,
    amplitude: float = 0.5,
    gaps: list[tuple[float, float]] | None = None,
    lead_s: float = 0.0,
    tail_s: float = 0.0,
) -> None:
    """Write a synthetic float WAV."""
    sf.write(path, _gap_samples(seconds, amplitude, gaps, lead_s, tail_s), SR, format="WAV", subtype="FLOAT")


def _manifest(path: Path) -> None:
    manifest_mod.dump({"schema": 1, "clips": [], "mtOnly": []}, path)


def test_matches_files_to_prompts(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (200.0, 1800.0))
    sheet = tmp_path / "sheet.md"
    rows = [
        {"id": f"en-{i:02d}", "purpose": "short", "text": f"word {i}.", "reference": f"palabra {i}."}
        for i in range(1, 10)
    ]
    _sheet(sheet, rows)
    for i in range(1, 10):
        _wav(tmp_path / f"en-{i:02d}.wav", seconds=2.0)
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)
    cache_dir = tmp_path / "cache"

    problems = ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=cache_dir)

    assert problems == []
    m = json.loads(manifest_path.read_text())
    assert len(m["clips"]) == 9
    by_id = {c["id"]: c for c in m["clips"]}
    for i in range(1, 10):
        cid = f"own-en-en-{i:02d}"
        c = by_id[cid]
        assert c["speaker"] == "own-user"
        assert c["nativeSpeaker"] is True
        assert c["translations"] == {"es": rows[i - 1]["reference"]}
        assert c["gainDb"] != 0.0
        assert len(c["sha256"]) == 64
        assert c["audio"] == f"own/en/{cid}.wav"
        assert (cache_dir / c["audio"]).exists()
        expected_tiers = ["pr", "full"] if i <= 8 else ["full"]
        assert c["tiers"] == expected_tiers


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


def test_count_pauses_one_gap() -> None:
    samples = _gap_samples(3.0, gaps=[(1.0, 0.4)], lead_s=0.5, tail_s=0.5)
    assert ingest._count_pauses(samples, (500.0, 2500.0)) == 1


def test_count_pauses_zero_for_gapless() -> None:
    samples = _gap_samples(2.0, lead_s=0.5, tail_s=0.5)
    assert ingest._count_pauses(samples, (500.0, 1500.0)) == 0


def test_pause_marks_matched(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (500.0, 2500.0))
    sheet = tmp_path / "sheet.md"
    _sheet(sheet, [{"id": "en-20", "purpose": "hesitation", "text": "Friday ‖ or Monday.", "reference": "Viernes o lunes."}])
    # one internal 0.4 s silence
    _wav(tmp_path / "en-20.wav", seconds=3.0, gaps=[(1.0, 0.4)], lead_s=0.5, tail_s=0.5)
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)

    problems = ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")

    assert not any("pause" in p for p in problems)


def test_pause_marks_mismatch_flagged(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (500.0, 2500.0))
    sheet = tmp_path / "sheet.md"
    _sheet(sheet, [{"id": "en-20", "purpose": "hesitation", "text": "a ‖ b ‖ c ‖ d", "reference": "ref"}])
    # gapless audio, but three marks expected
    _wav(tmp_path / "en-20.wav", seconds=3.0, lead_s=0.5, tail_s=0.5)
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)

    problems = ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")

    assert any("pause count mismatch" in p for p in problems)


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
    _sheet(
        sheet,
        [
            {"id": "en-01", "purpose": "short", "text": "Yes.", "reference": "Sí."},
            {"id": "en-99", "purpose": "short", "text": "Missing.", "reference": "Falta."},
        ],
    )
    _wav(tmp_path / "en-01.wav", seconds=2.0)
    _wav(tmp_path / "orphan.wav", seconds=2.0)
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)

    problems = ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")

    assert any("no prompt for file" in p and "orphan.wav" in p for p in problems)
    assert any("no file for prompt" in p and "en-99" in p for p in problems)


def test_duplicate_stem_reported(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (200.0, 1800.0))
    sheet = tmp_path / "sheet.md"
    _sheet(sheet, [{"id": "en-01", "purpose": "short", "text": "Yes.", "reference": "Sí."}])
    _wav(tmp_path / "en-01.wav", seconds=2.0)
    (tmp_path / "en-01.m4a").write_text("not audio")
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)

    problems = ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")

    assert any("duplicate recordings for en-01" in p for p in problems)


def test_no_entry_produced_refuses_manifest_update(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: None)
    sheet = tmp_path / "sheet.md"
    _sheet(sheet, [{"id": "en-01", "purpose": "short", "text": "Yes.", "reference": "Sí."}])
    _wav(tmp_path / "en-01.wav", seconds=1.0)
    manifest_path = tmp_path / "manifest.json"
    original = {
        "schema": 1,
        "clips": [
            {
                "id": "own-en-old-01",
                "source": {"dataset": "own", "revision": "oldsha", "originalId": "old.wav"},
                "lang": "en",
                "variant": "en",
                "speaker": "own-user",
                "nativeSpeaker": True,
                "transcript": "old",
                "translations": {"es": "viejo"},
                "gainDb": 0.0,
                "speechStartMs": 0.0,
                "speechEndMs": 1000.0,
                "tags": ["short", "own"],
                "tiers": ["pr", "full"],
                "sha256": "b" * 64,
                "licence": "own-recording",
                "audio": "own/en/own-en-old-01.wav",
            }
        ],
        "mtOnly": [],
    }
    manifest_mod.dump(original, manifest_path)

    problems = ingest.run(tmp_path, sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")

    assert any("no recordings produced" in p for p in problems)
    assert json.loads(manifest_path.read_text()) == original


def test_two_ingests_are_byte_identical(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (200.0, 1800.0))
    sheet = tmp_path / "sheet.md"
    _sheet(sheet, [{"id": "en-01", "purpose": "short", "text": "Yes.", "reference": "Sí."}])
    _wav(tmp_path / "en-01.wav", seconds=2.0)
    base = {"schema": 1, "clips": [], "mtOnly": []}
    manifest_a = tmp_path / "manifest-a.json"
    manifest_b = tmp_path / "manifest-b.json"
    manifest_mod.dump(base, manifest_a)
    manifest_mod.dump(base, manifest_b)

    ingest.run(tmp_path, sheet, "en", True, manifest_a, cache_dir=tmp_path / "cache-a")
    ingest.run(tmp_path, sheet, "en", True, manifest_b, cache_dir=tmp_path / "cache-b")

    assert manifest_a.read_bytes() == manifest_b.read_bytes()


def test_manifest_order_is_stable_across_variants(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (200.0, 1800.0))
    en_sheet = tmp_path / "en.md"
    es_sheet = tmp_path / "es-ES.md"
    _sheet(en_sheet, [{"id": "en-01", "purpose": "short", "text": "Yes.", "reference": "Sí."}])
    _sheet(es_sheet, [{"id": "es-ES-01", "purpose": "short", "text": "Sí.", "reference": "Yes."}])
    _wav(tmp_path / "en-01.wav", seconds=2.0)
    _wav(tmp_path / "es-ES-01.wav", seconds=2.0)
    manifest_path = tmp_path / "manifest.json"
    original = {
        "schema": 1,
        "clips": [
            {
                "id": "public-1",
                "source": {"dataset": "fleurs", "revision": "r", "originalId": "x"},
                "lang": "en",
                "variant": "en",
                "speaker": "s",
                "nativeSpeaker": True,
                "transcript": "t",
                "translations": {},
                "gainDb": 0.0,
                "speechStartMs": 0.0,
                "speechEndMs": 1000.0,
                "tags": [],
                "tiers": ["full"],
                "sha256": "a" * 64,
                "licence": "CC-BY-4.0",
                "audio": "fleurs/en/public-1.wav",
            },
            {
                "id": "own-en-old-01",
                "source": {"dataset": "own", "revision": "oldsha", "originalId": "old.wav"},
                "lang": "en",
                "variant": "en",
                "speaker": "own-user",
                "nativeSpeaker": True,
                "transcript": "old",
                "translations": {"es": "viejo"},
                "gainDb": 0.0,
                "speechStartMs": 0.0,
                "speechEndMs": 1000.0,
                "tags": ["short", "own"],
                "tiers": ["pr", "full"],
                "sha256": "b" * 64,
                "licence": "own-recording",
                "audio": "own/en/own-en-old-01.wav",
            },
        ],
        "mtOnly": [],
    }
    manifest_mod.dump(original, manifest_path)

    # ingest en first, then es-ES
    ingest.run(tmp_path, en_sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")
    ingest.run(tmp_path, es_sheet, "es-ES", True, manifest_path, cache_dir=tmp_path / "cache")
    first_bytes = manifest_path.read_bytes()

    # reset and ingest in reverse order
    manifest_mod.dump(original, manifest_path)
    ingest.run(tmp_path, es_sheet, "es-ES", True, manifest_path, cache_dir=tmp_path / "cache")
    ingest.run(tmp_path, en_sheet, "en", True, manifest_path, cache_dir=tmp_path / "cache")
    second_bytes = manifest_path.read_bytes()

    assert first_bytes == second_bytes
    m = json.loads(manifest_path.read_text())
    ids = [c["id"] for c in m["clips"]]
    assert ids[0] == "public-1"
    assert "own-en-old-01" not in ids
    assert ids[1:] == sorted(ids[1:])


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


def test_es_es_sheet_translation_keyed_en(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(groundtruth, "speech_span", lambda samples, sr=16000, why=None: (200.0, 1800.0))
    sheet = tmp_path / "sheet.md"
    _sheet(sheet, [{"id": "es-ES-01", "purpose": "short", "text": "Vale.", "reference": "Okay."}])
    _wav(tmp_path / "es-ES-01.wav", seconds=2.0)
    manifest_path = tmp_path / "manifest.json"
    _manifest(manifest_path)

    ingest.run(tmp_path, sheet, "es-ES", True, manifest_path, cache_dir=tmp_path / "cache")

    m = json.loads(manifest_path.read_text())
    assert len(m["clips"]) == 1
    assert m["clips"][0]["translations"] == {"en": "Okay."}
