"""Expected wall time of a `just bench` run: clip seconds x 1.6 plus 0.3 s per MT-only sentence (REQ-BH-60).

Usage: python -m tcbench.estimate <set> <profile> <lines-csv-or-empty> [--manifest P] [--cache DIR]
"""

import argparse
import json
import wave
from pathlib import Path

REALTIME_FACTOR = 1.6
MT_SECONDS = 0.3

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
            seconds += sum(_clip_seconds(c, cache) for c in chosen) * REALTIME_FACTOR + len(sentences) * MT_SECONDS
            clips += len(chosen)
            mt += len(sentences)
    return seconds, clips, mt


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
    seconds, clips, mt = estimate(manifest, Path(args.cache), args.set, args.profile, slugs)
    print(f"expected duration: {seconds / 60:.1f} min ({clips} clips, {mt} MT sentences, set={args.set})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
