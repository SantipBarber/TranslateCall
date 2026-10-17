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


def _speech_like(seconds=3.0, dbfs=-49.0):
    rng = np.random.default_rng(3)
    x = rng.normal(0, 1, int(seconds * 16000))
    x *= 10 ** (dbfs / 20) / np.sqrt((x**2).mean())
    return x.astype(np.float32)


def test_level_gain_brings_active_rms_to_minus_26_dbfs():
    x = _speech_like()
    span = (500.0, 2500.0)
    gain = audio.level_gain_db(x, span)
    q = audio.from_int16(audio.apply_gain_q16(x, gain))
    assert abs(audio.active_rms_dbfs(q, span) - (-26.0)) < 0.5
    assert gain > 0


def test_peak_limit_reduces_the_gain_and_holds_at_minus_1_dbfs():
    x = _speech_like(dbfs=-40.0)
    x[8000] = 0.5  # a loud peak: reaching -26 dBFS RMS would clip it
    gain = audio.level_gain_db(x, (500.0, 2500.0))
    q = audio.from_int16(audio.apply_gain_q16(x, gain))
    assert 20 * np.log10(np.abs(q).max()) <= -1.0 + 0.01
    assert audio.active_rms_dbfs(q, (500.0, 2500.0)) < -26.0


def test_apply_gain_quantises_to_int16():
    q = audio.apply_gain_q16(np.array([0.5, -2.0], np.float32), 0.0)
    assert q.dtype == np.int16 and list(q) == [16384, -32768]
