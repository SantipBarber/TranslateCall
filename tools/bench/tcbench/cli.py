"""Command-line interface for tcbench."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

from tcbench import baseline, compare, runs

STUBS = ("analyze", "report")
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
    import numpy as np

    for k, v in sorted(cfg.stats.items()):
        print(f"{k}: candidates {v['candidates']}, tried {v['tried']}, drops {v['dropped']}, duplicates {v['dropped_dup']}")
        print(f"  kept full {v['kept']} / quota {v['quota']}, kept PR {v['kept_pr']} / {v['quota_pr']}")
        if v["kept"] < v["quota"] or v["kept_pr"] < v["quota_pr"]:
            print(f"WARNING: {k} fell short: full {v['kept']}/{v['quota']}, PR {v['kept_pr']}/{v['quota_pr']}", file=sys.stderr)
        for name in ("end_offsets_all", "end_offsets_kept"):
            if v[name]:
                print(f"  silero end - refined end ({name}): median {np.median(v[name]):.0f} ms, p90 {np.percentile(v[name], 90):.0f} ms, n={len(v[name])}")
    print(f"wrote {out}: {len(m['clips'])} clips, {len(m['mtOnly'])} mt-only sentences")
    return 0


def _parse_bool(s: str) -> bool:
    s = s.lower()
    if s in ("true", "1", "yes"):
        return True
    if s in ("false", "0", "no"):
        return False
    raise argparse.ArgumentTypeError(f"expected true/false, got {s!r}")


def _cmd_ingest(args) -> int:
    try:
        import silero_vad  # noqa: F401
    except ImportError:
        print(
            "tcbench ingest needs silero-vad (optional extra 'vad').\n"
            "Run: uv run --locked --extra vad --project tools/bench tcbench ingest ...",
            file=sys.stderr,
        )
        return 1
    from . import ingest

    sheet = args.sheet or str(REPO / "bench" / "prompts" / f"{args.variant}.md")
    problems = ingest.run(
        Path(args.dir), Path(sheet), args.variant, args.native, Path(args.manifest)
    )
    for p in problems:
        print(p)
    return 1 if problems else 0


def _cmd_fetch(args) -> int:
    from . import fetch, sources

    cache = sources.default_cache_dir()
    fetch.run(args.manifest, cache, args.set, limit=args.limit)
    if args.prune:
        import shutil

        shutil.rmtree(cache / "_downloads", ignore_errors=True)
        print("pruned downloaded archives")
    return 0


def _load_json(path: str) -> dict:
    return json.loads(Path(path).read_text())


def _repo_is_dirty(repo_dir: Path | str | None = None) -> bool:
    """Return True if the git working tree under ``repo_dir`` has changes.

    Defaults to the repository root (three parents above this file).  Fails
    closed: if git is missing or ``git status`` errors, print a stderr warning
    and treat the tree as dirty so the baseline gate does not accept it.
    """
    if repo_dir is None:
        repo_dir = REPO
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain"],
            capture_output=True,
            text=True,
            check=True,
            cwd=repo_dir,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        print("cannot check git status — refusing", file=sys.stderr)
        return True
    return bool(result.stdout.strip())


def _cmd_compare(args: argparse.Namespace) -> int:
    try:
        run_meta, run_metrics = runs.load_run(args.run)
    except (FileNotFoundError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2

    if args.baseline_from_run:
        try:
            base_meta, base_metrics = runs.load_run(args.baseline_from_run)
        except (FileNotFoundError, ValueError) as exc:
            print(str(exc), file=sys.stderr)
            return 2
        baseline_doc = {
            "manifestSha256": base_meta.get("manifestSha256"),
            "macOS": base_meta.get("macOS"),
            "aggregates": base_metrics,
        }
    else:
        baseline_path = Path(args.baseline)
        if not baseline_path.exists():
            print(f"Baseline not found: {args.baseline}", file=sys.stderr)
            return 2
        baseline_doc = _load_json(args.baseline)

    try:
        thresholds = _load_json(args.thresholds)
    except FileNotFoundError:
        print(f"Thresholds not found: {args.thresholds}", file=sys.stderr)
        return 2

    table, exit_code = compare.run(run_metrics, baseline_doc, thresholds, run_meta)
    print(table)
    return exit_code


def _cmd_baseline(args: argparse.Namespace) -> int:
    try:
        baseline.run(args.run, args.reason, repo_dirty=_repo_is_dirty())
    except baseline.BaselineRefusal as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except (FileNotFoundError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
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
    i = sub.add_parser("ingest", help="ingest the user's own recordings into the manifest")
    i.add_argument("dir", help="folder containing the recordings")
    i.add_argument("--variant", choices=["es-ES", "en"], required=True)
    i.add_argument("--native", type=_parse_bool, required=True, help="true or false")
    i.add_argument("--sheet", default=None, help="override the default prompt sheet")
    i.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    i.set_defaults(func=_cmd_ingest)

    for name in STUBS:
        sub.add_parser(name)

    compare_parser = sub.add_parser("compare")
    compare_parser.add_argument("run", help="Path to a run directory containing metrics.json")
    compare_parser.add_argument("--baseline", default="bench/baseline.json", help="Path to baseline.json")
    compare_parser.add_argument("--baseline-from-run", help="Use another run's aggregates as baseline")
    compare_parser.add_argument("--thresholds", default="bench/thresholds.json", help="Path to thresholds.json")
    compare_parser.set_defaults(func=_cmd_compare)

    baseline_parser = sub.add_parser("baseline")
    baseline_parser.add_argument("run", help="Path to the run directory to promote")
    baseline_parser.add_argument("--reason", required=True, help="Why this baseline is being set")
    baseline_parser.set_defaults(func=_cmd_baseline)

    args = parser.parse_args(argv)
    if hasattr(args, "func"):
        return args.func(args)
    print(f"tcbench {args.command}: not implemented", file=sys.stderr)
    raise SystemExit(2)


if __name__ == "__main__":
    raise SystemExit(main())
