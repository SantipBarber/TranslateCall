import pytest

from tcbench.cli import main


@pytest.mark.parametrize("cmd", ["fetch", "manifest", "ingest", "analyze", "report"])
def test_stub_exits_2(cmd, capsys):
    with pytest.raises(SystemExit) as e:
        main([cmd])
    assert e.value.code == 2
    assert "not implemented" in capsys.readouterr().err


def test_compare_cli_missing_run_dir(capsys):
    with pytest.raises(SystemExit) as e:
        main(["compare", "/nonexistent/run"])
    assert e.value.code == 2


def test_baseline_cli_missing_run_dir(capsys):
    code = main(["baseline", "/nonexistent/run", "--reason", "test"])
    assert code == 2
