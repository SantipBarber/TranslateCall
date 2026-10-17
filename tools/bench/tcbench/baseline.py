"""Write and manage the benchmark baseline file.

A run directory is expected to contain ``metrics.json`` shaped as documented in
``tcbench.compare``:

    {
      "meta": {...},
      "aggregates": {...}
    }

``baseline.run`` reads that file and writes ``bench/baseline.json`` with the
run metadata, the provided reason, the current date, and the aggregate metrics.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class BaselineRefusal(Exception):
    """Raised when a run cannot be promoted to baseline."""


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _load_run(run_dir: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    metrics_path = run_dir / "metrics.json"
    if not metrics_path.exists():
        raise FileNotFoundError(f"No metrics.json found in {run_dir}")
    payload = json.loads(metrics_path.read_text())
    meta = payload.get("meta")
    if meta is None:
        # Fallback: look for a sibling run.json.
        run_json = run_dir / "run.json"
        if run_json.exists():
            meta = json.loads(run_json.read_text())
    if not isinstance(meta, dict):
        raise BaselineRefusal(f"No run metadata found in {run_dir}")
    aggregates = payload.get("aggregates", {})
    return meta, aggregates


def run(
    run_dir: Path | str,
    reason: str,
    repo_dirty: bool,
    output: Path | str | None = None,
) -> None:
    """Promote ``run_dir`` to the official baseline.

    Raises ``BaselineRefusal`` with a human-readable message if the run is
    dirty, informative, or overridden.
    """
    run_dir = Path(run_dir)
    if output is None:
        output = Path("bench/baseline.json")
    else:
        output = Path(output)

    if repo_dirty:
        raise BaselineRefusal(
            "Refusing to update baseline: repository has uncommitted changes."
        )

    meta, aggregates = _load_run(run_dir)

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
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(baseline, indent=2) + "\n")
