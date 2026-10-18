"""Self-contained HTML report for one bench run (REQ-BH-53, NFR-BH-05).

Scales: chrF++ 0..100; WER and cut rate are fractions shown as percentages; latencies in ms.
Every chart and table is per ``"<profile>/<runLine>"``: es-ES and es-419 are never merged.
The page inlines Vega/Vega-Lite/Vega-Embed and the audio as data URIs, so it opens offline.
"""

from __future__ import annotations

import base64
import io
import json
import sys
from pathlib import Path
from typing import Any

import soundfile as sf
import soxr
from jinja2 import Environment, FileSystemLoader, select_autoescape

from . import analyze, compare, runs, sources
from .text import wer

PKG = Path(__file__).resolve().parent
REPO = PKG.parents[2]
MAX_BYTES = 8 * 1024 * 1024
TOP_N = 10
STAGE_ORDER = ("vad", "stt", "translate", "ttsFirstAudio")
OPUS_RATES = (8000, 12000, 16000, 24000, 48000)
VENDOR_FILES = ("vega.min.js", "vega-lite.min.js", "vega-embed.min.js")
_SLACK = 16 * 1024


def _opus_available() -> bool:
    try:
        return "OPUS" in sf.available_subtypes("OGG")
    except Exception:  # pragma: no cover - libsndfile without OGG
        return False


def _data_uri(path: Path) -> str | None:
    """Audio file as a data URI: Opus (mono) when supported, else the WAV bytes."""
    if not path.is_file():
        return None
    if _opus_available():
        try:
            data, rate = sf.read(path, dtype="float32", always_2d=True)
            mono = data.mean(axis=1)
            if rate not in OPUS_RATES:
                mono = soxr.resample(mono, rate, 48000)
                rate = 48000
            buf = io.BytesIO()
            sf.write(buf, mono, rate, format="OGG", subtype="OPUS")
            return "data:audio/ogg;codecs=opus;base64," + base64.b64encode(buf.getvalue()).decode()
        except Exception:
            pass
    return "data:audio/wav;base64," + base64.b64encode(path.read_bytes()).decode()


def _line_data(run_dir: Path) -> dict[str, tuple[Path, dict]]:
    """``"<profile>/<runLine>"`` -> (line dir, raw.json)."""
    out: dict[str, tuple[Path, dict]] = {}
    for path in sorted(run_dir.rglob("raw.json")):
        raw = json.loads(path.read_text())
        out[f"{raw['profile']}/{raw['runLine']}"] = (path.parent, raw)
    return out


def _clip_rows(key: str, line_dir: Path, raw: dict, manifest: dict, cache: Path) -> list[dict[str, Any]]:
    by_id = {c["id"]: c for c in manifest["clips"]}
    target = runs.target_lang(raw.get("runLine", ""))
    assigned = analyze.assign(raw)
    rows = []
    for clip in raw["clips"]:
        mclip = by_id[clip["id"]]
        utts = assigned[clip["id"]]
        live = [u for u in utts if "dropped" not in u["events"]]
        total = None
        tts_path = None
        if live:
            last = live[-1]
            total = analyze._latencies(last, clip["speechEndNs"]).get("total")
            if last.get("audio"):
                tts_path = line_dir / last["audio"]
        stt = analyze._joined(utts, "sttFinal")
        rows.append({
            "key": key,
            "clip": clip["id"],
            "total": total,
            "wer": wer(mclip["transcript"], stt),
            "reference": mclip["transcript"],
            "stt": stt,
            "translation": analyze._joined(utts, "translated"),
            "refTranslation": (mclip.get("translations") or {}).get(target or "", ""),
            "srcPath": cache / mclip["audio"] if mclip.get("audio") else None,
            "ttsPath": tts_path,
        })
    return rows


def _worst(rows: list[dict]) -> list[dict]:
    """Top rows by total latency and by WER for one line, with rank and kind."""
    by_total = sorted((r for r in rows if r["total"] is not None), key=lambda r: -r["total"])[:TOP_N]
    by_wer = sorted((r for r in rows if r["wer"] > 0), key=lambda r: -r["wer"])[:TOP_N]
    out = [dict(r, kind="total", rank=i) for i, r in enumerate(by_total)]
    out += [dict(r, kind="wer", rank=i) for i, r in enumerate(by_wer)]
    return out


def _trend(run_dir: Path, history_dir: Path, last_n: int, aggregates: dict, set_type: str | None = None) -> list[dict]:
    """Latency trend over the last runs of the same set: PR (8 clips) and full runs are not comparable."""
    here = run_dir.resolve()
    entries: list[tuple[str, dict]] = []
    if history_dir.is_dir():
        for d in sorted(history_dir.iterdir()):
            if (d.is_symlink() or d.name.endswith("-failed") or d.resolve() == here
                    or not (d / "metrics.json").is_file()):
                continue
            try:
                payload = json.loads((d / "metrics.json").read_text())
                if set_type is not None and payload.get("meta", {}).get("set") != set_type:
                    continue
                entries.append((d.name, payload["aggregates"]))
            except (ValueError, KeyError, OSError):
                continue
    entries = entries[-max(last_n - 1, 0):] + [(run_dir.name, aggregates)]
    points = []
    for name, aggs in entries[-last_n:]:
        for key, agg in aggs.items():
            p50 = agg.get("latency", {}).get("total", {}).get("p50")
            points.append({"run": name, "key": key, "p50": p50,
                           "wer": agg["wer"] * 100.0 if agg.get("wer") is not None else None})
    return points


