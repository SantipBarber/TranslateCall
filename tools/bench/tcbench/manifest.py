"""Deterministic phase-1 manifest builder (REQ-BH-01, 03, 04, 07, 08)."""

from __future__ import annotations

import hashlib
import json
import random
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from . import audio as audio_mod
from .groundtruth import speech_span
from .sources import ALLOWED_LICENCES, Candidate

SCHEMA = 1
SHORT = {"fleurs": "fleurs", "voxpopuli": "vp", "common_voice": "cv"}


@dataclass
class SourcesConfig:
    audio: list = field(default_factory=list)
    text: list = field(default_factory=list)
    full_n: int = 300
    pr_n: int = 8
    pr_max_s: float = 6.0
    min_s: float = 2.0
    max_s: float = 12.0
    min_lead_ms: float = 200.0  # silence required before speechStart ...
    min_tail_ms: float = 300.0  # ... and after speechEnd, inside the file
    mt_full: int = 200
    mt_pr: int = 100
    mt_directions: tuple = (("en", "es"), ("es", "en"))
    log: object = print
    stats: dict = field(default_factory=dict)


def _check_licences(cfg: SourcesConfig) -> None:
    for src in [*cfg.audio, *cfg.text]:
        if src.licence not in ALLOWED_LICENCES:
            raise ValueError(f"source {src.dataset!r} has licence {src.licence!r}, which is not in the allow-list {sorted(ALLOWED_LICENCES)}")


def _order(cands: list[Candidate], rng: random.Random) -> list[Candidate]:
    """Seeded shuffle, then every sentence's first recording before any second one (speaker/sentence diversity)."""
    cands = sorted(cands, key=lambda c: c.original_id)
    rng.shuffle(cands)
    seen: dict[str, int] = {}
    ranked = []
    for c in cands:
        sentence = c.transcript.strip().lower()
        rank = seen.get(sentence, 0)
        seen[sentence] = rank + 1
        ranked.append((rank, c))
    ranked.sort(key=lambda t: t[0])  # stable: keeps the shuffled order inside each rank
    return [c for _, c in ranked]


