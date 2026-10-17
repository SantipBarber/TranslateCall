import io

import numpy as np
import soundfile as sf

from tcbench import audio


def test_normalize_resamples_stereo_to_16k_mono_float32():
    t = np.arange(48000) / 48000
    stereo = np.stack([np.sin(2 * np.pi * 440 * t), np.sin(2 * np.pi * 440 * t)], axis=1).astype(np.float32) * 0.5
    buf = io.BytesIO()
    sf.write(buf, stereo, 48000, format="WAV")
    out = audio.normalize(buf.getvalue())
    assert out.dtype == np.float32 and out.ndim == 1
    assert abs(len(out) - 16000) <= 2
    assert abs(np.abs(out).max() - 0.5) < 0.02


def test_write_wav16_is_16_bit_pcm_16k_mono_and_hash_is_stable(tmp_path):
    x = (np.sin(np.arange(8000) / 10) * 0.3).astype(np.float32)
    audio.write_wav16(tmp_path / "a.wav", x)
    audio.write_wav16(tmp_path / "b.wav", x)
    info = sf.info(tmp_path / "a.wav")
    assert (info.samplerate, info.channels, info.subtype) == (16000, 1, "PCM_16")
    assert audio.sha256(tmp_path / "a.wav") == audio.sha256(tmp_path / "b.wav")
