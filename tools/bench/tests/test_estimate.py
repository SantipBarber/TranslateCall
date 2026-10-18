import wave

import pytest

from tcbench import estimate


def _wav(path, seconds):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\0\0" * int(16000 * seconds))


def _clip(id_, variant, tiers, audio):
    return {"id": id_, "variant": variant, "tiers": tiers, "audio": audio, "speechEndMs": 1000}


def _manifest():
    return {
        "clips": [_clip("a", "en", ["pr", "full"], "a.wav"), _clip("b", "en", ["full"], "b.wav"),
                  _clip("c", "es-419", ["pr"], "c.wav")],
        "mtOnly": [{"id": "m1", "srcLang": "en", "tgtLang": "es", "tiers": ["pr"]},
                   {"id": "m2", "srcLang": "es", "tgtLang": "en", "tiers": ["pr"]}],
    }


def test_estimate_sums_clip_seconds_and_mt(tmp_path):
    _wav(tmp_path / "a.wav", 10)
    _wav(tmp_path / "c.wav", 5)
    seconds, clips, mt = estimate.estimate(_manifest(), tmp_path, "pr", "basic", ["outgoing-en-es", "outgoing-es-419-en"])
    assert (clips, mt) == (2, 2)
    assert seconds == pytest.approx(15 * 2.0 + 2 * 15 + 2 * 0.3 + 60)


def test_best_profile_skips_incoming_and_all_doubles_outgoing(tmp_path):
    _wav(tmp_path / "a.wav", 10)
    # incoming + best runs nothing; with another line selected it adds nothing either
    both = estimate.estimate(_manifest(), tmp_path, "pr", "best", ["incoming-en-es", "outgoing-en-es"])
    assert both[1] == 1
    assert estimate.estimate(_manifest(), tmp_path, "pr", "all", ["outgoing-en-es"])[1] == 2


def test_unknown_line_and_missing_audio(tmp_path):
    with pytest.raises(ValueError):
        estimate.estimate(_manifest(), tmp_path, "pr", "basic", ["nope"])
    seconds, _, _ = estimate.estimate(_manifest(), tmp_path, "pr", "basic", ["outgoing-en-es"])
    assert seconds == pytest.approx((1.0 + 1.0) * 2.0 + 0.3 + 15 + 60)


def test_no_clips_for_the_selection_is_an_error(tmp_path):
    with pytest.raises(ValueError, match="no clips"):
        estimate.estimate(_manifest(), tmp_path, "pr", "basic", ["outgoing-es-ES-en"])
    with pytest.raises(ValueError, match="no clips"):
        estimate.estimate(_manifest(), tmp_path, "pr", "best", ["incoming-en-es"])


def test_main_warns_over_ten_minutes_for_pr(tmp_path, capsys):
    import json

    m = _manifest()
    m["clips"] = [_clip(f"x{i}", "en", ["pr"], "x.wav") for i in range(200)]
    (tmp_path / "m.json").write_text(json.dumps(m))
    assert estimate.main(["pr", "basic", "outgoing-en-es", "--manifest", str(tmp_path / "m.json"),
                          "--cache", str(tmp_path)]) == 0
    assert "WARNING" in capsys.readouterr().err
    assert estimate.main(["pr", "basic", "outgoing-es-ES-en", "--manifest", str(tmp_path / "m.json"),
                          "--cache", str(tmp_path)]) == 2
