import pytest

from tcbench.sources import sentence_like


@pytest.mark.parametrize("text", ["Señor Presidente, quiero hablar.", "¿Qué opina usted?", "«Muy bien.»", "¡Gracias!"])
def test_sentence_like_accepts(text):
    assert sentence_like(text)


@pytest.mark.parametrize("text", ["señor presidente, quiero hablar.", "Señor Presidente, quiero", "", "y entonces dijo."])
def test_sentence_like_rejects_fragments(text):
    assert not sentence_like(text)
