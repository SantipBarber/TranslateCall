"""Write and manage the benchmark baseline file."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from tcbench import runs

REPO = Path(__file__).resolve().parents[3]


class BaselineRefusal(Exception):
    """Raised when a run cannot be promoted to baseline."""


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(
    run_dir: Path | str,
    reason: str,
    repo_dirty: bool,
    output: Path | str | None = None,
) -> None:
    """Promote ``run_dir`` to the official baseline.

    Raises ``BaselineRefusal`` with a human-readable message if the repository
    is dirty, the run is not full, the run lacks PR-subset aggregates, the run
    itself was produced from a dirty tree, or the run is informative/overridden.
    """
    run_dir = Path(run_dir)
    if output is None:
        output = REPO / "bench" / "baseline.json"
    else:
        output = Path(output)

    if repo_dirty:
        raise BaselineRefusal(
            "Refusing to update baseline: repository has uncommitted changes."
        )

    meta, aggregates = runs.load_run(run_dir)
    pr_aggregates = runs.load_pr_aggregates(run_dir)

    if meta.get("set") != "full":
        raise BaselineRefusal("baseline needs a full run")

    if pr_aggregates is None:
        raise BaselineRefusal(
            "Refusing to update baseline: the run has no PR-subset aggregates (prAggregates) — re-run `tcbench analyze` on it first."
        )

    if meta.get("dirty"):
        raise BaselineRefusal(
            "Refusing to update baseline: the run was produced from a dirty repository."
        )

    if meta.get("informative"):
        raise BaselineRefusal(
            "Refusing to update baseline: run is marked informative (not a full benchmark)."
        )

    if meta.get("override"):
        raise BaselineRefusal(
            "Refusing to update baseline: run was produced with an override configuration."
        )

    baseline = {
        "reason": reason,
        "date": _today(),
        "commit": meta.get("commit"),
        "manifestSha256": meta.get("manifestSha256"),
        "macOS": meta.get("macOS"),
        "machine": meta.get("machine"),
        "set": meta.get("set"),
        "aggregates": aggregates,
        "prAggregates": pr_aggregates,
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(baseline, indent=2) + "\n")
