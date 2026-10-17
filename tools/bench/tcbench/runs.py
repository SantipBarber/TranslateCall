"""Run-directory loading contract.

A run directory must contain a ``metrics.json`` file with this exact shape:

    {
      "meta": {
        "set": "pr" | "full",
        "manifestSha256": str,
        "macOS": str,
        "machine": str,
        "commit": str,
        "dirty": bool,
        "informative": bool,
        "override": str | None
      },
      "aggregates": {
        "<profile>/<runLine>": {
          "latency": {"<stage>": {"p50": float|None, "p90": float|None, ...}, ...},
          "latencyCold": {...},
          "wer": float,
          "cutRate": float,
          "mergeRate": float,
          "missed": int,
          "dropped": {str: int},
          "chrf": {"pipeline": float|None, "mtOnly": float|None},
          "comet": {"pipeline": float|None, "mtOnly": float|None} | None
        }
      }
    }

``load_run`` returns ``(meta, aggregates)`` and raises ``FileNotFoundError`` if
``metrics.json`` is missing or ``ValueError`` if the required keys are absent.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def load_run(run_dir: Path | str) -> tuple[dict[str, Any], dict[str, Any]]:
    """Load a run directory's metadata and aggregate metrics."""
    run_dir = Path(run_dir)
    metrics_path = run_dir / "metrics.json"
    if not metrics_path.exists():
        raise FileNotFoundError(f"No metrics.json found in {run_dir}")

    payload = json.loads(metrics_path.read_text())
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise ValueError(f"No run metadata found in {run_dir}")

    required = {"set", "manifestSha256", "macOS", "machine", "commit", "dirty", "informative", "override"}
    missing = required - meta.keys()
    if missing:
        raise ValueError(f"Run metadata missing keys {sorted(missing)} in {run_dir}")

    aggregates = payload.get("aggregates", {})
    if not isinstance(aggregates, dict):
        raise ValueError(f"Run aggregates must be a dict in {run_dir}")

    return meta, aggregates
