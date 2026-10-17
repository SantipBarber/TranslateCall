"""Tests for tcbench.analyze on synthetic raw.json dictionaries."""

import copy
import json
from pathlib import Path

import pytest

from tcbench import analyze, compare, runs
from tcbench.cli import main

FIXTURES = Path(__file__).parent / "fixtures"
S = 1_000_000_000
MS = 1_000_000


def _clip(cid, feed, feed_end, ss, se):
    return {"id": cid, "feedStartNs": feed, "feedEndNs": feed_end, "speechStartNs": ss, "speechEndNs": se}


def _utt(seq, start, vad_end=None, stt=None, tr=None, tts=None, text=None, seg_ms=None, translated=None,
         stt_engine="STT", tts_engine="TTS", merged=None, dropped=None):
    events = {"speechStart": start}
    detail = {}
    if vad_end is not None:
        events["vadEnd"] = vad_end
        if seg_ms is not None:
            detail["vadEnd"] = {"segmentAudioMs": str(seg_ms)}
    if stt is not None:
        events["sttFinal"] = stt
        detail["sttFinal"] = {"engine": stt_engine, "text": text or ""}
    if tr is not None:
        events["translated"] = tr
        detail["translated"] = {"text": translated or ""}
    if tts is not None:
        events["ttsFirstBuffer"] = tts
        detail["ttsFirstBuffer"] = {"engine": tts_engine, **({"mergedSeqs": merged} if merged else {})}
    if dropped:
        events["dropped"] = start + S
        detail["dropped"] = {"reason": dropped}
    return {"seq": seq, "events": events, "detail": detail}


def _raw(clips, utterances, mt_only=(), **over):
    raw = {
        "schema": 1, "runId": "r", "set": "pr", "profile": "basic", "runLine": "outgoing es-ES>en",
        "informative": False, "override": None,
        "meta": {"commit": "abc", "dirty": False, "machine": "M", "macOS": "15.6", "xcode": "16",
                 "manifestSha256": "a" * 64,
                 "engines": {"expectedSTT": "STT", "expectedTTS": "TTS"}, "settings": {}},
        "clips": clips, "utterances": utterances, "mtOnly": list(mt_only),
    }
    raw.update(over)
    return raw


def _manifest(*clips, mt=()):
    return {"schema": 1, "clips": [
        {"id": cid, "transcript": tr, "translations": ({"en": ref} if ref else {})} for cid, tr, ref in clips
    ], "mtOnly": list(mt)}


def _agg(raw, manifest, comet=False):
    return analyze.analyze_line(raw, manifest, comet=comet)


TWO = [_clip("a", 0, 4 * S, 1 * S, 3 * S), _clip("b", 4 * S, 8 * S, 5 * S, 7 * S)]
M2 = _manifest(("a", "hola mundo", "hello world"), ("b", "buenos días a todos", "good morning everyone"))


def test_assignment_by_feed_window():
    utts = [
        _utt(0, 1 * S, vad_end=4 * S - 1, stt=4 * S, tr=4 * S, tts=4 * S, text="x"),
        _utt(1, 5 * S, vad_end=8 * S, stt=8 * S, tr=8 * S, tts=8 * S, text="y"),
    ]
    assigned = analyze.assign(_raw(TWO, utts))
    assert [[u["seq"] for u in assigned["a"]], [u["seq"] for u in assigned["b"]]] == [[0], [1]]
    # a seq starting exactly on the next feedStart belongs to the next clip
    utts2 = [_utt(0, 4 * S)]
    assigned = analyze.assign(_raw(TWO, utts2))
    assert assigned["a"] == [] and len(assigned["b"]) == 1


