"""Baseline comparison for TranslateCall benchmark runs.

A run directory is expected to contain a ``metrics.json`` file shaped as:

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
          "dropped": {...},
          "chrf": {"pipeline": float|None, "mtOnly": float|None},
          "comet": {"pipeline": float|None, "mtOnly": float|None} | None
        }
      }
    }

The baseline file is ``bench/baseline.json`` and contains the same ``meta``-like
fields plus an ``aggregates`` key with the same shape.
"""

from __future__ import annotations

import sys
from typing import Any


def _pct_change(baseline: float | None, value: float | None) -> float | None:
    if baseline is None or value is None or baseline == 0:
        return None
    return (value - baseline) / baseline * 100.0


def _delta(baseline: float | None, value: float | None) -> float | None:
    if baseline is None or value is None:
        return None
    return value - baseline


def _fmt(value: float | None, precision: int = 2) -> str:
    if value is None:
        return "n/a"
    return f"{value:.{precision}f}"


def _latency_gate(
    baseline: float | None,
    value: float | None,
    thresholds: dict[str, Any],
    set_type: str,
    metric: str,
) -> tuple[str | None, bool]:
    """Return (display delta override, fail). Latency is only gated for full runs."""
    if set_type != "full":
        return "·", False
    change = _pct_change(baseline, value)
    threshold = (
        thresholds["latencyP50RegressionPct"]
        if metric == "p50"
        else thresholds["latencyP90RegressionPct"]
    )
    fail = change is not None and change > threshold
    return None, fail


def _wer_gate(baseline: float, value: float, thresholds: dict[str, Any]) -> bool:
    """WER is stored as a fraction; thresholds are in percentage points."""
    return (value - baseline) * 100.0 > thresholds["werIncreasePts"]


def _chrf_gate(baseline: float | None, value: float | None, thresholds: dict[str, Any]) -> bool:
    if baseline is None or value is None:
        return False
    return baseline - value > thresholds["chrfDropPts"]


def _cut_rate_gate(baseline: float, value: float, thresholds: dict[str, Any]) -> bool:
    """cutRate is stored as a fraction; thresholds are in percentage points."""
    max_allowed = max(
        thresholds["cutRateMaxPct"],
        baseline * 100.0 + thresholds["cutRateIncreasePts"],
    )
    return value * 100.0 > max_allowed


def _comet_gate(baseline: float | None, value: float | None, thresholds: dict[str, Any]) -> bool:
    """COMET has no dedicated threshold; reuse chrF drop tolerance."""
    return _chrf_gate(baseline, value, thresholds)


def _row(label: str, baseline: str, value: str, delta: str, verdict: str) -> str:
    return f"{label:24} {baseline:>12} {value:>12} {delta:>12} {verdict}"


