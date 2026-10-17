import pytest

from tcbench.cli import main


@pytest.mark.parametrize("cmd", ["ingest", "analyze", "compare", "report", "baseline"])
def test_stub_exits_2(cmd, capsys):
    with pytest.raises(SystemExit) as e:
        main([cmd])
    assert e.value.code == 2
    assert "not implemented" in capsys.readouterr().err
