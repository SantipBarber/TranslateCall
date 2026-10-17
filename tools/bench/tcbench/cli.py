"""Command-line interface for tcbench."""

import argparse
import json
import sys
from pathlib import Path

from tcbench import baseline, compare

COMMANDS = ["fetch", "manifest", "ingest", "analyze", "compare", "report", "baseline"]


def _load_json(path: str) -> dict:
    return json.loads(Path(path).read_text())


def _load_run(run_dir: str) -> tuple[dict, dict]:
    p = Path(run_dir) / "metrics.json"
    if not p.exists():
        print(f"No metrics.json found in {run_dir}", file=sys.stderr)
        raise SystemExit(2)
    payload = _load_json(str(p))
    meta = payload.get("meta")
    if meta is None:
        run_json = Path(run_dir) / "run.json"
        if run_json.exists():
            meta = _load_json(str(run_json))
    if not isinstance(meta, dict):
        print(f"No run metadata found in {run_dir}", file=sys.stderr)
        raise SystemExit(2)
    return meta, payload.get("aggregates", {})


def _cmd_compare(args: argparse.Namespace) -> int:
    run_meta, run_metrics = _load_run(args.run)

    if args.baseline_from_run:
        base_meta, base_metrics = _load_run(args.baseline_from_run)
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

    thresholds = _load_json(args.thresholds)
    table, exit_code = compare.run(run_metrics, baseline_doc, thresholds, run_meta)
    print(table)
    return exit_code


def _cmd_baseline(args: argparse.Namespace) -> int:
    try:
        baseline.run(args.run, args.reason, repo_dirty=args.repo_dirty)
    except baseline.BaselineRefusal as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except FileNotFoundError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tcbench", description="TranslateCall benchmark tooling")
    sub = parser.add_subparsers(dest="command", required=True)

    for name in COMMANDS:
        if name in ("compare", "baseline"):
            continue
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
    baseline_parser.add_argument("--repo-dirty", action="store_true", help="Passed when the git tree is dirty")
    baseline_parser.set_defaults(func=_cmd_baseline)

    args = parser.parse_args(argv)
    if hasattr(args, "func"):
        return args.func(args)

    print(f"tcbench {args.command}: not implemented", file=sys.stderr)
    raise SystemExit(2)


if __name__ == "__main__":
    raise SystemExit(main())
