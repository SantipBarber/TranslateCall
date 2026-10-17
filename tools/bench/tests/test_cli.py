import subprocess

import pytest

from tcbench.cli import _repo_is_dirty, main


@pytest.mark.parametrize("cmd", ["ingest", "analyze", "report"])
def test_stub_exits_2(cmd, capsys):
    with pytest.raises(SystemExit) as e:
        main([cmd])
    assert e.value.code == 2
    assert "not implemented" in capsys.readouterr().err


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