def test_cut_clip_latency_on_last_seq():
    utts = [
        _utt(3, 1 * S, vad_end=2 * S, stt=int(2.1 * S), tr=int(2.2 * S), tts=int(2.3 * S), text="hola"),
        _utt(4, int(2.5 * S), vad_end=int(3.2 * S), stt=int(3.3 * S), tr=int(3.5 * S), tts=int(3.9 * S), text="mundo"),
    ]
    agg = _agg(_raw([TWO[0]], utts), _manifest(("a", "hola mundo", "hello world")))
    assert agg["cutRate"] == 1.0
    assert agg["latency"]["total"]["p50"] == pytest.approx(900.0)  # 3.9 s - speechEnd 3.0 s
    assert agg["latency"]["vad"]["p50"] == pytest.approx(200.0)
    assert agg["latency"]["stt"]["p50"] == pytest.approx(100.0)
    assert agg["latency"]["translate"]["p50"] == pytest.approx(200.0)
    assert agg["latency"]["ttsFirstAudio"]["p50"] == pytest.approx(400.0)
    assert agg["latency"]["total"]["count"] == 1 and agg["latencyCold"]["total"]["count"] == 0


def test_merge_counted():
    utts = [
        # speech 1.0 s + 5000 ms segment passes clip b's speechStart (5 s)
        _utt(0, 1 * S, vad_end=6 * S, stt=6 * S, tr=6 * S, tts=6 * S, text="a", seg_ms=5000),
    ]
    agg = _agg(_raw(TWO, utts), M2)
    assert agg["mergeRate"] == pytest.approx(0.5)
    assert agg["missed"] == 1


def test_missed_clip():
    utts = [_utt(0, 1 * S, vad_end=3 * S, stt=3 * S, tr=3 * S, tts=3 * S, text="hola mundo", seg_ms=2000)]
    agg = _agg(_raw(TWO, utts), M2)
    assert agg["missed"] == 1
    assert agg["mergeRate"] == 0.0


def test_wer_joins_seqs():
    utts = [
        _utt(0, 1 * S, vad_end=2 * S, stt=2 * S, text="hola"),
        _utt(1, 2 * S, vad_end=3 * S, stt=3 * S, text="mundo"),
    ]
    agg = _agg(_raw([TWO[0]], utts), _manifest(("a", "hola mundo", "hello world")))
    assert agg["wer"] == 0.0
    utts[1]["detail"]["sttFinal"]["text"] = "mundial"
    agg = _agg(_raw([TWO[0]], utts), _manifest(("a", "hola mundo", "hello world")))
    assert agg["wer"] == pytest.approx(0.5)


def test_cold_reported_apart():
    utts = [
        _utt(0, 1 * S, vad_end=3 * S + 100 * MS, stt=3 * S + 200 * MS, tr=3 * S + 300 * MS, tts=3 * S + 5000 * MS, text="a"),
        _utt(1, 5 * S, vad_end=7 * S + 100 * MS, stt=7 * S + 200 * MS, tr=7 * S + 300 * MS, tts=7 * S + 400 * MS, text="b"),
    ]
    agg = _agg(_raw(TWO, utts), M2)
    assert agg["latencyCold"]["total"] == {"p50": 5000.0, "p90": 5000.0, "mean": 5000.0, "count": 1}
    assert agg["latency"]["total"]["count"] == 1
    assert agg["latency"]["total"]["p50"] == pytest.approx(400.0)


def test_dropped_reasons_counted():
    utts = [
        _utt(0, 1 * S, dropped="stt-empty"),
        _utt(1, 5 * S, dropped="stt-empty"),
        _utt(2, 6 * S, dropped="tts-no-audio"),
        _utt(3, 7 * S, dropped="empty-text"),
        _utt(4, 7 * S + 1, dropped="idle-timeout"),
    ]
    agg = _agg(_raw(TWO, utts), M2)
    assert agg["dropped"] == {"stt-empty": 2, "tts-no-audio": 1, "empty-text": 1, "idle-timeout": 1}


