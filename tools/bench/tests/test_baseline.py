"""Tests for tcbench.baseline."""

import json
from pathlib import Path

import pytest

from tcbench import baseline


def _make_run_dir(tmp_path: Path, dirty=False, informative=False, override=None, set_type="full", pr_aggregates=None):
    run_dir = tmp_path / "run"
    run_dir.mkdir()
    meta = {
        "set": set_type,
        "manifestSha256": "abc123",
        "macOS": "15.0",
        "machine": "test-machine",
        "commit": "deadbeef",
        "dirty": dirty,
        "informative": informative,
        "override": override,
    }
    aggregates = {"basic/outgoing es-ES>en": {"wer": 0.05}}
    payload = {"meta": meta, "aggregates": aggregates}
    if pr_aggregates is not None:
        payload["prAggregates"] = pr_aggregates
    (run_dir / "metrics.json").write_text(json.dumps(payload))
    return run_dir


def test_baseline_refuses_repo_dirty(tmp_path):
    run_dir = _make_run_dir(tmp_path, pr_aggregates={"basic/outgoing es-ES>en": {"wer": 0.05}})
    with pytest.raises(baseline.BaselineRefusal) as exc:
        baseline.run(run_dir, "reason", repo_dirty=True)
    assert "uncommitted" in str(exc.value).lower()


def test_baseline_refuses_run_dirty(tmp_path):
    run_dir = _make_run_dir(tmp_path, dirty=True, pr_aggregates={"basic/outgoing es-ES>en": {"wer": 0.05}})
    with pytest.raises(baseline.BaselineRefusal) as exc:
        baseline.run(run_dir, "reason", repo_dirty=False)
    assert "dirty" in str(exc.value).lower()


def test_baseline_refuses_non_full_run(tmp_path):
    run_dir = _make_run_dir(tmp_path, set_type="pr")
    with pytest.raises(baseline.BaselineRefusal) as exc:
        baseline.run(run_dir, "reason", repo_dirty=False)
    assert "baseline needs a full run" in str(exc.value).lower()


def test_baseline_refuses_informative(tmp_path):
    run_dir = _make_run_dir(tmp_path, informative=True, pr_aggregates={"basic/outgoing es-ES>en": {"wer": 0.05}})
    with pytest.raises(baseline.BaselineRefusal) as exc:
        baseline.run(run_dir, "reason", repo_dirty=False)
    assert "informative" in str(exc.value).lower()


def test_baseline_refuses_override(tmp_path):
    run_dir = _make_run_dir(tmp_path, override="custom", pr_aggregates={"basic/outgoing es-ES>en": {"wer": 0.05}})
    with pytest.raises(baseline.BaselineRefusal) as exc:
        baseline.run(run_dir, "reason", repo_dirty=False)
    assert "override" in str(exc.value).lower()


def test_baseline_refuses_missing_pr_aggregates(tmp_path):
    run_dir = _make_run_dir(tmp_path)
    with pytest.raises(baseline.BaselineRefusal) as exc:
        baseline.run(run_dir, "reason", repo_dirty=False)
    assert "praggregates" in str(exc.value).lower()


def test_baseline_roundtrip(tmp_path, monkeypatch):
    pr_aggregates = {"basic/outgoing es-ES>en": {"wer": 0.04}}
    monkeypatch.setattr(baseline, "_today", lambda: "2024-01-15T00:00:00")
    run_dir = _make_run_dir(tmp_path, pr_aggregates=pr_aggregates)
    out = tmp_path / "baseline.json"
    baseline.run(run_dir, "weekly baseline", repo_dirty=False, output=out)

    data = json.loads(out.read_text())
    assert data["reason"] == "weekly baseline"
    assert data["date"] == "2024-01-15T00:00:00"
    assert data["commit"] == "deadbeef"
    assert data["manifestSha256"] == "abc123"
    assert data["macOS"] == "15.0"
    assert data["machine"] == "test-machine"
    assert data["set"] == "full"
    assert "basic/outgoing es-ES>en" in data["aggregates"]
    assert data["prAggregates"] == pr_aggregates
