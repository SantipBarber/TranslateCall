"""Phase-1 dataset sources with pinned revisions (REQ-BH-03/04, design 4.1).

Revisions were resolved once, on 2026-10-17:
  - google/fleurs, facebook/voxpopuli: HF API `GET /api/datasets/<id>` -> `sha` (the repo's main commit).
  - MicrosoftTranslator/NTREX: GitHub API `GET /repos/.../commits?per_page=1` -> sha of main.
Smart Turn v3 test (pipecat-ai/smart-turn-data-v3-test) is deferred to project 2 (controller ruling R1).
"""

from __future__ import annotations

import csv
import json
import os
import sys
import tarfile
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

FLEURS_REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
VOXPOPULI_REVISION = "42f01879c780b4a2e90ec0b4f616c2ece526e4f1"
NTREX_REVISION = "468c6b69c7f6a75d31d4743d9daba2af566cc18d"

# Licences the harness may use (requirements D-2). Anything else is refused.
ALLOWED_LICENCES = frozenset({"CC0-1.0", "CC-BY-4.0", "CC-BY-SA-4.0"})

NTREX_RAW = "https://raw.githubusercontent.com/MicrosoftTranslator/NTREX/{rev}/NTREX-128/{name}"


def default_cache_dir() -> Path:
    return Path(os.environ.get("TC_BENCH_CACHE") or Path.home() / "Library/Caches/TranslateCallBench")


@dataclass
class Candidate:
    original_id: str
    lang: str
    variant: str
    transcript: str
    duration_s: float
    speaker: str
    native: bool = True
    translations: dict[str, str] = field(default_factory=dict)
    tags: list[str] = field(default_factory=list)


class AudioSource(Protocol):
    dataset: str
    revision: str
    licence: str

    def variants(self) -> list[str]: ...
    def candidates(self, variant: str) -> list[Candidate]: ...
    def raw_audio(self, original_ids: list[str]) -> dict[str, bytes]: ...


class TextSource(Protocol):
    dataset: str
    revision: str
    licence: str

    def pairs(self, src_lang: str, tgt_lang: str) -> list[tuple[str, str]]: ...


def _hf(repo: str, revision: str, filename: str, cache: Path) -> Path:
    from huggingface_hub import hf_hub_download

    return Path(
        hf_hub_download(
            repo, filename, repo_type="dataset", revision=revision, local_dir=cache / "_downloads" / repo.replace("/", "__")
        )
    )


def _read_tsv(path: Path) -> list[list[str]]:
    with open(path, encoding="utf-8", newline="") as f:
        return list(csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE))


class Fleurs:
    """FLEURS test split: es_419 -> variant es-419, en_us -> variant en; de_de only supplies reference text."""

    dataset = "fleurs"
    revision = FLEURS_REVISION
    licence = "CC-BY-4.0"
    CONFIGS = {"es-419": ("es", "es_419"), "en": ("en", "en_us")}
    REF_CONFIGS = {"es": "es_419", "en": "en_us", "de": "de_de"}

    def __init__(self, cache: Path):
        self.cache = cache
        self._tsv: dict[str, list[list[str]]] = {}

    def variants(self) -> list[str]:
        return list(self.CONFIGS)

    def _rows(self, config: str) -> list[list[str]]:
        if config not in self._tsv:
            self._tsv[config] = _read_tsv(_hf("google/fleurs", self.revision, f"data/{config}/test.tsv", self.cache))
        return self._tsv[config]

    def candidates(self, variant: str) -> list[Candidate]:
        lang, config = self.CONFIGS[variant]
        # Reference translations: the same sentence id in the other languages (FLEURS is n-way parallel).
        ref: dict[str, dict[str, str]] = {}
        for rl, rc in self.REF_CONFIGS.items():
            if rl == lang:
                continue
            for r in self._rows(rc):
                ref.setdefault(r[0], {}).setdefault(rl, r[2])
        other = "en_us" if config == "es_419" else "es_419"
        shared = {r[0] for r in self._rows(other)}  # only sentence ids present in both
        out = []
        for r in self._rows(config):
            if r[0] not in shared:
                continue
            out.append(
                Candidate(
                    original_id=f"{config}/{r[1]}",
                    lang=lang,
                    variant=variant,
                    transcript=r[2],
                    duration_s=int(r[5]) / 16000,
                    speaker=f"fleurs-{variant}-unknown-{r[6][:1].lower()}",  # FLEURS has no speaker id: visibly synthetic
                    translations=dict(ref.get(r[0], {})),
                    tags=["fleurs", "speaker-unknown"],
                )
            )
        return out

    def raw_audio(self, original_ids: list[str]) -> dict[str, bytes]:
        by_config: dict[str, dict[str, str]] = {}
        for oid in original_ids:
            config, name = oid.split("/", 1)
            by_config.setdefault(config, {})[f"test/{name}"] = oid
        out: dict[str, bytes] = {}
        for config, wanted in by_config.items():
            archive = _hf("google/fleurs", self.revision, f"data/{config}/audio/test.tar.gz", self.cache)
            remaining = set(wanted)
            with tarfile.open(archive, "r|gz") as tar:
                for m in tar:
                    if m.name in remaining:
                        out[wanted[m.name]] = tar.extractfile(m).read()
                        remaining.discard(m.name)
                        if not remaining:
                            break
            if remaining:
                raise RuntimeError(f"fleurs {config}: {len(remaining)} clips missing from archive, e.g. {sorted(remaining)[0]}")
        return out


