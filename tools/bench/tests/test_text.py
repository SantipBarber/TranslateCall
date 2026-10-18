from tcbench.text import corpus_wer, normalize_words, wer


def test_identical_is_zero():
    assert wer("hola qué tal", "hola qué tal") == 0


def test_ignores_case_and_punctuation():
    assert wer("Hola, ¿qué tal?", "hola que tal") == 0


def test_one_substitution_of_four():
    assert wer("can you hear me", "can you see me") == 0.25


def test_deletion_and_insertion():
    # ref 3 words; hyp drops one and adds one -> 2 edits / 3
    assert abs(wer("добрий день друже", "добрий друже привіт") - 2.0 / 3.0) < 1e-9


def test_empty_hypothesis_is_one():
    assert wer("a b", "") == 1


def test_empty_reference():
    assert wer("", "") == 0
    assert wer("", "x") == 1


def test_corpus_wer_is_total_edits_over_total_words():
    assert corpus_wer([("a b", "a"), ("c d", "c d")]) == 0.25


def test_normalize_words():
    assert normalize_words("Hola, ¿Qué  TAL?") == ["hola", "que", "tal"]
