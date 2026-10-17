import json

import numpy as np
import pytest

from tcbench import audio, fetch


class Provider:
    def __init__(self):
        self.calls = []

    def raw_audio(self, ids):
        self.calls.append(list(ids))
        import io

        import soundfile as sf

        out = {}
        for oid in ids:
            buf = io.BytesIO()
            sf.write(buf, np.random.default_rng(len(oid)).normal(0, 0.1, 8000).astype(np.float32), 16000, format="WAV", subtype="FLOAT")
            out[oid] = buf.getvalue()
        return out


@pytest.fixture
def world(tmp_path):
    p = Provider()
    clips = []
    for i, tiers in enumerate([["pr", "full"], ["full"]]):
        oid = f"c/{i}" + "x" * i
        raw = p.raw_audio([oid])[oid]
        ref = tmp_path / "ref.wav"
        audio.write_wav16(ref, audio.apply_gain_q16(audio.normalize(raw), 3.0))
        cid = f"stub-es-{i:04d}"
        clips.append({"id": cid, "variant": "es-ES", "gainDb": 3.0, "source": {"dataset": "stub", "revision": "r", "originalId": oid}, "tiers": tiers,
                      "sha256": audio.sha256(ref), "audio": f"stub/es/{cid}.wav"})
    p.calls.clear()
    bench = tmp_path / "bench"
    (bench / "manifests").mkdir(parents=True)
    (bench / "manifests" / "m.json").write_text(json.dumps({"schema": 1, "clips": clips, "mtOnly": []}))
    (bench / "licences.json").write_text(json.dumps({"sources": [{"id": "stub", "licence": "CC0-1.0"}]}))
    return bench / "manifests" / "m.json", tmp_path / "cache", p, clips


def test_second_fetch_downloads_nothing(world, capsys):
    m, cache, p, clips = world
    fetch.run(m, cache, "full", providers={"stub": p})
    assert len(p.calls) == 1 and (cache / clips[0]["audio"]).exists()
    fetch.run(m, cache, "full", providers={"stub": p})
    assert len(p.calls) == 1
    assert "up to date" in capsys.readouterr().out


def test_pr_set_only_fetches_pr_clips(world):
    m, cache, p, clips = world
    fetch.run(m, cache, "pr", providers={"stub": p})
    assert (cache / clips[0]["audio"]).exists() and not (cache / clips[1]["audio"]).exists()


def test_limit(world):
    m, cache, p, clips = world
    fetch.run(m, cache, "full", limit=1, providers={"stub": p})
    assert not (cache / clips[1]["audio"]).exists()


def test_corrupted_file_exits_1_naming_the_clip(world, capsys):
    m, cache, p, clips = world
    fetch.run(m, cache, "full", providers={"stub": p})
    (cache / clips[1]["audio"]).write_bytes(b"corrupt")
    with pytest.raises(SystemExit) as e:
        fetch.run(m, cache, "full", providers={"stub": p})
    assert e.value.code == 1
    assert clips[1]["id"] in capsys.readouterr().err


def test_sha_mismatch_after_download_exits_1_and_leaves_no_file(world, capsys):
    m, cache, p, clips = world
    d = json.loads(m.read_text())
    d["clips"][0]["sha256"] = "0" * 64
    m.write_text(json.dumps(d))
    with pytest.raises(SystemExit) as e:
        fetch.run(m, cache, "pr", providers={"stub": p})
    assert e.value.code == 1
    assert clips[0]["id"] in capsys.readouterr().err
    assert not (cache / clips[0]["audio"]).exists()


def test_download_error_names_the_source(world, capsys):
    m, cache, _, _ = world

    class Boom:
        def raw_audio(self, ids):
            raise OSError("network down")

    with pytest.raises(SystemExit) as e:
        fetch.run(m, cache, "pr", providers={"stub": Boom()})
    assert e.value.code == 1
    assert "stub" in capsys.readouterr().err


def test_source_missing_from_allow_list_is_refused(world, capsys):
    m, cache, p, _ = world
    (m.parent.parent / "licences.json").write_text(json.dumps({"sources": []}))
    with pytest.raises(SystemExit):
        fetch.run(m, cache, "pr", providers={"stub": p})
    assert "stub" in capsys.readouterr().err and p.calls == []


def test_fetch_pr_warns_for_run_line_variants_without_pr_clips(world, capsys):
    m, cache, p, _ = world
    fetch.run(m, cache, "pr", providers={"stub": p})
    err = capsys.readouterr().err
    assert "0 PR clips for run-line variant es-419" in err and "variant en" in err
    assert "variant es-ES" not in err


def _own_clip(id_, original_id, cache, sha):
    return {
        "id": id_,
        "variant": "en",
        "gainDb": 0.0,
        "source": {"dataset": "own", "revision": sha, "originalId": original_id},
        "tiers": ["pr", "full"],
        "sha256": sha,
        "audio": f"own/en/{id_}.wav",
    }


def test_own_clip_is_up_to_date_when_cached(world, capsys):
    m, cache, p, _ = world
    own_id = "own-en-en-01"
    own_audio = cache / "own" / "en" / f"{own_id}.wav"
    audio.write_wav16(own_audio, np.zeros(8000, np.float32))
    sha = audio.sha256(own_audio)
    manifest = {"schema": 1, "clips": [_own_clip(own_id, "en-01.wav", cache, sha)], "mtOnly": []}
    m.write_text(json.dumps(manifest))
    fetch.run(m, cache, "full", providers={"stub": p})
    assert p.calls == []
    assert "up to date" in capsys.readouterr().out


def test_own_clip_missing_fails(world, capsys):
    m, cache, p, _ = world
    own_id = "own-en-en-01"
    manifest = json.loads(m.read_text())
    manifest["clips"].append(_own_clip(own_id, "en-01.wav", cache, "c" * 64))
    m.write_text(json.dumps(manifest))
    with pytest.raises(SystemExit) as e:
        fetch.run(m, cache, "full", providers={"stub": p})
    assert e.value.code == 1
    err = capsys.readouterr().err
    assert own_id in err
    assert "re-run tcbench ingest" in err


def test_own_clip_sha_mismatch_fails(world, capsys):
    m, cache, p, _ = world
    own_id = "own-en-en-01"
    own_audio = cache / "own" / "en" / f"{own_id}.wav"
    audio.write_wav16(own_audio, np.zeros(8000, np.float32))
    manifest = json.loads(m.read_text())
    manifest["clips"].append(_own_clip(own_id, "en-01.wav", cache, "0" * 64))
    m.write_text(json.dumps(manifest))
    with pytest.raises(SystemExit) as e:
        fetch.run(m, cache, "full", providers={"stub": p})
    assert e.value.code == 1
    err = capsys.readouterr().err
    assert own_id in err
    assert "re-run tcbench ingest" in err
