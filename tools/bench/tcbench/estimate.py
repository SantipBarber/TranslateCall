"""Expected wall time of a `just bench` run (REQ-BH-60), calibrated on the 2026-10-17 measurements:
per run line x profile, clip seconds x 2.0 + 15 s (session start, warm-up) + 0.3 s per MT-only sentence;
plus ~60 s once for the build, analysis and report. (3 Basic lines measured 137/131/136 s; 7m18s end to end.)

Usage: python -m tcbench.estimate <set> <profile> <lines-csv-or-empty> [--manifest P] [--cache DIR]
"""

import argparse
import json
import sys
import wave
from pathlib import Path

REALTIME_FACTOR = 2.0
MT_SECONDS = 0.3
LINE_OVERHEAD_SECONDS = 15.0
FIXED_OVERHEAD_SECONDS = 60.0
PR_LIMIT_MINUTES = 10.0

# slug -> (clip variant, incoming, MT source language, MT target language); mirrors BenchRunLine.all in Swift.
LINES = {
    "outgoing-es-ES-en": ("es-ES", False, "es", "en"),
    "outgoing-es-419-en": ("es-419", False, "es", "en"),
    "outgoing-en-es": ("en", False, "en", "es"),
    "incoming-en-es": ("en", True, "en", "es"),
}


def _clip_seconds(clip: dict, cache: Path) -> float:
    try:
        with wave.open(str(cache / clip["audio"])) as w:
            return w.getnframes() / w.getframerate()
    except (OSError, wave.Error, EOFError):
        return clip["speechEndMs"] / 1000 + 1.0


def estimate(manifest: dict, cache: Path, set_: str, profile: str, lines: list[str]) -> tuple[float, int, int]:
    """Returns (seconds, clip count, MT sentence count) over every selected line x profile pair."""
    unknown = [slug for slug in lines if slug not in LINES]
    if unknown:
        raise ValueError(f"unknown run lines: {', '.join(unknown)} (known: {', '.join(LINES)})")
    selected = lines or list(LINES)
    profiles = ["basic", "best"] if profile == "all" else [profile]
    seconds, clips, mt = 0.0, 0, 0
    for slug in selected:
        variant, incoming, src, tgt = LINES[slug]
        for p in profiles:
            if p == "best" and incoming:
                continue
            chosen = [c for c in manifest["clips"] if c["variant"] == variant and set_ in c["tiers"]]
            sentences = [m for m in manifest["mtOnly"] if m["srcLang"] == src and m["tgtLang"] == tgt and set_ in m["tiers"]]
            seconds += (sum(_clip_seconds(c, cache) for c in chosen) * REALTIME_FACTOR
                        + len(sentences) * MT_SECONDS + LINE_OVERHEAD_SECONDS)
            clips += len(chosen)
            mt += len(sentences)
    if clips == 0:
        raise ValueError(f"no clips in set {set_} for run lines {', '.join(selected)} and profile {profile} "
                         "— check the manifest (just bench-manifest) and the line names")
    return seconds + FIXED_OVERHEAD_SECONDS, clips, mt


def main(argv: list[str] | None = None) -> int:
    from . import sources

    root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("set", choices=["pr", "full"])
    parser.add_argument("profile", choices=["basic", "best", "all"])
    parser.add_argument("lines", nargs="?", default="")
    parser.add_argument("--manifest", default=str(root / "bench" / "manifests" / "phase1.json"))
    parser.add_argument("--cache", default=str(sources.default_cache_dir()))
    args = parser.parse_args(argv)
    manifest = json.loads(Path(args.manifest).read_text())
    slugs = [s.strip() for s in args.lines.split(",") if s.strip()]
    try:
        seconds, clips, mt = estimate(manifest, Path(args.cache), args.set, args.profile, slugs)
    except ValueError as exc:
        print(f"✗ {exc}", file=sys.stderr)
        return 2
    print(f"expected duration: {seconds / 60:.1f} min ({clips} clips, {mt} MT sentences, set={args.set})")
    if args.set == "pr" and seconds / 60 > PR_LIMIT_MINUTES:
        print(f"WARNING: the PR bench is expected to take over {PR_LIMIT_MINUTES:.0f} min (NFR-BH-02) — "
              "narrow it with profile=/lines= or cut the PR set", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