_OPEN = "¿¡«“\"'(—-– "
_CLOSE = "»”\"')"


def sentence_like(text: str) -> bool:
    """Starts with a capital letter and ends with sentence-final punctuation."""
    t = text.strip().lstrip(_OPEN)
    e = text.strip().rstrip(_CLOSE)
    return bool(t) and bool(e) and t[0].isupper() and e[-1] in ".?!…"


class VoxPopuli:
    """VoxPopuli es test (European Parliament) -> variant es-ES."""

    dataset = "voxpopuli"
    revision = VOXPOPULI_REVISION
    licence = "CC0-1.0"
    FILE = "es/test-00000-of-00001.parquet"

    def __init__(self, cache: Path):
        self.cache = cache

    def variants(self) -> list[str]:
        return ["es-ES"]

    def _path(self) -> Path:
        return _hf("facebook/voxpopuli", self.revision, self.FILE, self.cache)

    def candidates(self, variant: str) -> list[Candidate]:
        import pyarrow.parquet as pq

        pf = pq.ParquetFile(self._path())
        meta = pf.read(columns=["audio_id", "raw_text", "speaker_id"]).to_pylist()
        sizes: list[int] = []
        for batch in pf.iter_batches(batch_size=32, columns=["audio"]):
            sizes += [len(a["bytes"]) for a in batch.column(0).to_pylist()]
        out = []
        for m, nbytes in zip(meta, sizes, strict=True):
            text = (m["raw_text"] or "").strip()
            if not sentence_like(text):
                continue  # segment edges cut mid-sentence give unreliable clips (lowercase start / no final punctuation)
            # 16 kHz mono WAV: 44-byte header, 32-bit float samples (checked on the pinned revision).
            dur = (nbytes - 44) / 4 / 16000
            out.append(
                Candidate(
                    original_id=m["audio_id"],
                    lang="es",
                    variant="es-ES",
                    transcript=text,
                    duration_s=dur,
                    speaker=f"vp-es-{m['speaker_id']}",
                    tags=["voxpopuli", "accent-unverified"],
                )
            )
        return out

    def raw_audio(self, original_ids: list[str]) -> dict[str, bytes]:
        import pyarrow.parquet as pq

        remaining = set(original_ids)
        out: dict[str, bytes] = {}
        for batch in pq.ParquetFile(self._path()).iter_batches(batch_size=32, columns=["audio_id", "audio"]):
            for aid, a in zip(batch.column(0).to_pylist(), batch.column(1).to_pylist(), strict=True):
                if aid in remaining:
                    out[aid] = a["bytes"]
                    remaining.discard(aid)
            if not remaining:
                break
        if remaining:
            raise RuntimeError(f"voxpopuli es: {len(remaining)} clips missing from parquet, e.g. {sorted(remaining)[0]}")
        return out


