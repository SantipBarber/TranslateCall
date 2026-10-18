"""Ground-truth speech span (REQ-BH-03): Silero VAD located, then refined by a noise-floor-relative energy method.

Never derived from the file length. Returns None (with a reason in `why["reason"]`) when the clip is
silent, too noisy (SNR < MIN_SNR_DB), has no energy near a Silero edge, or the refined end is more than
MAX_DISAGREE_MS from Silero's.
"""

from __future__ import annotations

import numpy as np

THRESHOLD = 0.35
WINDOW = 512
HOP_MS = 10
FLOOR_PERCENTILE = 20  # noise floor: 20th percentile of 10 ms frame dB (ruling: 10-20)
FLOOR_MARGIN_DB = 10.0  # threshold = floor + 10 dB ...
MAX_BELOW_PEAK_DB = 40.0  # ... but never below peak - 40 dB
MIN_SNR_DB = 20.0  # peak - floor
SEARCH_MS = 300  # edges are searched within +-300 ms of the Silero edge
MIN_RUN_FRAMES = 3  # an edge needs 3 consecutive frames (30 ms) above threshold
MAX_DISAGREE_MS = 200.0  # end-edge sanity check vs Silero (its 32 ms windows + hangover give a positive end offset)
FLOOR_RMS = 1e-4  # about -80 dBFS: below this the clip is treated as silence

_MODEL = None


def _silero_span(samples: np.ndarray, sr: int = 16000) -> tuple[float, float] | None:
    """(start_ms, end_ms) of the first to the last 512-sample window above THRESHOLD."""
    global _MODEL
    try:
        import torch
        from silero_vad import load_silero_vad
    except ImportError as e:  # pragma: no cover - exercised by the CLI check
        raise RuntimeError(
            "silero-vad is not installed. Run with the extra: uv run --locked --extra vad --project tools/bench tcbench manifest"
        ) from e
    if _MODEL is None:
        _MODEL = load_silero_vad()
    _MODEL.reset_states()
    x = torch.from_numpy(np.ascontiguousarray(samples, dtype=np.float32))
    first = last = None
    with torch.no_grad():
        for i in range(0, len(x) - WINDOW + 1, WINDOW):
            if float(_MODEL(x[i : i + WINDOW], sr)) >= THRESHOLD:
                if first is None:
                    first = i
                last = i + WINDOW
    _MODEL.reset_states()
    if first is None:
        return None
    return first * 1000.0 / sr, last * 1000.0 / sr


def _frame_db(samples: np.ndarray, sr: int) -> np.ndarray:
    hop = sr * HOP_MS // 1000
    n = len(samples) // hop
    if n == 0:
        return np.zeros(0)
    rms = np.sqrt((samples[: n * hop].astype(np.float64).reshape(n, hop) ** 2).mean(axis=1))
    return 20 * np.log10(np.maximum(rms, 1e-6))


def _runs(above: np.ndarray, lo: int, hi: int) -> list[tuple[int, int]]:
    """Runs (first, last inclusive) of >= MIN_RUN_FRAMES consecutive True frames inside [lo, hi)."""
    out, i = [], lo
    while i < hi:
        if above[i]:
            j = i
            while j + 1 < hi and above[j + 1]:
                j += 1
            if j - i + 1 >= MIN_RUN_FRAMES:
                out.append((i, j))
            i = j + 1
        else:
            i += 1
    return out


def _energy_refine(samples: np.ndarray, span: tuple[float, float], sr: int = 16000, why: dict | None = None):
    """Refine both Silero edges locally with a noise-floor-relative threshold; None with why["reason"]."""
    why = why if why is not None else {}
    db = _frame_db(samples, sr)
    n = len(db)
    if n == 0 or db.max() < 20 * np.log10(FLOOR_RMS):
        why["reason"] = "silent"
        return None
    fs, fe = int(span[0] // HOP_MS), min(int(np.ceil(span[1] / HOP_MS)), n)
    outside = np.concatenate([db[:fs], db[fe:]])
    floor = float(np.percentile(outside if len(outside) >= 20 else db, FLOOR_PERCENTILE))
    peak = float(db.max())
    if peak - floor < MIN_SNR_DB:
        why["reason"] = "low-snr"
        return None
    thr = max(floor + FLOOR_MARGIN_DB, peak - MAX_BELOW_PEAK_DB)
    above = db >= thr
    w = SEARCH_MS // HOP_MS
    start_runs = _runs(above, max(fs - w, 0), min(fs + w, n))
    end_runs = _runs(above, max(fe - w, 0), min(fe + w, n))
    if not start_runs or not end_runs:
        why["reason"] = "no-energy-at-edge"
        return None
    start = float(start_runs[0][0] * HOP_MS)
    end = float((end_runs[-1][1] + 1) * HOP_MS)
    why["silero"] = span
    why["refined"] = (start, end)
    if end <= start:
        why["reason"] = "no-energy-at-edge"
        return None
    return start, end


def speech_span(samples: np.ndarray, sr: int = 16000, why: dict | None = None) -> tuple[float, float] | None:
    """(start_ms, end_ms) of the speech, or None. `why` (optional dict) receives reason / silero / refined."""
    why = why if why is not None else {}
    silero = _silero_span(samples, sr)
    if silero is None:
        why["reason"] = "silero-no-speech"
        return None
    refined = _energy_refine(samples, silero, sr, why)
    if refined is None:
        return None
    # Only the end edge is cross-checked (latency uses speechEnd); the start is bounded by the +-300 ms search window.
    if abs(silero[1] - refined[1]) > MAX_DISAGREE_MS:
        why["reason"] = "silero-disagree"
        return None
    return refined