def _attributions(raws: list[dict], manifest: dict) -> list[dict]:
    licences = json.loads((REPO / "bench" / "licences.json").read_text())["sources"]
    by_clip = {c["id"]: c["source"]["dataset"] for c in manifest["clips"]}
    present = {by_clip[c["id"]] for raw in raws for c in raw["clips"] if c["id"] in by_clip}
    if any(raw.get("mtOnly") for raw in raws):
        present.add("ntrex128")
    return [s for s in licences if s["id"] in present]


def _comparison(run_dir: Path, baseline_path: Path, thresholds_path: Path) -> str:
    meta, aggs = runs.load_run(run_dir)
    if not baseline_path.is_file() or not thresholds_path.is_file():
        return "No baseline to compare against."
    base = json.loads(baseline_path.read_text())
    table, _ = compare.run(aggs, base, json.loads(thresholds_path.read_text()), meta)
    return table


def _stage_data(aggregates: dict) -> list[dict]:
    return [
        {"key": key, "stage": stage, "ms": agg["latency"].get(stage, {}).get("p50"),
         "order": STAGE_ORDER.index(stage)}
        for key, agg in sorted(aggregates.items())
        for stage in STAGE_ORDER
        if agg["latency"].get(stage, {}).get("p50") is not None
    ]


def _env() -> Environment:
    return Environment(loader=FileSystemLoader(PKG / "templates"), autoescape=select_autoescape(["html", "j2"]))


def run(
    run_dir: Path | str,
    history_dir: Path | str,
    last_n: int = 10,
    manifest: dict | None = None,
    baseline_path: Path | str | None = None,
    thresholds_path: Path | str | None = None,
) -> Path:
    """Write ``report.html`` in ``run_dir`` and return its path."""
    run_dir, history_dir = Path(run_dir), Path(history_dir)
    meta, aggregates = runs.load_run(run_dir)
    if manifest is None:
        manifest = json.loads((REPO / "bench" / "manifests" / "phase1.json").read_text())
    lines = _line_data(run_dir)
    cache = sources.default_cache_dir()

    all_rows: list[dict] = []
    totals: list[dict] = []
    worst: list[dict] = []
    for key, (line_dir, raw) in lines.items():
        rows = _clip_rows(key, line_dir, raw, manifest, cache)
        totals += [{"key": key, "total": r["total"]} for r in rows if r["total"] is not None]
        worst += _worst(rows)
        all_rows += rows
    # Lowest-ranked rows lose their audio first: rank position, then kind, then line.
    worst.sort(key=lambda r: (r["rank"], r["kind"] != "total", r["key"]))

    for r in worst:
        r["srcAudio"] = r["ttsAudio"] = None
        r["audioOmitted"] = False

    banners = [
        {"key": key, "fallbacks": agg.get("fallbacks", 0), "unassigned": agg.get("unassigned", 0)}
        for key, agg in sorted(aggregates.items())
        if agg.get("fallbacks", 0) > 0 or agg.get("unassigned", 0) > 0
    ]
    vendor = [(PKG / "vendor" / f).read_text() for f in VENDOR_FILES]
    context = {
        "meta": meta,
        "runName": run_dir.name,
        "aggregates": {k: aggregates[k] for k in sorted(aggregates)},
        "banners": banners,
        "comparison": _comparison(
            run_dir,
            Path(baseline_path) if baseline_path else REPO / "bench" / "baseline.json",
            Path(thresholds_path) if thresholds_path else REPO / "bench" / "thresholds.json",
        ),
        "stageData": _stage_data(aggregates),
        "totals": totals,
        "trend": _trend(run_dir, history_dir, last_n, aggregates, meta.get("set")),
        "worst": worst,
        "attributions": _attributions([raw for _, raw in lines.values()], manifest),
        "vendor": vendor,
    }
    template = _env().get_template("report.html.j2")

    def render() -> str:
        return template.render(**context)

    base = len(render().encode())
    encoded = {}
    for r in worst:
        for field, path in (("srcAudio", r["srcPath"]), ("ttsAudio", r["ttsPath"])):
            if path is not None and path not in encoded:
                encoded[path] = _data_uri(path)
    budget = MAX_BYTES - base - _SLACK
    while True:
        used = 0
        full = False
        for r in worst:
            src, tts = encoded.get(r["srcPath"]), encoded.get(r["ttsPath"])
            cost = sum(len(x) + 64 for x in (src, tts) if x)
            if cost and not full and used + cost <= budget:
                r["srcAudio"], r["ttsAudio"], r["audioOmitted"] = src, tts, False
                used += cost
            else:
                full = full or bool(cost)
                r["srcAudio"] = r["ttsAudio"] = None
                r["audioOmitted"] = bool(cost)
        html = render()
        if len(html.encode()) <= MAX_BYTES:
            break
        if used == 0:  # nothing embedded left to drop
            print(
                "WARNING: report exceeds size cap even with all audio omitted",
                file=sys.stderr,
            )
            break
        budget = int(budget * 0.95)
    out = run_dir / "report.html"
    out.write_text(html, encoding="utf-8")
    return out
