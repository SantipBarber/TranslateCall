import argparse
import sys
from pathlib import Path

COMMANDS = ["ingest", "analyze", "compare", "report", "baseline"]
REPO = Path(__file__).resolve().parents[3]
DEFAULT_MANIFEST = REPO / "bench" / "manifests" / "phase1.json"


def _cmd_manifest(args) -> int:
    try:
        import silero_vad  # noqa: F401
    except ImportError:
        print(
            "tcbench manifest needs silero-vad (optional extra 'vad').\n"
            "Run: uv run --locked --extra vad --project tools/bench tcbench manifest",
            file=sys.stderr,
        )
        return 1
    from . import manifest, sources

    cache = sources.default_cache_dir()
    audio_sources, text_sources = sources.phase1_sources(cache)
    cfg = manifest.SourcesConfig(audio=audio_sources, text=text_sources)
    note = sources.CommonVoice.skip_reason()
    print(note, file=sys.stderr)
    m = manifest.build(cfg, seed=args.seed)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    manifest.dump(m, out)
    for k, v in sorted(cfg.stats.items()):
        print(f"{k}: {v}")
    print(f"wrote {out}: {len(m['clips'])} clips, {len(m['mtOnly'])} mt-only sentences")
    return 0


def _cmd_fetch(args) -> int:
    from . import fetch, sources

    cache = sources.default_cache_dir()
    fetch.run(args.manifest, cache, args.set, limit=args.limit)
    if args.prune:
        import shutil

        shutil.rmtree(cache / "_downloads", ignore_errors=True)
        print("pruned downloaded archives")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tcbench", description="TranslateCall benchmark tooling")
    sub = parser.add_subparsers(dest="command", required=True)
    f = sub.add_parser("fetch", help="download and normalise manifest clips into the local cache")
    f.add_argument("--set", choices=["pr", "full"], default="pr")
    f.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    f.add_argument("--limit", type=int, default=None)
    f.add_argument("--prune", action="store_true", help="delete the downloaded source archives afterwards")
    f.set_defaults(func=_cmd_fetch)
    m = sub.add_parser("manifest", help="select clips, compute ground truth, write the manifest (needs the 'vad' extra)")
    m.add_argument("--out", default=str(DEFAULT_MANIFEST))
    m.add_argument("--seed", type=int, default=1729)
    m.set_defaults(func=_cmd_manifest)
    for name in COMMANDS:
        sub.add_parser(name)
    args = parser.parse_args(argv)
    if hasattr(args, "func"):
        code = args.func(args)
        if code:
            raise SystemExit(code)
        return 0
    print(f"tcbench {args.command}: not implemented", file=sys.stderr)
    raise SystemExit(2)


if __name__ == "__main__":
    main()
