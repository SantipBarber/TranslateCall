"""Ground-truth speech span (REQ-BH-03): Silero VAD refined and cross-checked by an energy method.

Never derived from the file length. A clip where the two methods disagree by more than
MAX_DISAGREE_MS on either edge has no trustworthy ground truth and is dropped (returns None).
"""

from __future__ import annotations

import numpy as np

THRESHOLD = 0.35
WINDOW = 512
HOP_MS = 10
ENERGY_RANGE_DB = 25.0
MAX_DISAGREE_MS = 150.0
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


def _energy_refine(samples: np.ndarray, span: tuple[float, float], sr: int = 16000) -> tuple[float, float] | None:
    """Move each Silero edge inward, in 10 ms hops, to the first/last frame within 25 dB of the clip's peak RMS.

    Trimming only inside Silero's span keeps noisy recordings (room noise within 25 dB of the peak)
    from dragging the edges outward; it removes Silero's hangover where the signal really is quiet.
    """
    hop = sr * HOP_MS // 1000
    n = len(samples) // hop
    if n == 0:
        return None
    rms = np.sqrt((samples[: n * hop].astype(np.float64).reshape(n, hop) ** 2).mean(axis=1))
    peak = rms.max()
    if peak < FLOOR_RMS:
        return None
    first = int(span[0] // HOP_MS)
    last = min(int(np.ceil(span[1] / HOP_MS)), n)  # exclusive
    active = np.nonzero(rms[first:last] >= peak * 10 ** (-ENERGY_RANGE_DB / 20))[0]
    if len(active) == 0:
        return None
    return float((first + active[0]) * HOP_MS), float((first + active[-1] + 1) * HOP_MS)


def speech_span(samples: np.ndarray, sr: int = 16000) -> tuple[float, float] | None:
    """(start_ms, end_ms), energy-refined, or None when silent or the methods disagree."""
    silero = _silero_span(samples, sr)
    if silero is None:
        return None
    refined = _energy_refine(samples, silero, sr)
    if refined is None:
        return None
    if abs(silero[0] - refined[0]) > MAX_DISAGREE_MS or abs(silero[1] - refined[1]) > MAX_DISAGREE_MS:
        return None
    return refined