def test_chrf_on_sample():
    raw = json.loads((FIXTURES / "raw-v1-sample.json").read_text())
    manifest = json.loads((FIXTURES / "manifest-v1-sample.json").read_text())
    agg = _agg(raw, manifest)
    assert agg["chrf"]["pipeline"] == pytest.approx(PIPELINE_PIN, abs=0.005)
    assert agg["chrf"]["mtOnly"] == pytest.approx(MTONLY_PIN, abs=0.005)
    assert agg["comet"] is None


PIPELINE_PIN = 15.34
MTONLY_PIN = 100.0


def test_missing_reference_contributes_nothing():
    manifest = _manifest(("a", "hola mundo", None), ("b", "buenos días", "good morning"))
    utts = [
        _utt(0, 1 * S, vad_end=3 * S, stt=3 * S, tr=3 * S, tts=3 * S, text="x", translated="anything at all"),
        _utt(1, 5 * S, vad_end=7 * S, stt=7 * S, tr=7 * S, tts=7 * S, text="y", translated="good morning"),
    ]
    agg = _agg(_raw(TWO, utts), manifest)
    assert agg["chrf"]["pipeline"] == pytest.approx(100.0)
    none = _agg(_raw(TWO, utts), _manifest(("a", "x", None), ("b", "y", None)))
    assert none["chrf"]["pipeline"] is None


def test_fallbacks_counted_and_warned(tmp_path, capsys):
    utts = [
        _utt(0, 1 * S, vad_end=3 * S, stt=3 * S, tr=3 * S, tts=3 * S, text="a", stt_engine="Other"),
        _utt(1, 5 * S, vad_end=7 * S, stt=7 * S, tr=7 * S, tts=7 * S, text="b", tts_engine="Edge"),
    ]
    assert _agg(_raw(TWO, utts), M2)["fallbacks"] == 2
    _write_line(tmp_path, _raw(TWO, utts))
    analyze.run(tmp_path, M2, comet=False)
    assert "WARNING" in capsys.readouterr().err


def _write_line(run_dir, raw, name="basic/line"):
    d = run_dir / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "raw.json").write_text(json.dumps(raw))


def test_comet_stubbed(monkeypatch):
    calls = []

    def fake(triples):
        calls.append(list(triples))
        return 0.8

    monkeypatch.setattr(analyze, "comet_score", fake)
    utts = [_utt(0, 1 * S, vad_end=3 * S, stt=3 * S, tr=3 * S, tts=3 * S, text="a", translated="hello")]
    agg = _agg(_raw([TWO[0]], utts, mt_only=[{"id": "m1", "hyp": "hi", "ms": 1}]),
               _manifest(("a", "hola", "hello"), mt=[{"id": "m1", "src": "hey", "ref": "hi", "srcLang": "es", "tgtLang": "en"}]),
               comet=True)
    assert agg["comet"] == {"pipeline": 0.8, "mtOnly": 0.8}
    assert calls[0] == [{"src": "hola", "mt": "hello", "ref": "hello"}]


def test_run_roundtrip_with_compare(tmp_path):
    raw1 = json.loads((FIXTURES / "raw-v1-sample.json").read_text())
    manifest = json.loads((FIXTURES / "manifest-v1-sample.json").read_text())
    raw2 = copy.deepcopy(raw1)
    raw2["profile"], raw2["informative"], raw2["override"] = "stress", True, "why"
    _write_line(tmp_path, raw1, "basic/l1")
    _write_line(tmp_path, raw2, "stress/l1")
    result = analyze.run(tmp_path, manifest, comet=False)
    assert (tmp_path / "basic/l1/metrics.json").exists()
    assert set(result["aggregates"]) == {"basic/es-ES>en", "stress/es-ES>en"}
    meta, aggs = runs.load_run(tmp_path)
    assert meta["informative"] is True and meta["override"] == "why" and meta["set"] == "pr"
    baseline = {"manifestSha256": meta["manifestSha256"], "macOS": meta["macOS"], "aggregates": aggs}
    thresholds = json.loads((Path(__file__).parents[3] / "bench" / "thresholds.json").read_text())
    _, code = compare.run(aggs, baseline, thresholds, meta)
    assert code == 0


