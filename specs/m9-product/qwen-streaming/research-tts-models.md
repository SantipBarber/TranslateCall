# Investigación: alternativas a Qwen3-TTS para clonación de voz (2026-10-31)

Investigación solo de lectura (WebSearch/WebFetch + `gh api`). No se descargó ni ejecutó ningún modelo. Todo lo marcado [V] se leyó en la fuente citada; [N/V] = no verificado (blog de terceros, tarjeta sin el dato, o inferido).

## 1. Resumen ejecutivo

- Veredicto: **quedarse con Qwen3-TTS**. Ningún candidato con licencia comercial lo supera claramente en la combinación clonación + español + streaming real + coste en M4.
- El único con mejor similitud en español publicada es VoxCPM2 (SIM 83,1 frente a 81,4 de Qwen3-TTS 1.7B y 81,2 de 0.6B). Pero pesa 2B (3x), el streaming en Swift es falso (un solo evento) y su WER en español es peor (1,438 frente a 1,491/1,126). No compensa para telefonía en directo.
- Candidatos descartados por licencia no comercial: Voxtral TTS, OmniVoice, Higgs TTS 3 (Higgs Audio v3), Phonon (Gradium), Fish Audio S2 Pro, Breeze TTS 2. Fish Audio Drama 3 tiene licencia comunitaria con umbral de ingresos (ver 3.8) y es de 35B, inviable en un Mac mini.
- No hay una versión nueva de Qwen3-TTS: el repositorio solo muestra la publicación del 2026-01-22 (0.6B y 1.7B, Base/CustomVoice/VoiceDesign) [V https://github.com/QwenLM/Qwen3-TTS]. No encontré "Qwen3-TTS-Flash" abierto.
- Oportunidad concreta y barata: **actualizar mlx-audio-swift de 0.1.2 a 0.1.7** (lanzado 2026-10-26) [V gh api releases]. Hoy incluye muchos modelos nuevos; conviene comprobar si mejora Qwen3-TTS (no verificado qué cambió en el módulo Qwen3TTS).

## 2. Qué soportan hoy mlx-audio-swift y mlx-audio

**mlx-audio-swift** (https://github.com/Blaizzy/mlx-audio-swift): última release v0.1.7 (2026-10-26); v0.1.6 (10-20), v0.1.5/0.1.4 (10-05), v0.1.3 (07-09). `Package.swift`: swift-tools 6.2, macOS 14+, mlx-swift >= 0.33. [V]

Módulos TTS en `Sources/MLXAudioTTS/Models` [V, vía gh api]: Audio8, Bark, BreezeTTS, Chatterbox, Confucius4, Dia, EchoTTS, FishSpeech, HiggsAudio3TTS, HiggsAudioV2, IndexTTS, IrodoriTTS, KugelAudio, Llama (Orpheus), LongCatAudioDiT, Marvis, MeloTTS, Ming, MingOmni, MingTiny, MossTTS, MossTTSNano, OmniVoice, OuteTTS, PocketTTS, Qwen3, Qwen3TTS, Rumik, Soprano, Spark, StyleTTS2, TADA, VibeVoice, VibeVoiceTTS, VoxCPM, VoxCPM2, VoxtralTTS, Zonos2. (Kokoro aparece en mlx-audio Python; en Swift no lo vi en esa lista, comprobar si lo usamos por otra vía.)

Detalles de los READMEs Swift que importan [V]:
- Qwen3TTS: clonación con refAudio + refText; es el que usamos, con streaming real.
- VoxCPM2: `mlx-community/VoxCPM2-4bit` (~2,3 GB), 48 kHz, 30+ idiomas. "Streaming" envuelve la generación completa y emite **un único evento de audio** (sin chunks incrementales).
- VoxCPM 1/1.5: solo inglés y chino; también un único evento.
- Audio8: 0,1B y 0,6B, necesita refText; `generateStream` emite la forma de onda completa (no incremental).
- Chatterbox: Regular (520M, 23 idiomas), Turbo (inglés, 350M); clonación sin refText; tiene `generateStream`.
- PocketTTS/Phonon: streaming incremental real, 24 kHz.
- MossTTSNano: `generateStream` existe, pero trocea por frases (no verificado si hay chunks por debajo de la frase).

**mlx-audio (Python)** (https://github.com/Blaizzy/mlx-audio): v0.6.3 (2026-10-28) [V]. Lista ~30 modelos TTS: Kokoro, Qwen3-TTS, Audio8, Higgs Audio v3, Fish Audio Drama 3, OmniVoice, Chatterbox, Ming-3.0 TTS, Voxtral TTS, VoxCPM2, MOSS-TTS / MOSS-TTS-Nano, Phonon, CSM/MisoTTS, etc. [V, la tabla de la página; "streaming" no siempre indicado].

## 3. Candidatos

### 3.1 VoxCPM2 (OpenBMB) — LICENCIA OK
- Enlace: https://huggingface.co/openbmb/VoxCPM2 · https://github.com/OpenBMB/VoxCPM
- Fecha: README dice 2026.04; el informe técnico aparece con id arXiv 2606.06928 (inconsistente) [V parcial].
- Tamaño: 2B, bf16 ~5 GB; int8 MLX 2,95 GB; 4-bit 2,3 GB [V].
- Licencia: Apache-2.0 [V].
- Clonación: clip corto, sin transcripción en modo estándar; "ultimate cloning" con audio + transcripción exacta [V]. Longitud recomendada: no indicada.
- Idiomas: 30, incluye español, sin etiqueta de idioma [V].
- Streaming: `generate_streaming` en Python [V]. En Swift (mlx-audio-swift) NO es streaming real [V].
- Latencia: RTF ~0,30 en RTX 4090, ~0,13 con Nano-vLLM; sin primer chunk publicado. llama.cpp-omni en Metal: RTF ~1,76 (Q8_0) en M4 Pro [V]. Es decir, más lento que tiempo real en Metal con ese runtime.
- Calidad (README de GitHub, MiniMax Multilingual, **español**): WER 1,438, SIM 83,1. Comparación en la misma tabla: Qwen3-TTS 1,126 / 81,4 (variante 1.7B), ElevenLabs 1,084 / 61,5, MiniMax 1,029 / 76,2, FishAudio S2 0,910 / 77,6 [V]. Seed-TTS-eval: EN WER 1,84 / SIM 75,3; ZH CER 0,97 / SIM 79,5. CV3-eval es: 3,80 [V].
- Mac: MLX (mlx-community/VoxCPM2-4bit, módulo Swift propio en mlx-audio-swift); también `speech-swift` (aufklarer, `VoxCPM2TTSModel`, https://huggingface.co/aufklarer/voxcpm2-mlx-int8, int8 2,95 GB); backend CoreML/ANE comunitario (voxcpmane2); ONNX comunitario solo CPU [V].
- Integración: cambio de modelo en el mismo paquete (ya es dependencia), pero hay que trocear por frases para tener "streaming" a nivel de aplicación.
- Valoración: mejor SIM en español, pero 3x más grande, sin streaming incremental en Swift, latencia desconocida en M4. Candidato a PoC por calidad, no por latencia.

### 3.2 Pocket TTS (Kyutai) — LICENCIA OK (con atribución)
- Enlace: https://huggingface.co/kyutai/pocket-tts · blog 2026-01-13
- Tamaño: ~100M [V]. Licencia: CC-BY-4.0, con política de uso prohibido y acceso con aceptación de términos; las voces tienen licencias propias [V].
- Idiomas: en, fr, de, pt, it, es (6) [V]. Calidad en español: sin cifras [N/V].
- Clonación: WAV de referencia, sin transcripción; recomiendan limpiar el audio [V]. Longitud: no indicada.
- Streaming: sí; "~200 ms hasta el primer chunk"; ~6x tiempo real en CPU de un MacBook Air M4 con 2 núcleos [V].
- Calidad medida (SIM/WER/MOS): no encontrada [N/V] (la página del blog no devolvió contenido).
- Mac: módulo PocketTTS en mlx-audio-swift con streaming incremental [V]; CPU nativo.
- Valoración: muy atractivo como motor ligero (fallback con voz propia mucho mejor que Kokoro/AVSpeech) y para liberar GPU. La similitud de clonación suele ser inferior a modelos grandes; hay que medirla. Cubre es/en, no ucraniano ni asiáticos.

### 3.3 Audio8 TTS Preview 0.6B — LICENCIA OK (0.6B)
- Enlace: https://huggingface.co/Audio8/Audio8-TTS-Preview-0.6b · mlx: https://huggingface.co/mlx-community/Audio8-TTS-Preview-0.6b-bf16
- Tamaño: 0,6B (601M + códec 44,1 kHz) [V]. Licencia: Apache-2.0 para el 0.6B; el 0.1B usa "Audio8 Community License v1.0" (no leída) [V].
- Idiomas: 11 (yue, zh, nl, en, fr, de, it, ja, ko, pl, es); no ru, no pt [V]. Cobertura "intencionadamente limitada".
- Clonación: referencia + transcripción exacta obligatoria [V].
- Streaming: no en el modelo base; la variante ONNX INT4 CPU lista PCM en streaming; en Swift emite la onda completa [V].
- Calidad (Seed-TTS): EN WER 1,506 / SIM 63,2; ZH CER 0,950 / SIM 73,1 [V]. SIM claramente inferior a Qwen3-TTS en inglés. Tabla CV3 con español existe pero sin leer los números.
- Valoración: no supera a Qwen3-TTS 0.6B (SIM menor), sin streaming. Descartable.

### 3.4 MOSS-TTS Nano / MOSS-TTS family (OpenMOSS) — LICENCIA OK
- Enlace: https://github.com/OpenMOSS/MOSS-TTS · https://huggingface.co/OpenMOSS-Team/MOSS-TTS-Nano
- Nano: ~0,1B, 2026-04-10 (HF) / 04-13 (GitHub), 20 idiomas con es, streaming en 4 núcleos de CPU, clonación con un audio [V]. Licencia: metadatos Apache-2.0, pero el README avisa de que si el LICENSE raíz no está publicado se considera "no licenciado para redistribución"; el README de GitHub dice Apache-2.0 para toda la familia [V, ambiguo: comprobar antes de integrar].
- Familia grande: MOSS-TTS-v1.5 (8B, 2026-05-26), Local-Transformer-v1.5 (4B, 2026-06-18, 48 kHz), Local-Transformer 1.7B, Realtime 1.7B (TTFB 180 ms en L20 GPU, RTF 0,51), 31 idiomas con es [V].
- Benchmarks (Seed-TTS-eval): MossTTSLocal 1.7B EN WER 1,93 / SIM 73,3; ZH CER 1,44 / SIM 79,6; MossTTSDelay 8B EN WER 1,84 / SIM 70,9 [V]. Sin cifras para Nano ni español.
- Mac: soporte en mlx-audio desde 2026-05-06; módulos Swift MossTTS (sin cuantizar, solo checkpoints completos) y MossTTSNano [V].
- Valoración: Nano es interesante como motor ligero con clonación; calidad sin datos. El Local 1.7B queda por detrás de Qwen en SIM (73 frente a ~75-79 en EN según tablas distintas; ojo, test sets/evaluadores no son idénticos).

### 3.5 Chatterbox (Resemble AI) — LICENCIA OK (MIT)
- Enlace: https://huggingface.co/ResembleAI/chatterbox
- Multilingüe ~500M (23+ idiomas; hay finetunes de español LatAm y España), Turbo ~350M solo inglés [V]. Clonación sin transcripción; longitud no indicada. Fecha de V3: no indicada [N/V].
- Streaming y primer chunk: no publicados en la tarjeta (la "sub-200 ms" es del servicio de pago) [V]. En mlx-audio-swift hay `generateStream`, sin medir.
- Calidad cuantitativa en español: no encontrada [N/V]. Lleva marca de agua PerTh [N/V, conocimiento previo].
- Valoración: opción MIT sólida pero sin evidencia de superar a Qwen3-TTS en SIM/español. Baja prioridad.

### 3.6 Fun-CosyVoice3-0.5B-2512 — LICENCIA OK
- Enlace: https://huggingface.co/FunAudioLLM/Fun-CosyVoice3-0.5B-2512 · Apache-2.0, 0,5B, 2025-12 [V].
- 9 idiomas (zh, en, ja, ko, de, es, fr, it, ru); streaming bidireccional "hasta 150 ms" (no confirmado como primer paquete) [V].
- Seed-TTS: EN WER 2,24 / SIM 71,8; ZH CER 1,21 / SIM 78,0 (RL: 1,68/69,5 y 0,81/77,4) [V]. Por debajo de Qwen3-TTS 0.6B en WER inglés (1,32).
- Mac: las instrucciones son Linux; no hay port MLX en la lista de mlx-audio-swift [V/N-V]. Integración: costosa (PyTorch/ONNX).
- Valoración: no aporta frente a Qwen3-TTS.

### 3.7 Ming-3.0 TTS (inclusionAI) — LICENCIA OK, sin datos útiles
- Ming-omni-tts-0.5B: Apache-2.0, clonación; solo cifra WER 0,83 % en Seed-TTS zh [V]. Idiomas Ming-3.0 TTS Tiny/Dense según mlx-audio: zh, en, de, es, fr, ko, ja [V]. Sin datos de español, streaming ni SIM. Módulos Ming/MingTiny existen en Swift. Baja prioridad.

### 3.8 Descartados por licencia (verificado salvo indicación)
| Modelo | Motivo | Fuente |
|---|---|---|
| Voxtral TTS 4B (Mistral, 2026-03) | CC BY-NC 4.0 (voces incluidas) | https://huggingface.co/mistralai/Voxtral-4B-TTS-2603 |
| OmniVoice 0.6B (k2-fsa, 2026-04) | Código Apache, pesos CC-BY-NC (datos Emilia) | https://huggingface.co/k2-fsa/OmniVoice |
| Higgs TTS 3 / Higgs Audio v3 4B (Boson, 2026-06-04) | Licencia de investigación y no comercial; uso comercial exige acuerdo; "Creator Use Grant" posterior [fuentes secundarias, no leí la licencia por 401] | https://huggingface.co/bosonai/higgs-tts-3-4b |
| Phonon 40M (Gradium) | Pesos CC BY-NC 4.0 | https://huggingface.co/gradium/phonon-40m-multilingual |
| Fish Audio S2 Pro | Fish Audio Research License; comercial requiere licencia aparte | https://fish.audio/blog/what-we-mean-by-open-source-for-s2/ |
| Fish Audio Drama 3 (2026-10-13, 35B MoE) | Community License: gratis comercial bajo 500 000 USD/año de ingresos (solo fuentes secundarias). Además 35B: inviable en M4 | https://www.marktechpost.com/2026/10/14/fish-audio-drama-3-open-weight-tts-model/ |
| Breeze TTS 2 | No comercial (fuente secundaria) | pinggy.io |
| XTTS-v2 | Coqui CPML | conocido |

(Kokoro, ya en el producto, Apache-2.0; no se re-evaluó.)

## 4. Estado de Qwen3-TTS (línea base)
- 22 ene 2026; 0.6B/1.7B Base, CustomVoice, VoiceDesign, tokenizer 12 Hz; Apache-2.0; 10 idiomas; vLLM-Omni solo offline [V https://github.com/QwenLM/Qwen3-TTS].
- Español (test multilingüe del informe): 12Hz-0.6B-Base WER 1,491 / SIM 0,812; 12Hz-1.7B-Base WER 1,126 / SIM 0,814; MiniMax 1,029 / 0,762; ElevenLabs 1,084 / 0,615 [V].
- Seed-TTS: 12Hz-0.6B WER zh 0,92 / en 1,32; 1.7B 0,77 / 1,24 [V].
- Sin actualizaciones posteriores a enero 2026 en el repo [V]. Posible mejora interna: pasar al 1.7B-Base (SIM igual, WER español 1,126 frente a 1,491) si la latencia lo permite — **no medido**; es la palanca más simple de calidad.
- Aviso: la tarjeta HF lista "97 ms" de latencia de extremo a extremo en GPU; nuestro 0,33 s en M4 es el dato relevante.

## 5. Lista corta para PoC en el M4 (máx. 3)
1. **Qwen3-TTS 12Hz-1.7B-Base (cuantizado) + mlx-audio-swift 0.1.7** — no es un modelo nuevo, pero es el experimento de menor coste: mismo código, WER en español 1,126 frente a 1,491 y mejor estabilidad; medir primer chunk y RTF frente al 0.6B. Si el primer chunk sigue < ~0,5 s, adoptar.
2. **Pocket TTS (Kyutai, CC-BY-4.0, ~100M)** — como segundo motor ligero/fallback con voz propia y latencia ~200 ms medida en M4; sustituiría a Kokoro/AVSpeech cuando Qwen no esté disponible o la CPU/GPU esté saturada. Medir SIM subjetivo y calidad del español con una referencia de 5-10 s.
3. **VoxCPM2-4bit (Apache-2.0, 2B)** — solo si la prioridad es similitud máxima: SIM español 83,1 publicado. Requiere trocear por frases (el streaming de Swift es un único evento) y medir tiempo hasta el primer audio; RTF de Metal reportado 1,76 en M4 Pro sugiere que será más lento que Qwen. Prueba corta y con expectativas bajas.

## 6. Veredicto
**Quedarse con Qwen3-TTS** como motor principal. Ningún modelo abierto con licencia comercial muestra una ventaja clara y conjunta en similitud, español, streaming real y coste en Apple Silicon. Los modelos mejor valorados por la comunidad en 2026 (Voxtral, Higgs v3, OmniVoice, Phonon, Fish S2) son no comerciales. Acciones recomendadas: actualizar mlx-audio-swift a 0.1.7, probar el 1.7B, y evaluar Pocket TTS como fallback.

## 7. Lo que no se pudo verificar
- Primer chunk de VoxCPM2, Chatterbox, MOSS-TTS-Nano y Audio8 en M4 (no publicado).
- Cifras SIM/WER de Pocket TTS y Nano en español; licencia exacta de Higgs v3 y Drama 3 (solo fuentes secundarias).
- Qué cambió entre mlx-audio-swift 0.1.2 y 0.1.7 en el módulo Qwen3TTS.
- Ucraniano: ningún candidato lo anuncia entre los verificados (OmniVoice sí, 646 idiomas, pero es NC). Sigue cubierto por la cascada básica.
- Comparabilidad: las tablas de SIM/WER vienen de evaluadores y normalizadores distintos (los propios autores lo advierten); la tabla MiniMax-es de VoxCPM2 es la única comparación directa publicada con Qwen3-TTS.
