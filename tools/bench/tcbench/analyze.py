"""Metrics from the Swift runner's raw.json files (every metric of the benchmark lives here).

Scales: chrF++ 0..100; wer, cutRate and mergeRate are fractions 0..1; latencies are
milliseconds.  Aggregates are keyed ``"<profile>/<runLine>"``; ``runLine`` is opaque and is
never parsed for a direction.  The one exception is reference lookup: the translation
reference of a line is the manifest translation for the language after ``>`` in ``runLine``.
"""

from __future__ import annotations

import functools
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any

from sacrebleu.metrics import CHRF

from .runs import target_lang
from .stats import summary
from .text import corpus_wer

COMET_MODEL = "Unbabel/wmt22-comet-da"
COMET_REVISION = "2760a223ac957f30acfb18c8aa649b01cf1d75f2"
STAGES = ("vad", "stt", "translate", "ttsFirstAudio", "total")
SHARED_META = ("set", "manifestSha256", "macOS", "machine", "commit", "dirty")


def comet_available() -> bool:
    return importlib.util.find_spec("comet") is not None


@functools.cache
def _comet_model():
    """Load the pinned checkpoint once per process."""
    from comet import load_from_checkpoint  # type: ignore[import-not-found]
    from huggingface_hub import snapshot_download

    # load_from_checkpoint reads hparams.yaml from the snapshot root, next to checkpoints/.
    root = Path(snapshot_download(COMET_MODEL, revision=COMET_REVISION))
    return load_from_checkpoint(str(root / "checkpoints" / "model.ckpt"))


def comet_score(triples: list[dict[str, str]]) -> float:
    """System-level COMET (mean segment score) for ``[{src, mt, ref}]``. Needs the 'comet' extra."""
    # num_workers=1: on Apple silicon COMET forces a "fork" loader context, which rejects 0 workers.
    out = _comet_model().predict(triples, batch_size=8, gpus=0, num_workers=1, progress_bar=False)
    return float(out.system_score)


def assign(raw: dict) -> dict[str, list[dict]]:
    """Clip id -> its utterances (by seq): speechStart inside [feedStartNs, next clip's feedStartNs)."""
    clips = sorted(raw["clips"], key=lambda c: c["feedStartNs"])
    out: dict[str, list[dict]] = {c["id"]: [] for c in clips}
    for utt in sorted(raw["utterances"], key=lambda u: u["seq"]):
        start = utt["events"].get("speechStart")
        if start is None:
            continue
        for i, clip in enumerate(clips):
            end = clips[i + 1]["feedStartNs"] if i + 1 < len(clips) else float("inf")
            if clip["feedStartNs"] <= start < end:
                out[clip["id"]].append(utt)
                break
    return out


def _is_merge(utt: dict, next_clip: dict | None) -> bool:
    if next_clip is None:
        return False
    seg = utt.get("detail", {}).get("vadEnd", {}).get("segmentAudioMs")
    start = utt["events"].get("speechStart")
    if seg is None or start is None:
        return False
    return start + float(seg) * 1_000_000 > next_clip["speechStartNs"]


def _latencies(utt: dict, speech_end_ns: int) -> dict[str, float]:
    ev = utt["events"]
    ms = 1e-6
    out: dict[str, float] = {}
    if "vadEnd" in ev:
        out["vad"] = (ev["vadEnd"] - speech_end_ns) * ms
    if "vadEnd" in ev and "sttFinal" in ev:
        out["stt"] = (ev["sttFinal"] - ev["vadEnd"]) * ms
    if "sttFinal" in ev and "translated" in ev:
        out["translate"] = (ev["translated"] - ev["sttFinal"]) * ms
    if "translated" in ev and "ttsFirstBuffer" in ev:
        out["ttsFirstAudio"] = (ev["ttsFirstBuffer"] - ev["translated"]) * ms
    if "ttsFirstBuffer" in ev:
        out["total"] = (ev["ttsFirstBuffer"] - speech_end_ns) * ms
    return out


def _cut_rate(cut_clips: int, clips: int, incomplete_turn: int = 0) -> float:
    """(cut clips + incomplete-turn clips) / (clips + incomplete-turn clips).

    ``incomplete_turn`` is the deferred Smart Turn term; it is always 0 today.
    """
    denominator = clips + incomplete_turn
    return (cut_clips + incomplete_turn) / denominator if denominator else 0.0


def _dropped(utt: dict) -> bool:
    return "dropped" in utt["events"]


def _heard(utt: dict) -> bool:
    return bool(utt.get("detail", {}).get("sttFinal", {}).get("text", "").strip())


def _joined(utts: list[dict], stage: str) -> str:
    texts = (u.get("detail", {}).get(stage, {}).get("text", "").strip() for u in utts)
    return " ".join(t for t in texts if t)


