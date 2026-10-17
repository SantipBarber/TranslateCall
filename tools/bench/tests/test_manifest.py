import json

import numpy as np
import pytest

from tcbench import audio, manifest
from tcbench.sources import Candidate

FIELDS = {
    "id", "source", "lang", "variant", "speaker", "nativeSpeaker", "transcript", "translations",
    "speechStartMs", "speechEndMs", "tags", "tiers", "sha256", "licence", "audio",
}
SAMPLE = json.load(open(__file__.replace("test_manifest.py", "fixtures/manifest-v1-sample.json"), encoding="utf-8"))


def wav_bytes(seed: int, seconds: float = 3.0) -> bytes:
    rng = np.random.default_rng(seed)
    import io

    import soundfile as sf

    buf = io.BytesIO()
    sf.write(buf, (rng.normal(0, 0.1, int(16000 * seconds))).astype(np.float32), 16000, format="WAV", subtype="FLOAT")
    return buf.getvalue()


class StubAudio:
    revision = "rev0"

    def __init__(self, dataset, variants, licence="CC0-1.0", n=30, shared_seed=None):
        self.dataset, self.licence, self._variants, self.n, self.shared = dataset, licence, variants, n, shared_seed
        self.calls = 0

    def variants(self):
        return self._variants

    def candidates(self, variant):
        lang = variant.split("-")[0]
        return [
            Candidate(f"{variant}/{i}", lang, variant, f"sentence {variant} {i}", 2.0 + (i % 8), f"spk{i % 3}", True, {"en": f"t{i}"}, [self.dataset])
            for i in range(self.n)
        ]

    def raw_audio(self, ids):
        self.calls += 1
        out = {}
        for oid in ids:
            i = int(oid.rsplit("/", 1)[1])
            out[oid] = wav_bytes(self.shared if self.shared is not None else i * 7 + len(oid) * 1000 + hash(oid.split("/")[0]) % 997, 3.0 + i % 3)
        return out


class StubText:
    dataset, revision, licence = "ntrex128", "rev0", "CC-BY-SA-4.0"

    def pairs(self, s, t):
        return [(f"{s} sentence {i}", f"{t} sentence {i}") for i in range(300)]


def span(samples, sr=16000, why=None):
    return 300.0, len(samples) * 1000.0 / sr - 400


@pytest.fixture(autouse=True)
def stub_span(monkeypatch):
    monkeypatch.setattr(manifest, "speech_span", span)


def cfg(audio_sources=None, **kw):
    a = audio_sources or [StubAudio("vox", ["es-ES"]), StubAudio("fl", ["es-419", "en"])]
    return manifest.SourcesConfig(audio=a, text=[StubText()], full_n=12, pr_n=3, pr_max_s=6.0, mt_full=20, mt_pr=10, log=lambda *_: None, **kw)


def test_build_twice_is_byte_identical(tmp_path):
    manifest.dump(manifest.build(cfg()), tmp_path / "a.json")
    manifest.dump(manifest.build(cfg()), tmp_path / "b.json")
    assert (tmp_path / "a.json").read_bytes() == (tmp_path / "b.json").read_bytes()
    assert (tmp_path / "a.json").read_bytes().endswith(b"}\n")


def test_every_entry_has_all_fields_matching_the_schema_sample():
    m = manifest.build(cfg())
    assert set(m) == set(SAMPLE) == {"schema", "clips", "mtOnly"}
    assert m["clips"] and m["mtOnly"]
    sample_keys = set(SAMPLE["clips"][0])
    assert sample_keys == FIELDS
    for c in m["clips"]:
        assert set(c) == FIELDS
        assert c["audio"] == f"{c['source']['dataset']}/{c['variant']}/{c['id']}.wav"
        assert set(c["source"]) == {"dataset", "revision", "originalId"}
        assert c["speechEndMs"] > c["speechStartMs"] >= 0
    for e in m["mtOnly"]:
        assert set(e) == set(SAMPLE["mtOnly"][0])


def test_tiers_and_counts():
    m = manifest.build(cfg())
    for variant in ("es-ES", "es-419", "en"):
        clips = [c for c in m["clips"] if c["variant"] == variant]
        assert len(clips) == 12
        pr = [c for c in clips if "pr" in c["tiers"]]
        assert len(pr) == 3 and all(c["tiers"] == ["pr", "full"] for c in pr)
    mt = [e for e in m["mtOnly"] if (e["srcLang"], e["tgtLang"]) == ("en", "es")]
    assert len(mt) == 20 and sum("pr" in e["tiers"] for e in mt) == 10


def test_pr_clips_are_short():
    m = manifest.build(cfg())
    # StubAudio durations are 2 + i % 8 s; candidates > 6 s must never be PR.
    longest = {c["id"]: int(c["source"]["originalId"].rsplit("/", 1)[1]) % 8 + 2 for c in m["clips"]}
    assert all(longest[c["id"]] <= 6 for c in m["clips"] if "pr" in c["tiers"])


def test_es_es_and_es_419_never_share_a_clip():
    # Both Spanish sources serve identical audio for every clip: the second variant must skip them all.
    a = StubAudio("vox", ["es-ES"], shared_seed=5)
    b = StubAudio("fl", ["es-419"], shared_seed=5)
    m = manifest.build(cfg([a, b]))
    shas = [c["sha256"] for c in m["clips"] if c["lang"] == "es"]
    assert len(shas) == len(set(shas))
    keys = [(c["source"]["dataset"], c["source"]["originalId"]) for c in m["clips"]]
    assert len(keys) == len(set(keys))


def test_non_commercial_licence_is_refused_naming_the_source():
    with pytest.raises(ValueError, match="badsrc"):
        manifest.build(cfg([StubAudio("badsrc", ["es-ES"], licence="CC-BY-NC-4.0")]))


def test_clips_without_reliable_span_are_dropped(monkeypatch):
    monkeypatch.setattr(manifest, "speech_span", lambda s, sr=16000, why=None: (why.update(reason="low-snr"), None)[1])
    c = cfg()
    m = manifest.build(c)
    assert m["clips"] == []
    assert c.stats["vox/es-ES"]["dropped"]["low-snr"] > 0


def test_sha256_is_of_the_normalised_wav(tmp_path):
    m = manifest.build(cfg([StubAudio("vox", ["es-ES"])]))
    c = m["clips"][0]
    raw = StubAudio("vox", ["es-ES"]).raw_audio([c["source"]["originalId"]])[c["source"]["originalId"]]
    audio.write_wav16(tmp_path / "x.wav", audio.normalize(raw))
    assert audio.sha256(tmp_path / "x.wav") == c["sha256"]


def test_clips_too_close_to_the_file_edges_are_dropped(monkeypatch):
    monkeypatch.setattr(manifest, "speech_span", lambda s, sr=16000, why=None: (150.0, 1000.0))
    c = cfg()
    assert manifest.build(c)["clips"] == []
    assert c.stats["vox/es-ES"]["dropped"]["lead<200ms"] > 0
    monkeypatch.setattr(manifest, "speech_span", lambda s, sr=16000, why=None: (300.0, len(s) * 1000.0 / sr - 100))
    c = cfg()
    assert manifest.build(c)["clips"] == []
    assert c.stats["vox/es-ES"]["dropped"]["tail<300ms"] > 0
