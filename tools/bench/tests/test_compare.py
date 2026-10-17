"""Tests for tcbench.compare."""

import pytest

from tcbench import compare


def _make_run_meta(**kwargs):
    defaults = {
        "set": "full",
        "manifestSha256": "abc123",
        "macOS": "15.0",
        "machine": "test-machine",
        "commit": "deadbeef",
        "dirty": False,
        "informative": False,
        "override": None,
    }
    defaults.update(kwargs)
    return defaults


def _make_baseline(aggregates, **kwargs):
    defaults = {
        "reason": "initial",
        "date": "2024-01-01T00:00:00",
        "commit": "deadbeef",
        "manifestSha256": "abc123",
        "macOS": "15.0",
        "machine": "test-machine",
        "set": "full",
    }
    defaults.update(kwargs)
    defaults["aggregates"] = aggregates
    return defaults


def _make_metrics(
    latency_total_p50=100.0,
    latency_total_p90=200.0,
    wer=0.05,
    cut_rate=0.01,
    chrf_pipeline=50.0,
    chrf_mt_only=52.0,
    comet_pipeline=None,
    comet_mt_only=None,
):
    entry = {
        "latency": {
            "total": {"p50": latency_total_p50, "p90": latency_total_p90, "mean": 150.0, "count": 10},
        },
        "latencyCold": {
            "total": {"p50": latency_total_p50, "p90": latency_total_p90, "mean": 150.0, "count": 10},
        },
        "wer": wer,
        "cutRate": cut_rate,
        "mergeRate": 0.0,
        "missed": 0,
        "dropped": {},
        "chrf": {"pipeline": chrf_pipeline, "mtOnly": chrf_mt_only},
    }
    if comet_pipeline is not None or comet_mt_only is not None:
        entry["comet"] = {"pipeline": comet_pipeline, "mtOnly": comet_mt_only}
    return {"basic/outgoing es-ES>en": entry}


THRESHOLDS = {
    "latencyP50RegressionPct": 10,
    "latencyP90RegressionPct": 15,
    "werIncreasePts": 2.0,
    "chrfDropPts": 2.0,
    "cutRateMaxPct": 5,
    "cutRateIncreasePts": 2.0,
}


def test_compare_pass_and_fail_verdicts():
    baseline_metrics = _make_metrics(wer=0.05)
    fail_run = _make_metrics(wer=0.071)  # +2.1 pp
    table, code = compare.run(fail_run, _make_baseline(baseline_metrics), THRESHOLDS, _make_run_meta())
    assert "❌" in table
    assert code == 1

    pass_run = _make_metrics(wer=0.069)  # +1.9 pp
    table, code = compare.run(pass_run, _make_baseline(baseline_metrics), THRESHOLDS, _make_run_meta())
    assert "✅" in table
    assert code == 0


def test_latency_not_gated_on_pr():
    baseline_metrics = _make_metrics(latency_total_p50=100.0, latency_total_p90=200.0)
    # Severe regression that would fail on full.
    run = _make_metrics(latency_total_p50=500.0, latency_total_p90=900.0)
    table, code = compare.run(run, _make_baseline(baseline_metrics), THRESHOLDS, _make_run_meta(set="pr"))
    assert "·" in table
    assert code == 0


def test_compare_refuses_manifest_mismatch():
    baseline_metrics = _make_metrics()
    run = _make_metrics()
    with pytest.raises(SystemExit) as exc:
        compare.run(run, _make_baseline(baseline_metrics, manifestSha256="old"), THRESHOLDS, _make_run_meta())
    assert exc.value.code == 3


def test_compare_warns_macos_change(capsys):
    baseline_metrics = _make_metrics()
    run = _make_metrics()
    table, code = compare.run(run, _make_baseline(baseline_metrics, macOS="14.0"), THRESHOLDS, _make_run_meta())
    assert "macOS changed" in capsys.readouterr().err
    assert code == 0


def test_cut_rate_rule():
    baseline_metrics = _make_metrics(cut_rate=0.03)  # 3%
    # Below absolute max and below baseline + 2 pp -> pass.
    run_pass = _make_metrics(cut_rate=0.04)
    table, code = compare.run(run_pass, _make_baseline(baseline_metrics), THRESHOLDS, _make_run_meta())
    assert code == 0

    # Above baseline + 2 pp but below absolute max -> fail.
    run_fail = _make_metrics(cut_rate=0.051)
    table, code = compare.run(run_fail, _make_baseline(baseline_metrics), THRESHOLDS, _make_run_meta())
    assert code == 1
    assert "❌" in table

    # Above absolute max -> fail even with low baseline.
    baseline_low = _make_metrics(cut_rate=0.001)
    run_max = _make_metrics(cut_rate=0.051)
    table, code = compare.run(run_max, _make_baseline(baseline_low), THRESHOLDS, _make_run_meta())
    assert code == 1
