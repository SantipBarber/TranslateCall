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


def write_wav16(path, samples: np.ndarray) -> None:
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