class Ntrex:
    """NTREX-128 newstest2019 references: eng (src file) and spa (Spain) line-aligned."""

    dataset = "ntrex128"
    revision = NTREX_REVISION
    licence = "CC-BY-SA-4.0"
    FILES = {"en": "newstest2019-src.eng.txt", "es": "newstest2019-ref.spa.txt"}

    def __init__(self, cache: Path):
        self.cache = cache

    def _lines(self, lang: str) -> list[str]:
        name = self.FILES[lang]
        dest = self.cache / "_downloads" / "ntrex" / self.revision / name
        if not dest.exists():
            dest.parent.mkdir(parents=True, exist_ok=True)
            with urllib.request.urlopen(NTREX_RAW.format(rev=self.revision, name=name), timeout=60) as r:
                dest.write_bytes(r.read())
        lines = dest.read_text(encoding="utf-8").split("\n")
        return lines[:-1] if lines and lines[-1] == "" else lines

    def pairs(self, src_lang: str, tgt_lang: str) -> list[tuple[str, str]]:
        s, t = self._lines(src_lang), self._lines(tgt_lang)
        if len(s) != len(t):
            raise RuntimeError(f"ntrex128: {src_lang}/{tgt_lang} line counts differ ({len(s)} vs {len(t)})")
        return [(a.strip(), b.strip()) for a, b in zip(s, t, strict=True)]


# Common Voice Scripted Speech 27.0 (es), read from a local archive the user downloaded from Mozilla Data Collective.
CV_VERSION = "cv-corpus-27.0-2026-09-11"
CV_ARCHIVE_NAME = f"{CV_VERSION}-es.tar"
CV_ARCHIVE_SIZE = 55_738_360_832
CV_DATASET_URL = "https://mozilladatacollective.com/datasets/cmu5kitx700pemi073feoiqqu"
CV_ARCHIVE_ENV = "TC_BENCH_CV_ARCHIVE"
CV_PREFIX = f"{CV_VERSION}/es/"
# Self-reported accents that are Spain (es-ES). Exact whole-field matches only: multi-value fields ("a|b"),
# free text, empty and unknown accents are excluded because they are not verifiable. Latin American, Philippine,
# American and other varieties are excluded by not being listed.
CV_SPAIN_ACCENTS = {
    "España: Norte peninsular (Asturias, Castilla y León, Cantabria, País Vasco, Navarra, Aragón, La Rioja, Guadalajara, Cuenca)": "accent-es-norte-peninsular",
    "España: Centro-Sur peninsular (Madrid, Toledo, Castilla-La Mancha)": "accent-es-centro-sur-peninsular",
    "España: Sur peninsular (Andalucia, Extremadura, Murcia)": "accent-es-sur-peninsular",
    "España: Islas Canarias": "accent-es-islas-canarias",
    "España: Este peninsular (Comunidad Valenciana)": "accent-es-este-peninsular",
}
CV_MAX_PER_SPEAKER = 5
CV_SPEAKER_SALT = "tcbench-cv-v1:"


def cv_archive_path() -> Path:
    env = os.environ.get(CV_ARCHIVE_ENV)
    return Path(env) if env else default_cache_dir() / "_downloads" / "commonvoice" / CV_ARCHIVE_NAME


def cv_speaker(client_id: str) -> str:
    """Anonymised speaker id; the raw client_id never leaves the archive."""
    import hashlib

    return "cv-" + hashlib.sha256((CV_SPEAKER_SALT + client_id).encode()).hexdigest()[:12]


