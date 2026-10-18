import numpy as np


def summary(values: list[float]) -> dict:
    if not values:
        return {"p50": None, "p90": None, "mean": None, "count": 0}
    arr = np.asarray(values, dtype=float)
    return {
        "p50": float(np.percentile(arr, 50, method="linear")),
        "p90": float(np.percentile(arr, 90, method="linear")),
        "mean": float(arr.mean()),
        "count": len(values),
    }
