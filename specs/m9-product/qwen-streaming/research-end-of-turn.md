> Informe de investigación (Haiku, 2026-10-31). Comprobado por Claude contra las fuentes: Namo v1 Multilingual (Apache-2.0, ~295 MB ONNX cuantizado, entrada TEXTO, 23 idiomas, español acc 0,8888 en 1 295 muestras, <29 ms según el autor; sin CoreML), Smart Turn v3.2 (BSD-2, 8 MB int8, entrada AUDIO 16 kHz hasta 8 s, 23 idiomas, sin cifras por idioma; la ruta CoreML para Mac NO aparece en su README → no verificado), Hibiki-Zero (arXiv 2602.11072, ICML 2026, cinco tareas X→inglés; el abstract no nombra los idiomas → la lista FR/ES/PT/DE no está verificada). El resto de cifras son del informe sin comprobar.

# Investigación: detección de fin de frase / turno y traducción simultánea (2026-10-31)

Alcance: solo investigación web. No se ha tocado el repositorio. Cada dato lleva su URL. Lo que no pude comprobar está marcado como **no verificado**. No hay cifras de benchmark propias: todas las cifras son las publicadas por cada autor, con el conjunto de prueba que él eligió.

## Resumen (top 3, ordenado)

1. **Detector semántico de fin de frase sobre el transcript en streaming, con Namo Turn Detector v1 Multilingual como candidato principal para piloto.** Cubre 23 idiomas incluido español, es Apache-2.0, tiene ONNX cuantizado (~295 MB) y su tarjeta reporta 0,8888 de accuracy en español (1.295 muestras) y <29 ms de inferencia. Es la opción con licencia más limpia para un producto. Riesgo: las cifras son del propio proveedor y no hay export CoreML oficial, así que habría que convertirlo.
   - Fuentes: [Namo HF](https://huggingface.co/videosdk-live/Namo-Turn-Detector-v1-Multilingual), [blog VideoSDK](https://www.videosdk.live/blog/namo-turn-detection-v1-semantic-turn-detection-for-ai-voice-agents).
   - Alternativa con mejor cifra publicada en español: **LiveKit turn-detector multilingual**. Publica TPR 99,3 % y TNR 86,0 % para español, y dice que el modelo multilingüe es el recomendado para proyectos nuevos. Pero su licencia es LiveKit Model License (hay que revisarla para uso comercial) y no hay variante CoreML/MLX documentada. [HF livekit/turn-detector](https://huggingface.co/livekit/turn-detector).

2. **Señal de audio barata como segundo filtro: Pipecat Smart Turn v3.2 (BSD-2-Clause).** 8 MB int8 en CPU (32 MB fp32 en GPU), 23 idiomas incluido español, entrada de audio de hasta 8 s, latencia publicada de ~12 ms en CPU moderna y ~65 ms en una instancia de nube. Pipecat documenta una ruta CoreML para Mac, y hay una conversión CoreML de terceros. Ventaja: es audio, así que no depende del STT. Riesgo: no hay cifra de precisión en español publicada (**no verificado**), y está pensado para "fin de turno", no para "fin de frase".
   - Fuentes: [GitHub pipecat-ai/smart-turn](https://github.com/pipecat-ai/smart-turn), [blog Daily](https://www.daily.co/blog/announcing-smart-turn-v3-with-cpu-inference-in-just-12ms/), [docs CoreML Pipecat](https://docs.pipecat.ai/server/utilities/smart-turn/local-coreml-smart-turn), [conversión CoreML de terceros](https://huggingface.co/aufklarer/Smart-Turn-v3.2-CoreML).

3. **No cambiar de traductor todavía. Mantener cascada y mejorar la segmentación.** En traducción simultánea hay novedades reales (Hibiki-Zero, CUNI sobre Canary, políticas LLM), pero ninguna que yo haya podido confirmar como ejecutable en un Mac M4 con latencia y calidad publicadas para ES→EN. Hibiki-Zero es speech-to-speech y solo cubre FR/ES/PT/DE→EN según el abstract; no encontré cifras de latencia verificadas. Seamless Streaming tiene licencia CC-BY-NC (no comercial).
   - Fuentes: [arXiv 2602.11072](https://arxiv.org/abs/2602.11072), [blog Kyutai](https://kyutai.org/blog/2026-02-12-hibiki-zero), [CUNI IWSLT 2026](https://www.alphaxiv.org/abs/2606.03948), [Seamless arXiv](https://arxiv.org/pdf/2312.05187).

Recomendación de integración: piloto de **Namo (o LiveKit) sobre el transcript parcial + Smart Turn sobre el audio**, decidiendo "frase completa / incompleta" con un tope máximo de espera. Medir sobre grabaciones reales de llamadas en español antes de decidir.

---

## Área 1: detección semántica / fin de turno

| Nombre | Qué hace | Entrada | Tamaño | Idiomas | Latencia publicada | Licencia | Formato Mac | Enlace |
|---|---|---|---|---|---|---|---|---|
| Pipecat Smart Turn v3.2 | Clasifica si el usuario ha terminado su turno, a partir de audio | Audio 16 kHz mono, hasta 8 s | 8 MB int8 (CPU) / 32 MB fp32 (GPU); base Whisper Tiny (39M) | 23, incl. **español** (lista exacta en la fuente) | ~12 ms CPU moderna; ~65 ms instancia Pipecat Cloud; 12,6 ms en AWS c7a.2xlarge (publicado) | BSD-2-Clause | ONNX oficial; CoreML documentado por Pipecat (deprecado en favor de V3); CoreML de terceros | [GitHub](https://github.com/pipecat-ai/smart-turn), [blog Daily](https://www.daily.co/blog/announcing-smart-turn-v3-with-cpu-inference-in-just-12ms/) |
| Smart Turn v3 (precursor de v3.2) | Igual, versión anterior | Audio | 8 MB | 23 | 12 ms CPU moderna | BSD-2-Clause | ONNX | [blog Daily](https://www.daily.co/blog/announcing-smart-turn-v3-with-cpu-inference-in-just-12ms/) |
| LiveKit turn-detector (multilingüe) | Clasifica fin de frase a partir del texto del STT | Texto (transcript) | ~0,1B params, base Qwen2.5-0,5B-Instruct; <500 MB RAM | 14, incl. **español** | Sin latencia en la tarjeta. Snippet de PyPI: ~25 ms (**no verificado**) | LiveKit Model License (revisar uso comercial) | Transformers; sin CoreML/MLX oficial | [HF](https://huggingface.co/livekit/turn-detector), [PyPI](https://pypi.org/project/livekit-plugins-turn-detector), [docs](https://docs.livekit.io/agents/logic-structure/turns/turn-detector/) |
| Namo Turn Detector v1 Multilingual | Detector semántico de fin de turno sobre texto ASR | Texto | ~295 MB (mmBERT-base) | 23, incl. **español** | <29 ms (vendor) | Apache-2.0 | ONNX cuantizado (`model_quant.onnx`); CoreML no documentado | [HF](https://huggingface.co/videosdk-live/Namo-Turn-Detector-v1-Multilingual), [blog](https://www.videosdk.live/blog/namo-turn-detection-v1-semantic-turn-detection-for-ai-voice-agents) |
| Namo v1 monolingüe | Igual, un idioma por modelo | Texto | ~135 MB | 1 por modelo | <19 ms (vendor) | Apache-2.0 | ONNX | [PyPI LiveKit plugin](https://pypi.org/project/livekit-plugins-namo-turn-detector/) |
| TEN Turn Detection | Clasifica finished / wait / unfinished | Texto | Base Qwen2.5-7B (7,6B); tamaño de esta versión no indicado | **Solo inglés y chino** | No reportada | Apache-2.0 con restricciones adicionales | Python/transformers; sin ruta Mac documentada; no apto para ES | [GitHub](https://github.com/TEN-framework/ten-turn-detection) |
| TEN VAD | VAD frame a frame de baja latencia (no es EOT) | Audio | No verificado | Independiente de idioma | No verificado | Ver repo | No verificado | [GitHub](https://github.com/TEN-framework/ten-turn-detection) |
| VAP (Voice Activity Projection) | Predice turno/solapamiento en conversación | Audio estéreo/dos canales | No verificado | EN, ZH, JA (estudio multilingüe 2024) | CPU en demo (2024) | Código público (repo de Ekstedt) | PyTorch | [LREC-COLING 2024](https://aclanthology.org/2024.lrec-main.1036), [código](https://github.com/ErikEkstedt/VoiceActivityProjection) (citado en snippet, no abierto) |
| Conjunto de evaluación eot-bench (LiveKit/voiceaispace) | Benchmark de EOT en pausas reales, 14 idiomas | — | No indicado | 14, incl. ES | — | Apache-2.0 | — | [eot-bench](https://www.voiceaispace.com/knowledge/repo/eot-bench) |

Lectura de resultados (todo auto-reportado por el autor de cada modelo, con conjuntos distintos):
- LiveKit (español): TPR 99,3 %, TNR 86,0 % ([HF](https://huggingface.co/livekit/turn-detector)). TNR es la capacidad de detectar que el hablante sigue hablando.
- Namo (español): accuracy 0,8888, precisión 0,8304, recall 0,9681, F1 0,8940, 1.295 muestras ([HF](https://huggingface.co/videosdk-live/Namo-Turn-Detector-v1-Multilingual)).
- Smart Turn v3 (por idioma, sin español en el extracto): inglés 94,31 %, chino 88,57 %, árabe 88,60 %, bengalí 84,10 %, vietnamita 81,27 % ([blog Daily](https://www.daily.co/blog/announcing-smart-turn-v3-with-cpu-inference-in-just-12ms/)). **Español no verificado**: la página lo lista pero no da cifra en el extracto que obtuve.
- TEN (inglés): 90,64 % finished, 98,44 % unfinished; chino 98,90 % y 92,74 % ([GitHub](https://github.com/TEN-framework/ten-turn-detection)). Un trabajo independiente (Phoenix-VAD) da ~0,93 en completas y 0,83–0,86 en incompletas ([arXiv 2509.20410](https://arxiv.org/pdf/2509.20410)).
- Ninguna de estas cifras es comparable entre sí: cada una usa su propio conjunto de prueba.

Otros hallazgos 2026 (no probados para el caso de uso):
- TurnBench (2026): benchmark con 30 h de conversación diádica anotada a mano y 104 h de entrenamiento; evaluó 14 sistemas y dice que ninguno evita falsos positivos excesivos ([HF papers 2608.25218](https://huggingface.co/papers/2608.25218)). Fecha y cifras solo del snippet.
- JAL-Turn (2026): modelo speech-only sobre encoder ASR congelado, con etiquetas automáticas para diálogos ([arXiv 2603.26515](https://arxiv.org/abs/2603.26515)). Sin verificar cifras.
- BanglaTurn (2026): corpus de 35 374 muestras para bengalí; afirma que Smart-Turn v3 rinde mal en bengalí ([arXiv 2609.29371](https://arxiv.org/pdf/2609.29371)).

---

## Área 2: detección de fin de frase en el transcript (puntuación)

| Nombre | Qué hace | Tamaño | Idiomas | Latencia | Licencia | Formato Mac | Enlace |
|---|---|---|---|---|---|---|---|
| ELECTRA-Small de puntuación en streaming (Polacek, 2023) | Restaura ?, comas y puntos en texto de subtítulos en vivo; ~3 palabras de latencia | Pequeño (ELECTRA-Small) | Checo (2023) | ~3 palabras (publicado) | No verificada | No verificado | [Interspeech 2023](https://www.isca-archive.org/interspeech_2023/polacek23_interspeech.html) |
| mELECTRA multilingüe (Polacek, RANLP 2025) | Puntuación bilingüe y multilingüe en ELECTRA-small; publica modelos en HF | Pequeño | Checo, eslovaco, sueco, noruego (+ otros) | No verificada en streaming | No verificada | No verificado | [RANLP 2025](https://aclanthology.org/2025.ranlp-stud.5) |
| fullstop-punctuation-multilang-large | Puntuación multilingüe, dice soporte en tiempo real | 559M (XLM-RoBERTa) | 4 idiomas europeos | No verificada | No verificada | Grande para tiempo real en Mac | [PromptLayer](https://www.promptlayer.com/models/fullstop-punctuation-multilang-large) |
| Cadence "Mark My Words" (2025) | Restauración de puntuación con LLM generalista | LLM | No verificado | No apta para streaming (no es su objetivo) | No verificada | No apta | [arXiv 2506.03793](https://arxiv.org/abs/2506.03793) |
| STT con puntuación integrada: Parakeet TDT v3 (FluidAudio CoreML) | ASR con puntuación/mayúsculas según la tarjeta de un mirror | 0,6B | 25 idiomas europeos | RTFx ~155,6 (M4 Pro, batch) | Apache-2.0 | CoreML, macOS 14+ | [HF FluidInference](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml), [benchmarks](https://docs.fluidinference.com/reference/benchmarks.md) |
| Parakeet EOU 120M (FluidAudio, streaming) | ASR en streaming de 160 ms | 120M | **Solo inglés** | 160 ms de chunk | Ver repo | CoreML | [docs FluidAudio](https://docs.fluidinference.com) (citado en búsqueda) |
| Apple SpeechAnalyzer / SpeechTranscriber (macOS 26) | Resultados volátiles y finales; puntuación atribuida a DictationTranscriber, **no verificado** en SpeechTranscriber | En sistema | Según locale | Volátiles casi inmediatos (WWDC25) | Propietario | Nativo | [write-up WWDC25](https://dev.to/arshtechpro/wwdc-2025-the-next-evolution-of-speech-to-text-using-speechanalyzer-6lo) |

Conclusión del área: no encontré un modelo pequeño, multilingüe y en streaming de restauración de puntuación publicado en 2025–2026. La combinación más cercana es el enfoque ELECTRA-Small de Polacek, pero habría que construir y medir la parte de streaming. Si el STT ya da puntuación, el detector de frase puede apoyarse en ella, pero hay que medir si la puntuación parcial es estable.

---

## Área 3: traducción simultánea y en streaming

| Nombre | Qué hace | Tamaño | Idiomas | Latencia | Licencia | Mac | Enlace |
|---|---|---|---|---|---|---|---|
| Kyutai Hibiki-Zero (2026) | Speech-to-speech simultáneo sin datos alineados; RL con GRPO para latencia | 3B | FR, ES, PT, DE → EN (según abstract) | **No verificada** (el artículo y el blog no se pudieron leer completos) | Código y pesos liberados; un mirror indica CC-BY-NC-SA 4.0 (**no verificado** en el repo oficial) | No verificado (PyTorch bf16 en HF) | [arXiv 2602.11072](https://arxiv.org/abs/2602.11072), [blog](https://kyutai.org/blog/2026-02-12-hibiki-zero), [HF](https://huggingface.co/kyutai/hibiki-zero-3b-pytorch-bf16) |
| Meta SeamlessStreaming | Speech-to-text/speech simultáneo, ~2 s de latencia | ~2,5B (EMMA) | Multilingüe | ~2 s (publicado; un blog habla de <200 ms, sin fuente sólida) | CC-BY-NC 4.0 (no comercial) | No documentado | [arXiv 2312.05187](https://arxiv.org/pdf/2312.05187), [repo](https://github.com/facebookresearch/seamless_communication) |
| CUNI "Pocket offline" (IWSLT 2026) | SimulST con Canary-1B-v2 + política AlignAtt | 1B | Canary cubre inglés→24 idiomas; pares evaluados: cs-en, en-it | No verificada en el resumen | Ver artículo | Un GGUF comunitario de Canary existe ([HF](https://huggingface.co/handy-computer/canary-1b-v2-gguf)), pero **no** es streaming | [alphaxiv](https://www.alphaxiv.org/abs/2606.03948) |
| NVIDIA Nemotron/Canary cascada (IWSLT 2026) | ASR streaming + traducción en cascada; NVIDIA documenta esta ruta para tiempo real | Varios | Varios | No verificada | Ver NVIDIA | No aplicable en Mac | [NVIDIA FAQ](https://perspectives.nvidia.com/nemotron-speech/task/faq/how-do-i-build-a-real-time-pipeline-that-transcribes-audio-in-one-language-and-o/) |
| Hierarchical Policy Optimization (arXiv 2604.21045) | LLM simultáneo con codificador en streaming y caché KV | No verificado | No verificado | No verificada | No verificada | Servidor GPU | [arXiv 2604.21045](https://arxiv.org/pdf/2604.21045) |
| StreamUni (arXiv 2507.07803) | Segmentación, decisión read/write y traducción en un solo modelo | No verificado | No verificado | No verificada | No verificada | Servidor | [arXiv](https://arxiv.org/abs/2507.07803) |
| EASiST (arXiv 2504.11809) | Speech LLM extremo a extremo con caché KV; evalúa En→De y En→Es (MuST-C) | No verificado | En→De, En→Es | No verificada | No verificada | Servidor | [arXiv html](https://arxiv.org/html/2504.11809v1) |
| SASST (arXiv 2508.07781) | Chunking consciente de sintaxis + LLM | No verificado | No verificado | No verificada | No verificada | Servidor | [arXiv](https://arxiv.org/pdf/2508.07781) |

Lectura: la traducción simultánea de voz en 2026 avanza hacia modelos únicos con políticas aprendidas (Hibiki-Zero, StreamUni, EASiST), pero casi todo se evalúa en GPU de servidor y con pares que no son ES↔EN. Para esta app, la ganancia realista a corto plazo es **segmentar mejor** (frase completa) y dejar que el traductor de texto (Apple Translation) haga el resto, no cambiar a speech-to-speech.

---

## Área 4: viabilidad de fine-tuning y datos

| Recurso | Qué es | Tamaño | Idiomas | Licencia | Enlace |
|---|---|---|---|---|---|
| Smart Turn data v3 (train/test) | Datos para entrenar y evaluar Smart Turn v3 | No indicado en el extracto | 23 | No verificada | [HF test](https://huggingface.co/datasets/pipecat-ai/smart-turn-data-v3-test), [HF train](https://huggingface.co/datasets/pipecat-ai/smart-turn-data-v3-train) (**URLs construidas a partir del nombre que da el blog; no abiertas**) |
| eot-bench | Benchmark de EOT en pausas reales, métricas de dead air y falsos cortes | No indicado | 14 (ES incluido) | Apache-2.0 | [voiceaispace](https://www.voiceaispace.com/knowledge/repo/eot-bench) |
| TurnBench | Corpus diádico anotado (30 h test, 104 h train) | 134 h | No verificado | No verificada | [HF papers](https://huggingface.co/papers/2608.25218) |
| Corpus BanglaTurn | 35 374 muestras de fin de turno en bengalí | 35 374 | Bengalí | No verificada | [arXiv](https://arxiv.org/pdf/2609.29371) |

Esfuerzo (estimación, no medido): un fine-tuning de Namo, Smart Turn o LiveKit sobre datos propios de llamadas en español requiere (a) etiquetar frases completas/incompletas en transcripts reales, (b) entrenar un clasificador sobre un modelo ya existente, (c) evaluar con eot-bench o un conjunto propio. No encontré un dataset multilingüe de fin de frase con receta de fine-tuning documentada. **No verificado**: el número de horas necesarias para superar a los modelos base en español.

---

## Notas de integración

Pipeline actual: VAD (Silero, 256 ms) → cierre fijo por 0,6 s de silencio → STT → traducción → TTS. Latencia de fin de turno hoy: ~0,85 s.

1. **Smart Turn sobre el audio acumulado**: se consulta cuando el VAD detecta silencio. Coste medido por el autor: ~12–65 ms por decisión en CPU. Si dice "completo", se cierra como hoy. Si dice "incompleto", se espera hasta un tope. Es el punto de entrada más barato.
2. **Namo o LiveKit sobre el transcript parcial del STT**: se evalúa en cada resultado parcial o cuando hay silencio corto. Si el texto parece frase completa (punto final, o clasificador "fin"), se traduce. Si no, se retiene. Requiere que el STT entregue parciales estables (Apple SpeechAnalyzer volátiles o Parakeet en streaming).
3. **Tope de espera**: la regla fundamental es un máximo de espera (por ejemplo, un tiempo de corte duro), para que una frase que nunca termina no bloquee la traducción. El valor debe medirse, no fijarse aquí.
4. **Traducción simultánea (Hibiki-Zero, CUNI, Seamless)**: fuera de alcance por ahora. Revisar cuando haya cifras de latencia y licencia verificadas para ES→EN en Apple Silicon.

**Compensación de latencia (cualitativa, sin cifras inventadas)**: los modelos de turno (Smart Turn) cuestan milisegundos. Lo que añade latencia de verdad es la espera extra que se decide cuando el modelo dice "incompleto". Esa espera extra es lo que hay que medir sobre llamadas reales.

---

## Riesgos abiertos y qué medir

- **Español en Smart Turn**: sin cifra publicada en el extracto. Medir accuracy y TPR/TNR en llamadas propias.
- **Cifras de Namo y LiveKit**: auto-reportadas, con conjuntos distintos. Medir en el mismo conjunto de llamadas en español.
- **Licencia de LiveKit**: LiveKit Model License. Revisar condiciones comerciales antes de usarlo en producto.
- **Conversión a CoreML/MLX**: Namo tiene ONNX (medir ONNX Runtime en Mac). LiveKit no tiene export documentado. Smart Turn tiene ruta CoreML documentada por Pipecat (y una conversión de terceros, no verificada).
- **Latencia real en Mac M4**: todas las cifras son de CPU de nube o de la fuente. Medir en el M4 con el pipeline real.
- **Estabilidad de parciales**: si el STT cambia palabras ya emitidas, un clasificador de texto puede decidir mal. Medir la tasa de cambios en parciales.
- **Apple SpeechAnalyzer y puntuación**: la afirmación de puntuación sale de un solo blog (DictationTranscriber). **No verificado** para SpeechTranscriber.
- **FluidAudio Parakeet TDT v3 en streaming**: la documentación oficial lo lista como batch; el streaming usa EOU 120M (solo inglés). **No verificado** si TDT v3 soporta streaming con puntuación.
- **Hibiki-Zero**: latencia, calidad y licencia no verificadas en el artículo completo.
- **Seamless Streaming**: CC-BY-NC, no comercial.
- **Fechas de algunos 2026 (TurnBench, BanglaTurn, CUNI)**: vienen de snippets de búsqueda, no del texto completo.

Fuentes consultadas (todas citadas arriba). Páginas abiertas completas: GitHub Smart Turn, blog Daily Smart Turn v3, HF livekit/turn-detector, HF Namo multilingual, GitHub TEN, eot-bench, arXiv 2602.11072 (solo abstract). Lo demás viene de resultados de búsqueda.