class CommonVoice:
    """Common Voice 27.0 es, test split only (an evaluation, never train/dev), Spain accents -> variant es-ES.

    Terms: no re-hosting or re-sharing, no attempt to identify speakers. Nothing leaves the local cache.
    """

    dataset = "common_voice"
    licence = "CC0-1.0"
    max_per_speaker = CV_MAX_PER_SPEAKER
    SPLIT = "test"

    def __init__(self, cache: Path, archive: Path | None = None):
        self.cache = cache
        self.archive = archive or cv_archive_path()
        self.version = CV_VERSION
        self.prefix = CV_PREFIX
        self.expected_size = CV_ARCHIVE_SIZE
        self._index: dict | None = None

    # -- archive access
    def _check_archive(self) -> Path:
        if not self.archive.is_file():
            raise FileNotFoundError(
                f"Common Voice archive not found at {self.archive}. Download '{CV_ARCHIVE_NAME}' from {CV_DATASET_URL} "
                f"and place it there (or set {CV_ARCHIVE_ENV})."
            )
        size = self.archive.stat().st_size
        if self.expected_size is not None and size != self.expected_size:
            raise RuntimeError(f"Common Voice archive {self.archive} is {size} bytes, expected {self.expected_size}")
        return self.archive

    @property
    def revision(self) -> str:
        """Version plus the archive's sha256 (hashed once; cached in a .sha256 file next to the archive)."""
        path = self._check_archive()
        side = path.with_name(path.name + ".sha256")
        if side.exists():
            digest = side.read_text().split()[0]
        else:
            import hashlib

            print(f"hashing {path.name} once (slow); the result is cached in {side.name}", file=sys.stderr, flush=True)
            h = hashlib.sha256()
            with open(path, "rb") as f:
                for block in iter(lambda: f.read(8 << 20), b""):
                    h.update(block)
            digest = h.hexdigest()
            side.write_text(f"{digest}  {path.name}\n")
        return f"{self.version}@sha256:{digest}"

    def _read_members(self, names: list[str]) -> dict[str, bytes]:
        """Read small leading members (TSVs) by walking the first headers only."""
        want = {self.prefix + n for n in names}
        out: dict[str, bytes] = {}
        with tarfile.open(self._check_archive(), "r:") as tar:
            for m in tar:
                if m.name in want:
                    out[m.name[len(self.prefix) :]] = tar.extractfile(m).read()
                    want.discard(m.name)
                    if not want:
                        break
        if want:
            raise RuntimeError(f"Common Voice archive {self.archive} lacks {sorted(want)}")
        return out

    # -- selection
    def variants(self) -> list[str]:
        return ["es-ES"]

    def candidates(self, variant: str) -> list[Candidate]:
        import io

        files = self._read_members([f"{self.SPLIT}.tsv", "clip_durations.tsv"])
        csv.field_size_limit(sys.maxsize)
        durations = {}
        for r in csv.DictReader(io.StringIO(files["clip_durations.tsv"].decode("utf-8")), delimiter="\t", quoting=csv.QUOTE_NONE):
            durations[r["clip"]] = int(r["duration[ms]"]) / 1000
        out = []
        for r in csv.DictReader(io.StringIO(files[f"{self.SPLIT}.tsv"].decode("utf-8")), delimiter="\t", quoting=csv.QUOTE_NONE):
            tag = CV_SPAIN_ACCENTS.get(r["accents"])
            if tag is None or r["path"] not in durations or not r["sentence"].strip():
                continue
            out.append(
                Candidate(
                    original_id=r["path"],
                    lang="es",
                    variant="es-ES",
                    transcript=r["sentence"].strip(),
                    duration_s=durations[r["path"]],
                    speaker=cv_speaker(r["client_id"]),
                    native=False,  # not asserted: Common Voice does not say
                    tags=["commonvoice", tag, "accent-self-reported", "native-unknown"],
                )
            )
        return out

    # -- audio
    def _load_index(self) -> dict:
        """{clip name: [data offset, size]} for every clip, built once by walking the tar headers (about 2 min)."""
        if self._index is not None:
            return self._index
        side = self.archive.with_name(f"{self.version}.clip-offsets.json")
        if side.exists():
            self._index = json.loads(side.read_text())
            return self._index
        print(f"indexing {self.archive.name} once; cached in {side.name}", file=sys.stderr, flush=True)
        index = {}
        clips = self.prefix + "clips/"
        with tarfile.open(self._check_archive(), "r:") as tar:
            for m in tar:
                if m.isfile() and m.name.startswith(clips):
                    index[m.name[len(clips) :]] = [m.offset_data, m.size]
                tar.members = []  # keep memory flat over millions of headers
        side.write_text(json.dumps(index, separators=(",", ":")))
        self._index = index
        return index

    def raw_audio(self, original_ids: list[str]) -> dict[str, bytes]:
        index = self._load_index()
        out = {}
        with open(self._check_archive(), "rb") as f:
            for oid in sorted(original_ids, key=lambda n: index[n][0] if n in index else -1):
                if oid not in index:
                    raise RuntimeError(f"common_voice: clip {oid} not in the archive")
                off, size = index[oid]
                f.seek(off)
                out[oid] = f.read(size)
        return out


def audio_source(dataset: str, cache: Path) -> AudioSource:
    if dataset == "fleurs":
        return Fleurs(cache)
    if dataset == "voxpopuli":
        return VoxPopuli(cache)
    if dataset == "common_voice":
        return CommonVoice(cache)
    raise ValueError(f"no downloader for dataset {dataset!r}")


def phase1_sources(cache: Path):
    # VoxPopuli is no longer a phase-1 source (segments lack lead/tail silence); es-ES is Common Voice only.
    return [Fleurs(cache), CommonVoice(cache)], [Ntrex(cache)]
