import pytest

from tcbench.cli import _repo_is_dirty, main


@pytest.mark.parametrize("cmd", ["fetch", "manifest", "ingest", "analyze", "report"])
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


def test_repo_is_dirty_smoke():
    # The harness worktree itself has uncommitted changes during this test.
    assert _repo_is_dirty() is True
