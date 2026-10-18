"""Tests for tcbench.report on synthetic runs built through analyze's own output."""

import json
import re
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from tcbench import analyze, report
from tcbench.cli import main

S = 1_000_000_000
MS = 1_000_000
SR = 24_000


def _wav(path: Path, seconds: float, seed: int = 0) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(seed)
    sf.write(path, (rng.standard_normal(int(seconds * SR)) * 0.1).astype("float32"), SR, subtype="PCM_16")


def _build(tmp_path, monkeypatch, n=3, seconds=1.0, transcript="hola mundo", stt_engine="STT",
           dataset="fleurs", run_name="run1", total_ms=500):
    """Synthetic run: one line `basic/outgoing es-ES>en` with n clips; returns (run_dir, manifest)."""
    cache = tmp_path / "cache"
    monkeypatch.setenv("TC_BENCH_CACHE", str(cache))
    clips, mclips, utts = [], [], []
    for i in range(n):
        cid = f"c{i:02d}"
        feed = i * 4 * S
        clips.append({"id": cid, "feedStartNs": feed, "feedEndNs": feed + 4 * S,
                      "speechStartNs": feed + S, "speechEndNs": feed + 2 * S})
        rel = f"{dataset}/es/{cid}.wav"
        _wav(cache / rel, seconds, i)
        mclips.append({"id": cid, "transcript": transcript, "translations": {"en": "hello world"},
                       "source": {"dataset": dataset}, "audio": rel, "gainDb": 3.0, "licence": "CC-BY-4.0"})
        end = feed + 2 * S
        text = transcript if i % 2 == 0 else "otra cosa"
        utts.append({
            "seq": i, "audio": f"audio/{i}.wav",
            "events": {"speechStart": feed + S, "vadEnd": end + 100 * MS, "sttFinal": end + 200 * MS,
                       "translated": end + 300 * MS, "ttsFirstBuffer": end + (total_ms + i * 20) * MS},
            "detail": {"sttFinal": {"engine": stt_engine, "text": text},
                       "translated": {"text": "hello <b>world</b>"}, "ttsFirstBuffer": {"engine": "TTS"}},
        })
    raw = {
        "schema": 1, "runId": run_name, "set": "pr", "profile": "basic", "runLine": "outgoing es-ES>en",
        "informative": False, "override": None,
        "meta": {"commit": "abc", "dirty": False, "machine": "M", "macOS": "15.6", "xcode": "16",
                 "manifestSha256": "a" * 64, "engines": {"expectedSTT": "STT", "expectedTTS": "TTS"}, "settings": {}},
        "clips": clips, "utterances": utts, "mtOnly": [],
    }
    run_dir = tmp_path / run_name
    line = run_dir / "basic" / "outgoing-es-ES-en"
    line.mkdir(parents=True)
    for i in range(n):
        _wav(line / "audio" / f"{i}.wav", seconds, 100 + i)
    (line / "raw.json").write_text(json.dumps(raw))
    manifest = {"schema": 1, "clips": mclips, "mtOnly": []}
    analyze.run(run_dir, manifest)
    return run_dir, manifest


def _go(run_dir, manifest, tmp_path, **kw):
    return report.run(run_dir, tmp_path / "history", manifest=manifest, **kw)


def test_report_is_self_contained(tmp_path, monkeypatch):
    run_dir, manifest = _build(tmp_path, monkeypatch)
    out = _go(run_dir, manifest, tmp_path)
    assert out == run_dir / "report.html"
    html = out.read_text()
    assert not re.findall(r"""(?:src|href)\s*=\s*["']?https?://""", html)
    assert "<link" not in html
    assert "vega-embed" in html or "vegaEmbed" in html
    assert "basic/outgoing es-ES&gt;en" in html


def test_report_size_capped(tmp_path, monkeypatch):
    run_dir, manifest = _build(tmp_path, monkeypatch, n=30, seconds=10.0)
    out = _go(run_dir, manifest, tmp_path)
    assert out.stat().st_size <= report.MAX_BYTES


def test_report_size_capped_with_wav_fallback(tmp_path, monkeypatch):
    monkeypatch.setattr(report, "_opus_available", lambda: False)
    run_dir, manifest = _build(tmp_path, monkeypatch, n=30, seconds=10.0)
    html = _go(run_dir, manifest, tmp_path).read_text()
    assert len(html.encode()) <= report.MAX_BYTES
    assert "data:audio/wav;base64," in html
    # highest-ranked rows keep audio, lowest-ranked lose it
    assert html.count("<audio") < 40
    assert "audio omitted (size cap)" in html


def test_opus_used_when_available(tmp_path, monkeypatch):
    if not report._opus_available():
        pytest.skip("no Opus in this soundfile build")
    run_dir, manifest = _build(tmp_path, monkeypatch, n=30, seconds=10.0)
    html = _go(run_dir, manifest, tmp_path).read_text()
    assert "data:audio/ogg;codecs=opus;base64," in html
    assert "audio omitted" not in html