def _select_variant(src, variant: str, cfg: SourcesConfig, seed: int, claimed: set[str], tmp: Path):
    """Return [(Candidate, wav sha256, start_ms, end_ms, is_pr, gain_db)] for one source variant."""
    rng = random.Random(f"{seed}:{src.dataset}:{variant}")
    ordered = [c for c in _order(src.candidates(variant), rng) if cfg.min_s <= c.duration_s <= cfg.max_s]
    stat = cfg.stats.setdefault(f"{src.dataset}/{variant}", {"candidates": len(ordered), "tried": 0, "dropped": {}, "dropped_dup": 0, "end_offsets_all": [], "end_offsets_kept": []})
    accepted: list[tuple] = []
    tried: set[str] = set()
    speakers: dict[str, int] = {}
    speaker_cap = getattr(src, "max_per_speaker", None)

    def process(batch: list[Candidate], cap: int, is_pr: bool) -> None:
        """Accept clips from `batch` until `accepted` holds `cap` clips."""
        batch = [c for c in batch if c.original_id not in tried]
        if not batch:
            return
        raw = src.raw_audio([c.original_id for c in batch])
        for c in batch:
            if len(accepted) >= cap:
                return
            if speaker_cap is not None and speakers.get(c.speaker, 0) >= speaker_cap:
                continue  # per-speaker cap: a few speakers must not dominate
            tried.add(c.original_id)
            stat["tried"] += 1
            source_samples = audio_mod.normalize(raw[c.original_id])
            why: dict = {}
            # Pass 1 locates the speech on the float source to set the level; pass 2 measures the ground
            # truth on the exact int16 samples written to the cache (the runner plays those).
            first = speech_span(source_samples, why=why)
            if first is None:
                span, gain, samples = None, 0.0, source_samples
            else:
                gain = audio_mod.level_gain_db(source_samples, first)
                q = audio_mod.apply_gain_q16(source_samples, gain)
                samples = audio_mod.from_int16(q)
                why = {}
                span = speech_span(samples, why=why)
            reason = why.get("reason", "unknown") if span is None else None
            if span is not None and span[0] < cfg.min_lead_ms:
                reason = "lead<%dms" % cfg.min_lead_ms
            elif span is not None and len(samples) * 1000.0 / 16000 - span[1] < cfg.min_tail_ms:
                reason = "tail<%dms" % cfg.min_tail_ms
            if "silero" in why and "refined" in why:
                stat["end_offsets_all"].append(why["silero"][1] - why["refined"][1])
            if reason:
                stat["dropped"][reason] = stat["dropped"].get(reason, 0) + 1
                cfg.log(f"drop {src.dataset}/{variant} {c.original_id}: {reason}")
                continue
            path = tmp / "candidate.wav"
            audio_mod.write_wav16(path, q)
            sha = audio_mod.sha256(path)
            if sha in claimed:
                stat["dropped_dup"] += 1
                continue
            claimed.add(sha)
            speakers[c.speaker] = speakers.get(c.speaker, 0) + 1
            if "silero" in why:
                stat["end_offsets_kept"].append(why["silero"][1] - why["refined"][1])
            accepted.append((c, sha, span[0], span[1], is_pr, gain))

    short = [c for c in ordered if c.duration_s <= cfg.pr_max_s]
    process(short[: cfg.pr_n * 4], cfg.pr_n, True)
    pos = 0
    while len(accepted) < cfg.full_n and pos < len(ordered):
        need = cfg.full_n - len(accepted)
        batch = ordered[pos : pos + max(need + need // 4, 8)]
        pos += len(batch)
        process(batch, cfg.full_n, False)
    stat.update(kept=len(accepted), kept_pr=sum(1 for a in accepted if a[4]), quota=cfg.full_n, quota_pr=cfg.pr_n)
    return accepted


def _mt(cfg: SourcesConfig, seed: int) -> list[dict]:
    out = []
    for src in cfg.text:
        for s_lang, t_lang in cfg.mt_directions:
            pairs = [(i, a, b) for i, (a, b) in enumerate(src.pairs(s_lang, t_lang)) if a and b]
            rng = random.Random(f"{seed}:{src.dataset}:{s_lang}>{t_lang}")
            picked = rng.sample(pairs, min(cfg.mt_full, len(pairs)))
            for n, (_, a, b) in enumerate(picked, 1):
                out.append(
                    {
                        "id": f"mt-{s_lang}-{t_lang}-{n:04d}",
                        "srcLang": s_lang,
                        "tgtLang": t_lang,
                        "src": a,
                        "ref": b,
                        "tiers": ["pr", "full"] if n <= cfg.mt_pr else ["full"],
                    }
                )
    return out


def build(sources_cfg: SourcesConfig, seed: int = 1729) -> dict:
    cfg = sources_cfg
    _check_licences(cfg)
    clips: list[dict] = []
    claimed: dict[str, set[str]] = {}  # per language: sha256 of normalised audio already used
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        for src in sorted(cfg.audio, key=lambda s: s.dataset):
            for variant in sorted(src.variants()):
                lang_key = variant.split("-")[0]
                sel = _select_variant(src, variant, cfg, seed, claimed.setdefault(lang_key, set()), tmp)
                sel.sort(key=lambda a: a[0].original_id)
                for n, (c, sha, start, end, is_pr, gain) in enumerate(sel, 1):
                    clips.append(
                        {
                            "id": f"{SHORT.get(src.dataset, src.dataset)}-{variant.lower()}-{n:04d}",
                            "source": {"dataset": src.dataset, "revision": src.revision, "originalId": c.original_id},
                            "lang": c.lang,
                            "variant": variant,
                            "speaker": c.speaker,
                            "nativeSpeaker": c.native,
                            "transcript": c.transcript,
                            "translations": c.translations,
                            "gainDb": gain,
                            "speechStartMs": start,
                            "speechEndMs": end,
                            "tags": c.tags,
                            "tiers": ["pr", "full"] if is_pr else ["full"],
                            "sha256": sha,
                            "licence": src.licence,
                            "audio": f"{src.dataset}/{variant}/{SHORT.get(src.dataset, src.dataset)}-{variant.lower()}-{n:04d}.wav",
                        }
                    )
    return {"schema": SCHEMA, "clips": clips, "mtOnly": _mt(cfg, seed)}


def dump(m: dict, path) -> None:
    Path(path).write_text(json.dumps(m, sort_keys=True, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def sha256_file(path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()
