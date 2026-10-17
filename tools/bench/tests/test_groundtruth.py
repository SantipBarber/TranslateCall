import numpy as np
import pytest

from tcbench import groundtruth

SR = 16000


RNG = np.random.default_rng(7)


def noise(seconds, dbfs=-70.0):
    return (RNG.normal(0, 1, int(seconds * SR)) * 10 ** (dbfs / 20)).astype(np.float32)


def tone(seconds, dbfs=-12.0):
    t = np.arange(int(seconds * SR)) / SR
    return (10 ** (dbfs / 20) * np.sin(2 * np.pi * 220 * t)).astype(np.float32)


def clip(lead=0.5, tail=0.7, coda=0.0):
    parts = [noise(lead), tone(1.0) + noise(1.0)]
    if coda:
        parts.append(tone(coda, -40.0) + noise(coda))
    parts.append(noise(tail))
    return np.concatenate(parts)


def stub(monkeypatch, span):
    monkeypatch.setattr(groundtruth, "_silero_span", lambda s, sr=16000: span)


def test_span_of_tone_between_noise_floors(monkeypatch):
    stub(monkeypatch, (500.0, 1500.0))
    start, end = groundtruth.speech_span(clip())
    assert start == pytest.approx(500, abs=30)
    assert end == pytest.approx(1500, abs=30)


def test_quiet_coda_after_the_tone_is_kept(monkeypatch):
    # -12 dBFS tone, then a 150 ms -40 dBFS coda over a -70 dBFS floor: the end must land after the coda.
    stub(monkeypatch, (500.0, 1500.0))
    _, end = groundtruth.speech_span(clip(coda=0.15))
    assert end == pytest.approx(1650, abs=30)


def test_silero_hangover_over_pure_noise_is_trimmed(monkeypatch):
    stub(monkeypatch, (500.0, 1650.0))  # Silero runs 150 ms into noise
    _, end = groundtruth.speech_span(clip())
    assert end == pytest.approx(1500, abs=30)


def test_silero_ending_early_extends_the_edge_when_energy_continues(monkeypatch):
    stub(monkeypatch, (500.0, 1400.0))  # Silero stopped 100 ms early
    _, end = groundtruth.speech_span(clip())
    assert end == pytest.approx(1500, abs=30)


def test_single_click_does_not_set_an_edge(monkeypatch):
    s = clip()
    s[int(0.4 * SR) : int(0.4 * SR) + 40] = 0.5  # 2.5 ms click 100 ms before the speech
    stub(monkeypatch, (500.0, 1500.0))
    start, _ = groundtruth.speech_span(s)
    assert start == pytest.approx(500, abs=30)


def test_all_silence_is_none(monkeypatch):
    stub(monkeypatch, (500.0, 1500.0))
    why = {}
    assert groundtruth.speech_span(np.zeros(2 * SR, np.float32), why=why) is None
    assert why["reason"] == "silent"


def test_low_snr_clip_is_dropped(monkeypatch):
    stub(monkeypatch, (500.0, 1500.0))
    s = np.concatenate([noise(0.5, -30), tone(1.0, -12) + noise(1.0, -30), noise(0.7, -30)])
    why = {}
    assert groundtruth.speech_span(s, why=why) is None
    assert why["reason"] == "low-snr"


def test_end_disagreeing_by_more_than_200ms_is_none(monkeypatch):
    why = {}
    stub(monkeypatch, (500.0, 1750.0))
    assert groundtruth.speech_span(clip(), why=why) is None
    assert why["reason"] == "silero-disagree"
    stub(monkeypatch, (250.0, 1500.0))  # start only bounded by the search window, not cross-checked
    assert groundtruth.speech_span(clip())[0] == pytest.approx(500, abs=30)


def test_silero_finding_nothing_is_none(monkeypatch):
    stub(monkeypatch, None)
    assert groundtruth.speech_span(clip()) is None


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