def run(
    run_metrics: dict[str, Any],
    baseline: dict[str, Any],
    thresholds: dict[str, Any],
    run_meta: dict[str, Any],
) -> tuple[str, int]:
    """Compare ``run_metrics`` against ``baseline`` using ``thresholds``.

    Returns a tuple of (human-readable table, exit code).  Exit codes:
      * 0 - no gated regressions (or run is informative/overridden);
      * 1 - at least one gated metric regressed;
      * 3 - baseline manifest changed, re-baseline required.
    """
    lines: list[str] = []
    gated_fail = False
    gated = run_meta.get("set") == "full" and not run_meta.get("informative") and not run_meta.get("override")

    if run_meta.get("manifestSha256") != baseline.get("manifestSha256"):
        print(
            "manifest changed — re-baseline with `just bench-baseline`",
            file=sys.stderr,
        )
        raise SystemExit(3)

    if run_meta.get("macOS") != baseline.get("macOS"):
        print(
            f"macOS changed: baseline={baseline.get('macOS')} run={run_meta.get('macOS')}",
            file=sys.stderr,
        )

    if run_meta.get("informative") or run_meta.get("override"):
        lines.append(
            "=== informative / overridden run: results shown for comparison only, no gating ==="
        )

    lines.append(_row("metric", "baseline", "value", "delta", "verdict"))
    lines.append("-" * 64)

    base_aggs = baseline.get("aggregates", {})

    for key in sorted(run_metrics):
        run_entry = run_metrics[key]
        base_entry = base_aggs.get(key, {})
        lines.append(f"[{key}]")

        # Latency total p50 / p90
        latency_b = base_entry.get("latency", {})
        latency_v = run_entry.get("latency", {})
        for stage, metric in [("total", "p50"), ("total", "p90")]:
            b = latency_b.get(stage, {}).get(metric)
            v = latency_v.get(stage, {}).get(metric)
            delta, fail = _latency_gate(b, v, thresholds, run_meta.get("set", "full"), metric)
            if delta == "·":
                verdict = "·"
            elif fail and gated:
                verdict = "❌"
                gated_fail = True
            else:
                verdict = "✅"
            display_delta = delta if delta is not None else _fmt(_pct_change(b, v)) + "%"
            lines.append(
                _row(
                    f"  latency {stage} {metric}",
                    _fmt(b),
                    _fmt(v),
                    display_delta,
                    verdict,
                )
            )

        # WER
        b_wer = base_entry.get("wer", 0.0)
        v_wer = run_entry.get("wer", 0.0)
        wer_fail = _wer_gate(b_wer, v_wer, thresholds)
        if wer_fail and gated:
            verdict = "❌"
            gated_fail = True
        else:
            verdict = "✅"
        lines.append(
            _row(
                "  WER",
                f"{_fmt(b_wer * 100.0)}%",
                f"{_fmt(v_wer * 100.0)}%",
                f"{_fmt((v_wer - b_wer) * 100.0)} pts",
                verdict,
            )
        )

        # Cut rate
        b_cut = base_entry.get("cutRate", 0.0)
        v_cut = run_entry.get("cutRate", 0.0)
        cut_fail = _cut_rate_gate(b_cut, v_cut, thresholds)
        if cut_fail and gated:
            verdict = "❌"
            gated_fail = True
        else:
            verdict = "✅"
        lines.append(
            _row(
                "  cut rate",
                f"{_fmt(b_cut * 100.0)}%",
                f"{_fmt(v_cut * 100.0)}%",
                f"{_fmt((v_cut - b_cut) * 100.0)} pts",
                verdict,
            )
        )

        # chrF++
        b_chrf = base_entry.get("chrf", {})
        v_chrf = run_entry.get("chrf", {})
        for sub in ("pipeline", "mtOnly"):
            b = b_chrf.get(sub)
            v = v_chrf.get(sub)
            chrf_fail = _chrf_gate(b, v, thresholds)
            if chrf_fail and gated:
                verdict = "❌"
                gated_fail = True
            else:
                verdict = "✅"
            lines.append(
                _row(
                    f"  chrF++ {sub}",
                    _fmt(b),
                    _fmt(v),
                    _fmt(_delta(b, v)),
                    verdict,
                )
            )

        # COMET (optional)
        b_comet = base_entry.get("comet")
        v_comet = run_entry.get("comet")
        if b_comet or v_comet:
            for sub in ("pipeline", "mtOnly"):
                b = b_comet.get(sub) if b_comet else None
                v = v_comet.get(sub) if v_comet else None
                comet_fail = _comet_gate(b, v, thresholds)
                if comet_fail and gated:
                    verdict = "❌"
                    gated_fail = True
                else:
                    verdict = "✅"
                lines.append(
                    _row(
                        f"  COMET {sub}",
                        _fmt(b),
                        _fmt(v),
                        _fmt(_delta(b, v)),
                        verdict,
                    )
                )

    table = "\n".join(lines)
    return table, 0 if not gated_fail else 1
