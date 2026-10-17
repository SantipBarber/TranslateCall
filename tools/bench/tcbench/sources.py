"""Phase-1 dataset sources with pinned revisions (REQ-BH-03/04, design 4.1).

Revisions were resolved once, on 2026-10-17:
  - google/fleurs, facebook/voxpopuli: HF API `GET /api/datasets/<id>` -> `sha` (the repo's main commit).
  - MicrosoftTranslator/NTREX: GitHub API `GET /repos/.../commits?per_page=1` -> sha of main.
Smart Turn v3 test (pipecat-ai/smart-turn-data-v3-test) is deferred to project 2 (controller ruling R1).
"""

from __future__ import annotations

import csv
import os
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
                    speaker=f"fleurs-{variant}-{r[6].lower()}",
                    translations=dict(ref.get(r[0], {})),
                    tags=["fleurs"],
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
            if not text:
                continue
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
                    tags=["voxpopuli"],
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


class CommonVoice:
    """Gated (needs a Hugging Face token with access); optional. Phase 1 does not select from it."""

    dataset = "common_voice"
    licence = "CC0-1.0"
    TOKEN_ENV = "TC_BENCH_CV_TOKEN"

    @staticmethod
    def skip_reason() -> str | None:
        if not os.environ.get(CommonVoice.TOKEN_ENV):
            return f"Common Voice skipped: {CommonVoice.TOKEN_ENV} is not set (gated dataset, optional in phase 1)"
        return (
            "Common Voice skipped: token present but selection from Common Voice is not implemented in phase 1"
        )


def audio_source(dataset: str, cache: Path) -> AudioSource:
    if dataset == "fleurs":
        return Fleurs(cache)
    if dataset == "voxpopuli":
        return VoxPopuli(cache)
    raise ValueError(f"no downloader for dataset {dataset!r}")


def phase1_sources(cache: Path):
    return [Fleurs(cache), VoxPopuli(cache)], [Ntrex(cache)]
