import numpy as np
import pytest

from tcbench import groundtruth

SR = 16000


def clip(lead=0.5, tone=1.0, tail=0.7):
    t = np.arange(int(tone * SR)) / SR
    wave = (10 ** (-12 / 20) * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    return np.concatenate([np.zeros(int(lead * SR), np.float32), wave, np.zeros(int(tail * SR), np.float32)])


def test_span_of_tone_between_silences(monkeypatch):
    monkeypatch.setattr(groundtruth, "_silero_span", lambda s, sr=16000: (500.0, 1500.0))
    start, end = groundtruth.speech_span(clip())
    assert start == pytest.approx(500, abs=20)
    assert end == pytest.approx(1500, abs=20)


def test_all_silence_is_none(monkeypatch):
    monkeypatch.setattr(groundtruth, "_silero_span", lambda s, sr=16000: (500.0, 1500.0))
    assert groundtruth.speech_span(np.zeros(2 * SR, np.float32)) is None


def test_methods_disagreeing_by_more_than_150ms_is_none(monkeypatch):
    monkeypatch.setattr(groundtruth, "_silero_span", lambda s, sr=16000: (500.0, 1700.0))
    assert groundtruth.speech_span(clip()) is None
    monkeypatch.setattr(groundtruth, "_silero_span", lambda s, sr=16000: (300.0, 1500.0))
    assert groundtruth.speech_span(clip()) is None


def test_silero_finding_nothing_is_none(monkeypatch):
    monkeypatch.setattr(groundtruth, "_silero_span", lambda s, sr=16000: None)
    assert groundtruth.speech_span(clip()) is None


def test_energy_trims_silero_hangover(monkeypatch):
    # Silero's span runs 100 ms into a -45 dB tail; that is more than 25 dB under the peak, so the end is trimmed back.
    weak = 10 ** (-45 / 20) * np.sin(2 * np.pi * 220 * np.arange(SR // 2) / SR).astype(np.float32)
    s = np.concatenate([clip(tail=0.0), weak, np.zeros(SR // 2, np.float32)])
    monkeypatch.setattr(groundtruth, "_silero_span", lambda s, sr=16000: (500.0, 1600.0))
    _, end = groundtruth.speech_span(s)
    assert end == pytest.approx(1500, abs=20)


@pytest.mark.network
def test_groundtruth_silero_real():
    """Real Silero on a real cached FLEURS clip (run `tcbench fetch --set pr` first; skipped without it)."""
    from tcbench import audio
    from tcbench.sources import default_cache_dir

    pytest.importorskip("silero_vad")
    wavs = sorted((default_cache_dir() / "fleurs" / "en").glob("*.wav"))
    if not wavs:
        pytest.skip("no cached FLEURS clip; run `tcbench fetch --set pr`")
    samples = audio.normalize(str(wavs[0]))
    span = groundtruth.speech_span(samples)
    assert span is not None
    assert 0 <= span[0] < span[1] <= len(samples) * 1000 / SR
    assert span[1] - span[0] > 1000  # a read sentence is longer than a second
