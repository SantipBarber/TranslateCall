from tcbench.stats import summary


def test_summary_basic():
    s = summary([1, 2, 3, 4])
    assert s["p50"] == 2.5
    assert abs(s["p90"] - 3.7) < 1e-9
    assert s["mean"] == 2.5
    assert s["count"] == 4


def test_summary_empty():
    s = summary([])
    assert s == {"p50": None, "p90": None, "mean": None, "count": 0}
