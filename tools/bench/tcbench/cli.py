"""Command-line interface for tcbench."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

from tcbench import baseline, compare, runs

COMMANDS = ["fetch", "manifest", "ingest", "analyze", "compare", "report", "baseline"]


def _load_json(path: str) -> dict:
    return json.loads(Path(path).read_text())


def _repo_is_dirty(repo_dir: Path | str | None = None) -> bool:
    """Return True if the git working tree under ``repo_dir`` has changes.

    Defaults to the repository root (three parents above this file).  Fails
    closed: if git is missing or ``git status`` errors, print a stderr warning
    and treat the tree as dirty so the baseline gate does not accept it.
    """
    if repo_dir is None:
        repo_dir = Path(__file__).resolve().parents[3]
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
    baseline_parser.set_defaults(func=_cmd_baseline)

    args = parser.parse_args(argv)
    if hasattr(args, "func"):
        return args.func(args)

    print(f"tcbench {args.command}: not implemented", file=sys.stderr)
    raise SystemExit(2)


if __name__ == "__main__":
    raise SystemExit(main())
