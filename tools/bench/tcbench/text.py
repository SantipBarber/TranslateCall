"""Word error rate: a port of TranslateCallTests/Support/WordErrorRate.swift."""
import unicodedata


def normalize_words(text: str) -> list[str]:
    """NFKD, drop combining marks, casefold, split on non-alphanumerics."""
    decomposed = unicodedata.normalize("NFKD", text)
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c)).casefold()
    return _split_alnum(stripped)


def _split_alnum(text: str) -> list[str]:
    words: list[str] = []
    current: list[str] = []
    for ch in text:
        if ch.isalnum():
            current.append(ch)
        elif current:
            words.append("".join(current))
            current = []
    if current:
        words.append("".join(current))
    return words


def _edits(ref: list[str], hyp: list[str]) -> int:
    prev = list(range(len(hyp) + 1))
    for i in range(1, len(ref) + 1):
        cur = [i] + [0] * len(hyp)
        for j in range(1, len(hyp) + 1):
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        prev = cur
    return prev[len(hyp)]


def wer(reference: str, hypothesis: str) -> float:
    ref, hyp = normalize_words(reference), normalize_words(hypothesis)
    if not ref:
        return 0 if not hyp else 1
    return _edits(ref, hyp) / len(ref)


def corpus_wer(pairs: list[tuple[str, str]]) -> float:
    """Total edits over total reference words."""
    edits = words = 0
    for reference, hypothesis in pairs:
        ref, hyp = normalize_words(reference), normalize_words(hypothesis)
        words += len(ref)
        edits += _edits(ref, hyp) if ref else len(hyp)
    return edits / words if words else 0