def analyze_line(raw: dict, manifest: dict, comet: bool = False) -> dict[str, Any]:
    clips = sorted(raw["clips"], key=lambda c: c["feedStartNs"])
    by_id = {c["id"]: c for c in manifest["clips"]}
    unknown = [c["id"] for c in clips if c["id"] not in by_id]
    if unknown:
        raise ValueError(f"clips not in the manifest: {unknown[:5]}")
    assigned = assign(raw)
    target = target_lang(raw.get("runLine", ""))
    first_seq = min((u["seq"] for u in raw["utterances"] if not _dropped(u)), default=None)
    unassigned = len(raw["utterances"]) - sum(len(v) for v in assigned.values())

    lat: dict[str, list[float]] = {s: [] for s in STAGES}
    cold: dict[str, list[float]] = {s: [] for s in STAGES}
    wer_pairs: list[tuple[str, str]] = []
    pipeline: list[dict[str, str]] = []
    cut = missed = merges = 0

    for i, clip in enumerate(clips):
        utts = assigned[clip["id"]]
        mclip = by_id[clip["id"]]
        next_clip = clips[i + 1] if i + 1 < len(clips) else None
        merges += sum(_is_merge(u, next_clip) for u in utts)
        if not utts:
            missed += 1
        if sum(_heard(u) for u in utts) > 1:
            cut += 1
        wer_pairs.append((mclip["transcript"], _joined(utts, "sttFinal")))
        ref = mclip.get("translations", {}).get(target) if target else None
        if ref:
            pipeline.append({"src": mclip["transcript"], "mt": _joined(utts, "translated"), "ref": ref})
        live = [u for u in utts if not _dropped(u)]
        if live:
            last = live[-1]
            bucket = cold if last["seq"] == first_seq else lat
            for stage, value in _latencies(last, clip["speechEndNs"]).items():
                bucket[stage].append(value)

    dropped: dict[str, int] = {}
    for u in raw["utterances"]:
        reason = u.get("detail", {}).get("dropped", {}).get("reason")
        if reason is not None:
            dropped[reason] = dropped.get(reason, 0) + 1

    engines = raw["meta"].get("engines", {})
    exp_stt, exp_tts = engines.get("expectedSTT"), engines.get("expectedTTS")
    fallbacks = 0
    for u in raw["utterances"]:
        d = u.get("detail", {})
        stt_engine = d.get("sttFinal", {}).get("engine")
        tts_engine = d.get("ttsFirstBuffer", {}).get("engine")
        if (exp_stt and stt_engine is not None and stt_engine != exp_stt) or (
            exp_tts and tts_engine is not None and tts_engine != exp_tts
        ):
            fallbacks += 1

    mt_refs = {s["id"]: s for s in manifest.get("mtOnly", [])}
    mt_triples = [
        {"src": mt_refs[r["id"]].get("src", ""), "mt": r["hyp"], "ref": mt_refs[r["id"]]["ref"]}
        for r in raw.get("mtOnly", [])
        if r.get("hyp") is not None and r["id"] in mt_refs and mt_refs[r["id"]].get("ref")
    ]

    chrf = CHRF(word_order=2)

    def chrf_score(triples: list[dict[str, str]]) -> float | None:
        if not triples:
            return None
        return float(chrf.corpus_score([t["mt"] for t in triples], [[t["ref"] for t in triples]]).score)

    comet_result = None
    if comet:
        comet_result = {
            "pipeline": comet_score(pipeline) if pipeline else None,
            "mtOnly": comet_score(mt_triples) if mt_triples else None,
        }

    n = len(clips)
    return {
        "latency": {s: summary(lat[s]) for s in STAGES},
        "latencyCold": {s: summary(cold[s]) for s in STAGES},
        "wer": corpus_wer(wer_pairs),
        "cutRate": _cut_rate(cut, n),
        "mergeRate": merges / n if n else 0.0,
        "missed": missed,
        "dropped": dropped,
        "chrf": {"pipeline": chrf_score(pipeline), "mtOnly": chrf_score(mt_triples)},
        "comet": comet_result,
        "fallbacks": fallbacks,
        "unassigned": unassigned,
    }


def _shared(raw: dict, path: Path) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key in SHARED_META:
        source = raw if key == "set" else raw.get("meta", {})
        if key not in source:
            raise ValueError(f"{path}: raw.json is missing {'set' if key == 'set' else 'meta.' + key}")
        out[key] = source[key]
    return out


def _run_meta(raws: list[tuple[Path, dict]]) -> dict[str, Any]:
    first_path, first = raws[0]
    meta = _shared(first, first_path)
    for path, raw in raws[1:]:
        other = _shared(raw, path)
        for key in SHARED_META:
            if other[key] != meta[key]:
                raise ValueError(
                    f"run lines disagree on {key}: {first_path} has {meta[key]!r}, {path} has {other[key]!r}"
                )
    meta["informative"] = any(r.get("informative", False) for _, r in raws)
    meta["override"] = next((r["override"] for _, r in raws if r.get("override") is not None), None)
    return meta


def run(run_dir: Path | str, manifest: dict, comet: bool = False) -> dict[str, Any]:
    run_dir = Path(run_dir)
    paths = sorted(run_dir.rglob("raw.json"))
    if not paths:
        raise FileNotFoundError(f"No raw.json found under {run_dir}")
    raws = [(p, json.loads(p.read_text())) for p in paths]
    meta = _run_meta(raws)
    aggregates: dict[str, Any] = {}
    for path, raw in raws:
        key = f"{raw['profile']}/{raw['runLine']}"
        if key in aggregates:
            raise ValueError(f"two raw.json files for {key}: {path}")
        agg = analyze_line(raw, manifest, comet=comet)
        aggregates[key] = agg
        (path.parent / "metrics.json").write_text(
            json.dumps({"meta": meta, "key": key, "aggregate": agg}, indent=2, sort_keys=True) + "\n"
        )
        if agg["unassigned"]:
            print(
                f"WARNING: {key}: {agg['unassigned']} utterance(s) fall outside every clip window (unassigned)",
                file=sys.stderr,
            )
        if agg["fallbacks"]:
            print(
                f"WARNING: {key}: {agg['fallbacks']} utterance(s) ran on an engine other than the expected "
                f"STT/TTS (runtime fallback); this run does not measure the configured engines",
                file=sys.stderr,
            )
    result = {"meta": meta, "aggregates": aggregates}
    (run_dir / "metrics.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result