def test_run_fails_on_disagreeing_meta(tmp_path):
    raw1 = _raw(TWO, [])
    raw2 = _raw(TWO, [], profile="stress")
    raw2["meta"]["commit"] = "other"
    _write_line(tmp_path, raw1, "a")
    _write_line(tmp_path, raw2, "b")
    with pytest.raises(ValueError, match="commit"):
        analyze.run(tmp_path, M2, comet=False)


def test_cli_analyze(tmp_path, capsys):
    m = tmp_path / "m.json"
    m.write_text(json.dumps(M2))
    run = tmp_path / "run"
    _write_line(run, _raw(TWO, []))
    assert main(["analyze", str(run), "--manifest", str(m)]) == 0
    assert (run / "metrics.json").exists()


def test_cli_comet_branches(tmp_path, monkeypatch, capsys):
    m = tmp_path / "m.json"
    m.write_text(json.dumps(M2))
    run = tmp_path / "run"
    _write_line(run, _raw(TWO, []))
    monkeypatch.setattr(analyze, "comet_available", lambda: False)
    assert main(["analyze", str(run), "--manifest", str(m), "--comet"]) == 1
    assert "unbabel-comet" in capsys.readouterr().err
    monkeypatch.setattr(analyze, "comet_available", lambda: True)
    monkeypatch.setattr(analyze, "comet_score", lambda triples: 0.5)
    assert main(["analyze", str(run), "--manifest", str(m), "--comet"]) == 0


def test_trailing_dropped_seq_does_not_hijack():
    utts = [
        _utt(0, 1 * S, vad_end=3 * S + 100 * MS, stt=3 * S + 200 * MS, tr=3 * S + 300 * MS, tts=3 * S + 500 * MS, text="hola mundo"),
        _utt(1, int(3.5 * S), vad_end=3 * S + 600 * MS, dropped="stt-empty"),
    ]
    agg = _agg(_raw([TWO[0]], utts), _manifest(("a", "hola mundo", "hello")))
    assert agg["cutRate"] == 0.0
    assert agg["latency"]["total"]["count"] + agg["latencyCold"]["total"]["count"] == 1
    assert agg["latency"]["vad"]["count"] == 0 or agg["latency"]["vad"]["p50"] == pytest.approx(100.0)
    only_dropped = _agg(_raw([TWO[0]], [utts[1]]), _manifest(("a", "hola", "hello")))
    assert only_dropped["latency"]["total"]["count"] == 0 == only_dropped["latency"]["vad"]["count"]
    assert only_dropped["latencyCold"]["vad"]["count"] == 0


def test_unassigned_counted_and_warned(tmp_path, capsys):
    raw = _raw(TWO, [_utt(0, -1 * S, dropped="stt-empty"), _utt(1, 1 * S, vad_end=3 * S, stt=3 * S, text="x")])
    assert _agg(raw, M2)["unassigned"] == 1
    _write_line(tmp_path, raw)
    analyze.run(tmp_path, M2, comet=False)
    assert "unassigned" in capsys.readouterr().err


def test_missing_meta_key_is_value_error(tmp_path):
    raw = _raw(TWO, [])
    del raw["meta"]["machine"]
    _write_line(tmp_path, raw)
    with pytest.raises(ValueError, match="meta.machine"):
        analyze.run(tmp_path, M2, comet=False)
    raw = _raw(TWO, [])
    del raw["set"]
    _write_line(tmp_path, raw)
    with pytest.raises(ValueError, match="set"):
        analyze.run(tmp_path, M2, comet=False)


def test_target_lang():
    assert runs.target_lang("outgoing es-ES>en") == "en"
    assert runs.target_lang("incoming en>es-419") == "es"
    assert runs.target_lang("nonsense") is None
