"""Baseline comparison for TranslateCall benchmark runs."""

from __future__ import annotations

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


def _round(value: float | None, digits: int = 6) -> float | None:
    if value is None:
        return None
    return round(value, digits)


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
    fail = change is not None and _round(change) > threshold
    return None, fail


def _wer_gate(baseline: float | None, value: float | None, thresholds: dict[str, Any]) -> bool:
    """WER is stored as a fraction; thresholds are in percentage points."""
    if baseline is None or value is None:
        return False
    return _round((value - baseline) * 100.0) > thresholds["werIncreasePts"]


def _chrf_gate(baseline: float | None, value: float | None, thresholds: dict[str, Any]) -> bool:
    if baseline is None or value is None:
        return False
    return _round(baseline - value) > thresholds["chrfDropPts"]


def _cut_rate_gate(baseline: float | None, value: float | None, thresholds: dict[str, Any]) -> bool:
    """cutRate is stored as a fraction; thresholds are in percentage points."""
    if baseline is None or value is None:
        return False
    max_allowed = max(
        thresholds["cutRateMaxPct"],
        baseline * 100.0 + thresholds["cutRateIncreasePts"],
    )
    return _round(value * 100.0) > max_allowed


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
    set_type = run_meta.get("set", "full")
    informative = bool(run_meta.get("informative"))
    override = bool(run_meta.get("override"))
    gated = not informative and not override

    if not run_metrics:
        return "No aggregates in run", 2

    # Manifest / macOS checks.
    if run_meta.get("manifestSha256") != baseline.get("manifestSha256"):
        msg = "manifest changed — re-baseline with `just bench-baseline`"
        lines.append(msg)
        return "\n".join(lines), 3

    if run_meta.get("macOS") != baseline.get("macOS"):
        msg = f"macOS changed: baseline={baseline.get('macOS')} run={run_meta.get('macOS')}"
        lines.append(msg)

    if informative or override:
        lines.append(
            "=== informative / overridden run: results shown for comparison only, no gating ==="
        )

    lines.append(_row("metric", "baseline", "value", "delta", "verdict"))
    lines.append("-" * 64)

    if set_type == "pr":
        base_aggs = baseline.get("prAggregates")
        if base_aggs is None:
            msg = "baseline has no PR aggregates — re-baseline with `just bench-baseline`"
            lines.append(msg)
            return "\n".join(lines), 3
    else:
        base_aggs = baseline.get("aggregates", {})

    effective_thresholds = {k: v for k, v in thresholds.items() if k != "perSet"}
    effective_thresholds.update(thresholds.get("perSet", {}).get(set_type, {}))

    all_keys = sorted(set(run_metrics) | set(base_aggs))
    for key in all_keys:
        if key not in run_metrics:
            lines.append(f"[{key}] not in this run (not gated)")
            continue
        if key not in base_aggs:
            lines.append(f"[{key}] new line, no baseline")
            continue

        run_entry = run_metrics[key]
        base_entry = base_aggs[key]
        lines.append(f"[{key}]")

        # Latency total p50 / p90
        latency_b = base_entry.get("latency", {})
        latency_v = run_entry.get("latency", {})
        for stage, metric in [("total", "p50"), ("total", "p90")]:
            b = latency_b.get(stage, {}).get(metric)
            v = latency_v.get(stage, {}).get(metric)
            delta, fail = _latency_gate(b, v, effective_thresholds, set_type, metric)
            if delta == "·":
                verdict = "·"
            elif b is None or v is None:
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
        b_wer = base_entry.get("wer")
        v_wer = run_entry.get("wer")
        wer_fail = _wer_gate(b_wer, v_wer, effective_thresholds)
        if b_wer is None or v_wer is None:
            verdict = "·"
        elif wer_fail and gated:
            verdict = "❌"
            gated_fail = True
        else:
            verdict = "✅"
        lines.append(
            _row(
                "  WER",
                f"{_fmt(b_wer * 100.0 if b_wer is not None else None)}%",
                f"{_fmt(v_wer * 100.0 if v_wer is not None else None)}%",
                f"{_fmt(_round((v_wer - b_wer) * 100.0 if b_wer is not None and v_wer is not None else None))} pts",
                verdict,
            )
        )

        # Cut rate
        b_cut = base_entry.get("cutRate")
        v_cut = run_entry.get("cutRate")
        cut_fail = _cut_rate_gate(b_cut, v_cut, effective_thresholds)
        if b_cut is None or v_cut is None:
            verdict = "·"
        elif cut_fail and gated:
            verdict = "❌"
            gated_fail = True
        else:
            verdict = "✅"
        lines.append(
            _row(
                "  cut rate",
                f"{_fmt(b_cut * 100.0 if b_cut is not None else None)}%",
                f"{_fmt(v_cut * 100.0 if v_cut is not None else None)}%",
                f"{_fmt(_round((v_cut - b_cut) * 100.0 if b_cut is not None and v_cut is not None else None))} pts",
                verdict,
            )
        )

        # chrF++
        b_chrf = base_entry.get("chrf", {})
        v_chrf = run_entry.get("chrf", {})
        for sub in ("pipeline", "mtOnly"):
            b = b_chrf.get(sub)
            v = v_chrf.get(sub)
            chrf_fail = _chrf_gate(b, v, effective_thresholds)
            if b is None or v is None:
                verdict = "·"
            elif chrf_fail and gated:
                verdict = "❌"
                gated_fail = True
            else:
                verdict = "✅"
            lines.append(
                _row(
                    f"  chrF++ {sub}",
                    _fmt(b),
                    _fmt(v),
                    _fmt(_round(_delta(b, v))),
                    verdict,
                )
            )

        # COMET (optional, never gated)
        b_comet = base_entry.get("comet")
        v_comet = run_entry.get("comet")
        if b_comet or v_comet:
            for sub in ("pipeline", "mtOnly"):
                b = b_comet.get(sub) if b_comet else None
                v = v_comet.get(sub) if v_comet else None
                lines.append(
                    _row(
                        f"  COMET {sub}",
                        _fmt(b),
                        _fmt(v),
                        _fmt(_round(_delta(b, v))),
                        "·",
                    )
                )

    table = "\n".join(lines)
    return table, 0 if not gated_fail else 1
