"""Audio normalisation: every cached clip is 16 kHz mono 16-bit PCM WAV (REQ-BH-02)."""

from __future__ import annotations

import hashlib
import io
from pathlib import Path

import numpy as np
import soundfile as sf
import soxr

TARGET_SR = 16000


def normalize(path_or_bytes) -> np.ndarray:
    """Decode any libsndfile format; return 16 kHz mono float32 in [-1, 1]."""
    src = io.BytesIO(path_or_bytes) if isinstance(path_or_bytes, (bytes, bytearray)) else path_or_bytes
    data, sr = sf.read(src, dtype="float32", always_2d=True)
    mono = data.mean(axis=1) if data.shape[1] > 1 else data[:, 0]
    if sr != TARGET_SR:
        mono = soxr.resample(mono, sr, TARGET_SR, quality="HQ")
    return np.ascontiguousarray(np.clip(mono, -1.0, 1.0), dtype=np.float32)


TARGET_ACTIVE_RMS_DBFS = -26.0
PEAK_LIMIT_DBFS = -1.0


def active_rms_dbfs(samples: np.ndarray, span_ms: tuple[float, float], sr: int = TARGET_SR) -> float:
    seg = samples[int(span_ms[0] * sr / 1000) : int(span_ms[1] * sr / 1000)].astype(np.float64)
    return 20 * np.log10(max(float(np.sqrt((seg**2).mean())), 1e-9))


def level_gain_db(samples: np.ndarray, span_ms: tuple[float, float]) -> float:
    """One gain (dB, rounded to 3 decimals) taking the active-speech RMS to -26 dBFS, peak limited to -1 dBFS."""
    gain = TARGET_ACTIVE_RMS_DBFS - active_rms_dbfs(samples, span_ms)
    peak = float(np.abs(samples).max())
    if peak > 0:
        gain = min(gain, PEAK_LIMIT_DBFS - 20 * np.log10(peak))
    return round(float(gain), 3)


def apply_gain_q16(samples: np.ndarray, gain_db: float) -> np.ndarray:
    """Apply the gain and quantise to int16 exactly as written to the cache."""
    x = samples.astype(np.float64) * 10 ** (gain_db / 20)
    return np.clip(np.rint(x * 32768), -32768, 32767).astype(np.int16)


def from_int16(q: np.ndarray) -> np.ndarray:
    return (q.astype(np.float32) / 32768.0).astype(np.float32)


def write_wav16(path, samples: np.ndarray) -> None:
    """Write 16-bit PCM; int16 input is written verbatim, float input is converted by libsndfile."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), samples, TARGET_SR, subtype="PCM_16", format="WAV")


def read_wav16(path) -> np.ndarray:
    """Samples as the 16-bit file stores them (what the sha256 covers)."""
    return normalize(str(path))


def sha256(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()