def test_attributions_present(tmp_path, monkeypatch):
    run_dir, manifest = _build(tmp_path, monkeypatch, dataset="fleurs")
    html = _go(run_dir, manifest, tmp_path).read_text()
    assert "Conneau et al." in html
    assert "CC BY 4.0" in html
    assert "Mozilla Common Voice contributors" not in html
    assert "NTREX" not in html
    assert "Smart Turn" not in html
    assert "32 ms" in html and "0.35" in html and "256 ms" in html and "0.85" in html
    assert "-26 dBFS" in html


def test_fallback_warning_banner(tmp_path, monkeypatch):
    run_dir, manifest = _build(tmp_path, monkeypatch, stt_engine="OTHER")
    html = _go(run_dir, manifest, tmp_path).read_text()
    assert 'class="banner warn"' in html
    assert "runtime fallback" in html


def test_no_banner_without_fallbacks(tmp_path, monkeypatch):
    run_dir, manifest = _build(tmp_path, monkeypatch)
    assert 'class="banner warn"' not in _go(run_dir, manifest, tmp_path).read_text()


def test_html_special_characters_escaped(tmp_path, monkeypatch):
    run_dir, manifest = _build(tmp_path, monkeypatch, transcript="<script>alert(1)</script> & \"q\"")
    html = _go(run_dir, manifest, tmp_path).read_text()
    assert "<script>alert(1)</script>" not in html
    assert "&lt;script&gt;alert(1)&lt;/script&gt;" in html
    assert "hello <b>world</b>" not in html
    assert "hello &lt;b&gt;world&lt;/b&gt;" in html


def test_trend_uses_history(tmp_path, monkeypatch):
    old, m = _build(tmp_path, monkeypatch, run_name="2026-01-01", total_ms=900)
    cur, m = _build(tmp_path, monkeypatch, run_name="2026-02-01")
    hist = tmp_path / "history"
    hist.mkdir()
    (hist / "2026-01-01").mkdir()
    (hist / "2026-01-01" / "metrics.json").write_text((old / "metrics.json").read_text())
    html = report.run(cur, hist, manifest=m).read_text()
    assert "2026-01-01" in html


def test_trend_ignores_latest_symlink_and_dirs_without_metrics(tmp_path, monkeypatch):
    old, m = _build(tmp_path, monkeypatch, run_name="2026-01-01", total_ms=900)
    cur, m = _build(tmp_path, monkeypatch, run_name="2026-02-01")
    hist = tmp_path / "history"
    (hist / "2026-01-01").mkdir(parents=True)
    (hist / "2026-01-01" / "metrics.json").write_text((old / "metrics.json").read_text())
    (hist / "2026-01-02-failed").mkdir()          # a failed run: no metrics.json
    (hist / "latest").symlink_to("2026-01-01")      # would otherwise count the run twice
    trend = report._trend(cur, hist, 10, json.loads((cur / "metrics.json").read_text())["aggregates"])
    assert sorted({p["run"] for p in trend}) == ["2026-01-01", "2026-02-01"]


def test_trend_skips_failed_runs_even_with_metrics(tmp_path, monkeypatch):
    old, m = _build(tmp_path, monkeypatch, run_name="2026-01-01", total_ms=900)
    cur, m = _build(tmp_path, monkeypatch, run_name="2026-02-01")
    hist = tmp_path / "history"
    (hist / "2026-01-01").mkdir(parents=True)
    (hist / "2026-01-01" / "metrics.json").write_text((old / "metrics.json").read_text())
    # bench.sh renames a failed run to "<run>-failed" but its metrics.json may still exist
    (hist / "2026-01-02-failed").mkdir()
    (hist / "2026-01-02-failed" / "metrics.json").write_text((old / "metrics.json").read_text())
    trend = report._trend(cur, hist, 10, json.loads((cur / "metrics.json").read_text())["aggregates"])
    assert sorted({p["run"] for p in trend}) == ["2026-01-01", "2026-02-01"]


def test_trend_only_same_set(tmp_path, monkeypatch):
    old, m = _build(tmp_path, monkeypatch, run_name="2026-01-01", total_ms=900)
    cur, m = _build(tmp_path, monkeypatch, run_name="2026-02-01")
    hist = tmp_path / "history"
    for name, set_type in [("2026-01-01", "full"), ("2026-01-02", "pr")]:
        payload = json.loads((old / "metrics.json").read_text())
        payload["meta"]["set"] = set_type
        (hist / name).mkdir(parents=True)
        (hist / name / "metrics.json").write_text(json.dumps(payload))
    aggs = json.loads((cur / "metrics.json").read_text())["aggregates"]
    trend = report._trend(cur, hist, 10, aggs, "full")
    assert sorted({p["run"] for p in trend}) == ["2026-01-01", "2026-02-01"]


def test_cli_report(tmp_path, monkeypatch, capsys):
    run_dir, manifest = _build(tmp_path, monkeypatch)
    mpath = tmp_path / "m.json"
    mpath.write_text(json.dumps(manifest))
    code = main(["report", str(run_dir), "--history", str(tmp_path / "h"), "--manifest", str(mpath)])
    assert code == 0
    assert (run_dir / "report.html").exists()
    assert main(["report", str(tmp_path / "nope")]) == 2
