import io
import tarfile

import pytest

from tcbench import sources
from tcbench.sources import CV_PREFIX, CommonVoice, cv_speaker

NORTE = "España: Norte peninsular (Asturias, Castilla y León, Cantabria, País Vasco, Navarra, Aragón, La Rioja, Guadalajara, Cuenca)"
CANARIAS = "España: Islas Canarias"
HEADER = "client_id\tpath\tsentence_id\tsentence\tsentence_domain\tup_votes\tdown_votes\tage\tgender\taccents\tvariant\tlocale\tsegment\n"


def row(client, clip, accent, sentence="Hola, ¿qué tal?"):
    return f"{client}\t{clip}.mp3\tsid\t{sentence}\t\t2\t0\t\t\t{accent}\t\tes\t\n"


def add(tar, name, data: bytes):
    info = tarfile.TarInfo(CV_PREFIX + name)
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))


@pytest.fixture
def archive(tmp_path):
    test_rows = [
        row("clientA-secret", "c1", NORTE),
        row("clientA-secret", "c2", CANARIAS),
        row("clientB-secret", "c3", "México"),
        row("clientC-secret", "c4", ""),
        row("clientD-secret", "c5", NORTE + "|Cataluña"),
        row("clientE-secret", "c6", "Nativo, from Spain."),
        row("clientF-secret", "c7", "España: Centro-Sur peninsular (Madrid, Toledo, Castilla-La Mancha)"),
    ]
    other_rows = [row("clientG-secret", "train1", NORTE), row("clientH-secret", "dev1", NORTE)]
    p = tmp_path / "cv.tar"
    with tarfile.open(p, "w") as t:
        add(t, "test.tsv", (HEADER + "".join(test_rows)).encode())
        add(t, "train.tsv", (HEADER + other_rows[0]).encode())
        add(t, "dev.tsv", (HEADER + other_rows[1]).encode())
        add(t, "clip_durations.tsv", b"clip\tduration[ms]\n" + b"".join(f"{c}.mp3\t4000\n".encode() for c in ["c1", "c2", "c3", "c4", "c5", "c6", "c7", "train1", "dev1"]))
        for c in ["c1", "c2", "c3", "c4", "c5", "c6", "c7", "train1", "dev1"]:
            add(t, f"clips/{c}.mp3", f"audio-{c}".encode())
    return p


def source(archive, tmp_path):
    s = CommonVoice(tmp_path, archive=archive)
    s.expected_size = None
    return s


def test_only_exact_spain_accents_from_the_test_split(archive, tmp_path):
    ids = {c.original_id for c in source(archive, tmp_path).candidates("es-ES")}
    assert ids == {"c1.mp3", "c2.mp3", "c7.mp3"}  # not México, empty, multi-value, free text, train or dev


def test_candidates_are_es_es_with_tags_and_no_native_claim(archive, tmp_path):
    c = {c.original_id: c for c in source(archive, tmp_path).candidates("es-ES")}["c2.mp3"]
    assert (c.variant, c.lang, c.native) == ("es-ES", "es", False)
    assert c.tags == ["commonvoice", "accent-es-islas-canarias", "accent-self-reported", "native-unknown"]
    assert c.translations == {} and c.transcript == "Hola, ¿qué tal?" and c.duration_s == 4.0


def test_speaker_is_anonymised_and_stable(archive, tmp_path):
    cands = {c.original_id: c for c in source(archive, tmp_path).candidates("es-ES")}
    assert cands["c1.mp3"].speaker == cands["c2.mp3"].speaker == cv_speaker("clientA-secret")
    assert cands["c1.mp3"].speaker != cands["c7.mp3"].speaker
    assert cands["c1.mp3"].speaker.startswith("cv-") and "clientA" not in cands["c1.mp3"].speaker
    assert len(cands["c1.mp3"].speaker) == 3 + 12


def test_missing_archive_names_the_path_and_page(tmp_path):
    s = CommonVoice(tmp_path, archive=tmp_path / "nope.tar")
    with pytest.raises(FileNotFoundError) as e:
        s.candidates("es-ES")
    msg = str(e.value)
    assert str(tmp_path / "nope.tar") in msg and sources.CV_DATASET_URL in msg


def test_wrong_size_archive_is_refused(archive, tmp_path):
    s = CommonVoice(tmp_path, archive=archive)  # expected_size is the real 55 GB
    with pytest.raises(RuntimeError, match="expected 55738360832"):
        s.candidates("es-ES")


def test_raw_audio_reads_clip_bytes_through_the_cached_offset_index(archive, tmp_path):
    s = source(archive, tmp_path)
    assert s.raw_audio(["c7.mp3", "c1.mp3"]) == {"c1.mp3": b"audio-c1", "c7.mp3": b"audio-c7"}
    assert (archive.parent / f"{sources.CV_VERSION}.clip-offsets.json").exists()
    assert source(archive, tmp_path).raw_audio(["c2.mp3"]) == {"c2.mp3": b"audio-c2"}  # from the cached index


def test_revision_pins_the_archive_sha256_from_the_sidecar(archive, tmp_path):
    (archive.parent / "cv.tar.sha256").write_text("ab" * 32 + "  cv.tar\n")
    assert source(archive, tmp_path).revision == f"{sources.CV_VERSION}@sha256:{'ab' * 32}"


def test_phase1_es_es_is_common_voice_only(tmp_path):
    audio, _ = sources.phase1_sources(tmp_path)
    assert [s.dataset for s in audio] == ["fleurs", "common_voice"]
