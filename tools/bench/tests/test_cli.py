import json
import subprocess
import sys
from pathlib import Path

import pytest

from tcbench import runs
from tcbench.cli import REPO, _repo_is_dirty, main


def _write_run(path, set_type="full", aggregates=None, pr_aggregates=None):
    payload = {
        "meta": {
            "set": set_type,
            "manifestSha256": "abc123",
            "macOS": "15.0",
            "machine": "test",
            "commit": "deadbeef",
            "dirty": False,
            "informative": False,
            "override": None,
        },
        "aggregates": aggregates or {},
    }
    if pr_aggregates is not None:
        payload["prAggregates"] = pr_aggregates
    path.mkdir(parents=True, exist_ok=True)
    (path / "metrics.json").write_text(json.dumps(payload))


def test_ingest_cli_runs(monkeypatch, tmp_path, capsys):
    monkeypatch.setitem(sys.modules, "silero_vad", type(sys)("silero_vad"))
    called = {}

    def fake_run(folder, sheet, variant, native, manifest_path, cache_dir=None):
        called.update(
            folder=folder,
            sheet=sheet,
            variant=variant,
            native=native,
            manifest=manifest_path,
            cache_dir=cache_dir,
        )
        return []

    monkeypatch.setattr("tcbench.ingest.run", fake_run)
    code = main(["ingest", str(tmp_path), "--variant", "en", "--native", "true"])
    assert code == 0
    assert called["variant"] == "en"
    assert called["native"] is True


def test_all_commands_in_help(capsys):
    with pytest.raises(SystemExit) as e:
        main(["--help"])
    assert e.value.code == 0
    err = capsys.readouterr().out
    for cmd in ("fetch", "manifest", "ingest", "analyze", "report", "compare", "baseline"):
        assert cmd in err


def test_compare_cli_missing_run_dir(capsys):
    code = main(["compare", "/nonexistent/run"])
    assert code == 2


def test_baseline_cli_missing_run_dir(capsys, monkeypatch):
    monkeypatch.setattr("tcbench.cli._repo_is_dirty", lambda: False)
    code = main(["baseline", "/nonexistent/run", "--reason", "test"])
    assert code == 2


def test_baseline_cli_refuses_dirty_tree(capsys, monkeypatch):
    monkeypatch.setattr("tcbench.cli._repo_is_dirty", lambda: True)
    code = main(["baseline", "/nonexistent/run", "--reason", "test"])
    assert code == 1
    assert "uncommitted" in capsys.readouterr().err.lower()


def test_repo_is_dirty_smoke(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / "file.txt").write_text("clean\n")
    subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "add", "file.txt"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-m", "init"], cwd=repo, check=True, capture_output=True)

    assert _repo_is_dirty(repo) is False

    (repo / "file.txt").write_text("dirty\n")
    assert _repo_is_dirty(repo) is True


def test_repo_is_dirty_fails_closed(capsys, monkeypatch):
    def _boom(*args, **kwargs):
        raise subprocess.CalledProcessError(1, ["git", "status"])

    monkeypatch.setattr(subprocess, "run", _boom)
    assert _repo_is_dirty("/any/path") is True
    assert "cannot check git status" in capsys.readouterr().err


def _entry(wer=0.05, cut_rate=0.01):
    return {
        "latency": {"total": {"p50": 100.0, "p90": 200.0, "mean": 150.0, "count": 10}},
        "latencyCold": {"total": {"p50": 100.0, "p90": 200.0, "mean": 150.0, "count": 10}},
        "wer": wer,
        "cutRate": cut_rate,
        "mergeRate": 0.0,
        "missed": 0,
        "dropped": {},
        "chrf": {"pipeline": 50.0, "mtOnly": 52.0},
    }


def test_baseline_from_run_pr_uses_its_aggregates_as_pr_aggregates(tmp_path, monkeypatch):
    base = tmp_path / "base"
    run = tmp_path / "run"
    aggs = {"basic/outgoing es-ES>en": _entry()}
    _write_run(base, set_type="pr", aggregates=aggs)
    _write_run(run, set_type="pr", aggregates=aggs)
    monkeypatch.setattr("tcbench.cli.REPO", tmp_path)
    thresholds = tmp_path / "thresholds.json"
    thresholds.write_text(json.dumps({
        "latencyP50RegressionPct": 10,
        "latencyP90RegressionPct": 15,
        "werIncreasePts": 5.0,
        "chrfDropPts": 4.0,
        "cutRateMaxPct": 12.5,
        "cutRateIncreasePts": 2.0,
    }))
    code = main([
        "compare", str(run),
        "--baseline-from-run", str(base),
        "--thresholds", str(thresholds),
    ])
    assert code == 0


def test_baseline_from_run_full_loads_pr_aggregates(tmp_path, monkeypatch):
    base = tmp_path / "base"
    run = tmp_path / "run"
    full_aggs = {"basic/outgoing es-ES>en": _entry()}
    pr_aggs = {"basic/outgoing es-ES>en": _entry(wer=0.06)}
    _write_run(base, set_type="full", aggregates=full_aggs, pr_aggregates=pr_aggs)
    _write_run(run, set_type="pr", aggregates=pr_aggs)
    monkeypatch.setattr("tcbench.cli.REPO", tmp_path)
    thresholds = tmp_path / "thresholds.json"
    thresholds.write_text(json.dumps({
        "latencyP50RegressionPct": 10,
        "latencyP90RegressionPct": 15,
        "werIncreasePts": 5.0,
        "chrfDropPts": 4.0,
        "cutRateMaxPct": 12.5,
        "cutRateIncreasePts": 2.0,
    }))
    code = main([
        "compare", str(run),
        "--baseline-from-run", str(base),
        "--thresholds", str(thresholds),
    ])
    assert code == 0


def test_compare_default_paths_are_repo_rooted(tmp_path, monkeypatch):
    # Create a baseline/thresholds under the real repo defaults and run from another cwd.
    real_baseline = REPO / "bench" / "baseline.json"
    real_thresholds = REPO / "bench" / "thresholds.json"
    baseline = json.loads(real_baseline.read_text())
    thresholds = json.loads(real_thresholds.read_text())
    run = tmp_path / "run"
    _write_run(run, set_type="pr", aggregates=baseline.get("prAggregates") or baseline["aggregates"])
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(runs, "load_run", lambda d: ({
        "set": "pr",
        "manifestSha256": baseline["manifestSha256"],
        "macOS": baseline.get("macOS", "15.0"),
        "machine": "test",
        "commit": "deadbeef",
        "dirty": False,
        "informative": False,
        "override": None,
    }, baseline.get("prAggregates") or baseline["aggregates"]))
    code = main(["compare", str(run)])
    assert code in (0, 1)
