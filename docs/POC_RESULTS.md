# TranslateCall - Resultados de Pruebas de Concepto (Milestone 0)

**Fecha de ejecucion:** 31 de enero de 2026
**Entorno:** macOS 26.2 (Tahoe), Build 25C56 | Swift 5.10 | Mac mini
**Repositorio:** TranslateCallPocs

---

## Resumen Ejecutivo

| PoC | Nombre | Tests | Resultado | Estado |
|-----|--------|-------|-----------|--------|
| 1 | Translation API | 4/4 | **PASS** | Validado con contexto SwiftUI minimo |
| 2 | Voice Activity Detection | 4/4 | **PASS** | Listo para integrar |
| 3 | Voice Cloning DSP | 4/4 (calidad insuficiente) | **NO-GO** | Deferir a Phase 2 (MLX-Audio) |
| 4 | BlackHole Integration | 5/5 | **PASS** | BlackHole detectado y configurado via Homebrew |
| 5 | Half-Duplex Echo Management | 6/6 | **PASS** | Listo para integrar |

**Decision Go/No-Go:** GO con ajustes. La arquitectura core es viable. Voice cloning se pospone al MVP Enhanced (Phase 2).

---

## PoC 1: Translation API

**Objetivo:** Validar que Apple Translation Framework funciona sin SwiftUI visible, con latencias aceptables para traduccion en tiempo real.

**Hallazgo critico:** El Translation Framework **requiere** un contexto SwiftUI (`.translationTask()`) para acceder a los modelos de traduccion descargados. Un command-line tool puro no puede usar `TranslationSession(installedSource:target:)` porque `LanguageAvailability` reporta los idiomas como `supported` en lugar de `installed`, incluso estando descargados.

**Solucion implementada:** App minima con NSApplication + NSHostingView oculto que proporciona el contexto SwiftUI necesario. La ventana puede ser invisible (`LSUIElement = true`).

### Resultados

| Test | Estado | Latencia | Detalle |
|------|--------|----------|---------|
| TranslationViaTask | PASS | 44,224 ms* | ES->EN: "Hola, como estas?" -> "Hello, how are you?" |
| BatchTranslation | PASS | 119 ms | 4 frases traducidas correctamente en batch |
| TranslationLatency | PASS | 12.1 ms avg | Min: 10.1ms, Max: 15.3ms (5 iteraciones) |
| LanguageAvailability | PASS | 5.1 ms | 2 instalados, 10 soportados de 10 pares |

*\*La primera traduccion incluye inicializacion del modelo y descarga de idioma (one-time). Las siguientes son ~12ms.*

### Metricas clave para TranslateCall

- **Latencia de traduccion (steady-state):** ~12ms por frase
- **Latencia batch:** ~30ms por frase (4 frases en 119ms)
- **Budget de latencia del proyecto:** <600ms --> **Cumple con margen**
- **Idiomas ES-EN:** Funcionan correctamente una vez descargados
- **10 pares de idiomas soportados** (requieren descarga individual)

### Implicaciones para la arquitectura

1. **TranslationBridge necesario:** La app final debe incluir un componente SwiftUI oculto (`TranslationBridge`) que mantenga la sesion de `.translationTask()` activa.
2. **Gestion de idiomas:** El usuario debera descargar los pares de idiomas la primera vez. Se puede guiar con `LanguageAvailability.status()` y `session.prepareTranslation()`.
3. **Firma de codigo:** La app debe estar firmada con un certificado de desarrollo valido (no ad-hoc) para que el framework reconozca los idiomas instalados.

### Codigo de referencia

```
PoC1_Translation/main.swift
```

La estructura clave es:
```swift
// SwiftUI view con .translationTask() que proporciona la sesion
struct TranslationTestView: View {
    @State private var configuration: TranslationSession.Configuration?
    var body: some View {
        Text("...")
            .translationTask(configuration) { session in
                // session.translate() funciona aqui
            }
            .onAppear {
                configuration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "es"),
                    target: Locale.Language(identifier: "en")
                )
            }
    }
}

// NSApplication minima que hospeda la view
let app = NSApplication.shared
app.setActivationPolicy(.regular)
// ... NSHostingView(rootView: TranslationTestView())
```

---

## PoC 2: Voice Activity Detection (VAD)

**Objetivo:** Validar deteccion de actividad vocal basada en energia (FFT) con latencias aceptables para procesamiento en tiempo real.

**Nota:** Este PoC valida VAD basado en energia. El MVP usara FluidAudio Silero VAD (mas preciso), pero esta implementacion sirve como fallback.

### Resultados

| Test | Estado | Latencia | Detalle |
|------|--------|----------|---------|
| BasicEnergyDetection | PASS | 21.3 ms | Voz: -20.3 dB, Silencio: -200.0 dB, Delta: 179.7 dB |
| MixedSequenceDetection | PASS | 7.2 ms | Deteccion en t=1.00s, esperado 1.0s (error: 0.00s) |
| DetectionLatency | PASS | 0.001 ms | 100 iteraciones, max: 0.002ms |
| FrequencyVariation | PASS | 8.4 ms | 100-300Hz: todas detectadas |

### Metricas clave para TranslateCall

- **Latencia de deteccion:** <0.01ms (procesamiento del buffer)
- **Budget de latencia del proyecto:** <100ms --> **Cumple con margen enorme**
- **Precision:** 100% en datos sinteticos (con audio real dependera del threshold)
- **Rango de frecuencias:** 100-300Hz cubierto (rango tipico de voz humana)

### Implicaciones para la arquitectura

1. **VAD basado en energia es viable como fallback** si FluidAudio Silero no esta disponible.
2. **Threshold ajustable:** El umbral de deteccion necesitara calibracion con audio real del microfono.
3. **Listo para integracion** con `AudioManager` via buffers de AVAudioEngine.

---

## PoC 3: Voice Cloning DSP

**Objetivo:** Evaluar si las tecnicas DSP basicas (pitch shifting, time stretching, formant shaping) producen calidad suficiente para voice cloning en el MVP.

**Resultado:** NO-GO para MVP. La calidad DSP no alcanza el minimo aceptable.

### Resultados

| Test | Estado | Calidad | Detalle |
|------|--------|---------|---------|
| ProfileExtraction | PASS | N/A | Pitch error: 0.1% (extraccion precisa) |
| PitchShifting | PASS | N/A | Pitch error: 5.0% (aceptable) |
| FullDSPPipeline | PASS | 2.5/5 | Pipeline funciona pero calidad baja |
| QualityMetrics | PASS | 3.2/5 | Score promedio: 64.6% |

### Metricas detalladas

| Metrica | Valor | Objetivo MVP | Objetivo Phase 2 |
|---------|-------|-------------|------------------|
| Pitch accuracy | 85% | >80% | >95% |
| Rate accuracy | 78% | >80% | >90% |
| Timbre preservation | 45% | >60% | >80% |
| Naturalness | 60% | >70% | >85% |
| Overall similarity | 55% | >60% | >80% |
| **Promedio** | **64.6%** | **>70%** | **>85%** |

### Decision

- **MVP (Phase 1):** Usar voces Premium de AVSpeechSynthesizer sin clonacion. La voz traducida sonara diferente al usuario pero sera clara y natural.
- **Phase 2 (Meses 7-9):** Implementar voice cloning neural con MLX-Audio CSM-1B, que promete >80% de similitud con solo 30 segundos de muestra de voz.

### Implicaciones para la arquitectura

1. **VoiceProfileManager** se mantiene en la arquitectura pero se activa en Phase 2.
2. **DSPVoiceStyleTransfer** puede usarse para ajustes menores (pitch/rate) sobre voces TTS Premium.
3. **No bloquea el MVP:** La traduccion funciona sin voice cloning.

---

## PoC 4: BlackHole Integration

**Objetivo:** Validar la integracion con BlackHole como driver de audio virtual para routing entre TranslateCall y apps de videollamadas.

### Resultados

| Test | Estado | Detalle |
|------|--------|---------|
| BlackHoleDetection | PASS | BlackHole 2ch detectado (ID: 91, Input+Output) |
| InstallationMethod | PASS | Instalado via Homebrew (blackhole-2ch) |
| DeviceEnumeration | PASS | 6 dispositivos (3 input, 4 output) |
| VirtualDeviceConfiguration | PASS | 48000 Hz, 2 canales, input+output |
| AudioRoutingSimulation | PASS | Arquitectura de routing validada |

### Dispositivos detectados

| Dispositivo | Tipo | Detalle |
|-------------|------|---------|
| Microfono de "SpBarber" | Input | Microfono fisico (Bluetooth) |
| BlackHole 2ch | Input/Output | 48000 Hz, 2 canales - **virtual driver** |
| EShareAudio | Input/Output | Dispositivo de pantalla compartida |
| U34E2M | Output | Monitor AOC |
| Altavoces del Mac mini | Output | Speakers integrados |

### Flujo de audio validado

```
Microfono fisico (SpBarber / EShareAudio)
    |
    v
TranslateCall (VAD -> STT -> Translation -> TTS)
    |
    v
BlackHole 2ch (virtual output) - 48kHz, stereo
    |
    v
Zoom / Teams / Meet (usa BlackHole como microfono)
```

### Configuracion de BlackHole

- **Sample Rate:** 48000 Hz (compatible con el budget de TranslateCall)
- **Canales:** 2 (stereo)
- **Funciona como:** Input y Output simultaneamente (loopback virtual)
- **Instalacion:** `brew install blackhole-2ch`

### Implicaciones para la arquitectura

1. **BlackHole funciona correctamente** como puente de audio virtual.
2. **Onboarding necesario:** La app debera guiar al usuario para instalar BlackHole y configurar el audio en su app de videollamadas.
3. **Deteccion automatica:** El test demuestra que se puede detectar BlackHole por nombre de dispositivo, util para el wizard de configuracion de la app.
4. **Alternativas si BlackHole falla:** Investigar otros drivers virtuales (Soundflower, Loopback de Rogue Amoeba).

---

## PoC 5: Half-Duplex Echo Management

**Objetivo:** Validar que el modo half-duplex (mutear microfono durante TTS) previene eco y feedback efectivamente.

### Resultados

| Test | Estado | Latencia | Detalle |
|------|--------|----------|---------|
| StateMachineTransitions | PASS | 639 ms total | listening->speaking: 314.6ms, speaking->listening: 319.6ms |
| MicrophoneMuting | PASS | 301.1 ms | Mic muteado correctamente durante speaking |
| EchoPrevention | PASS | N/A | Sin HD: feedback detectado. Con HD: sin feedback |
| TransitionTiming | PASS | 315.3 ms avg | Dentro del rango 300ms +/-50ms |
| ConcurrentTransitions | PASS | 311.3 ms | Estado final correcto (listening) |
| VisualIndicator | PASS | N/A | 3 estados visuales definidos |

### Metricas clave para TranslateCall

- **Latencia de transicion:** ~315ms (buffer de seguridad de 300ms + overhead)
- **Prevencion de eco:** 100% efectiva en simulacion
- **Concurrencia:** Maneja transiciones simultaneas correctamente
- **Estados:** listening (mic on), speaking (mic muted), transitioning (buffer)

### Indicador visual para el usuario

| Estado | Color | Icono | Significado |
|--------|-------|-------|-------------|
| Listening | Verde | Microfono | Mic activo, escuchando al usuario |
| Speaking | Rojo | Muted | Mic muteado, reproduciendo traduccion |
| Transitioning | Amarillo | Reloj | Transicion entre estados (300ms buffer) |

### Implicaciones para la arquitectura

1. **HalfDuplexManager listo para produccion.** La maquina de estados es simple y robusta.
2. **Buffer de 300ms es adecuado** para evitar eco sin introducir delay perceptible.
3. **Indicador visual critico** para UX: el usuario debe saber cuando puede hablar.

---

## Conclusiones Generales

### Arquitectura validada

El pipeline core de TranslateCall es viable:

```
Mic -> VAD (PoC2: ~0.01ms) -> STT -> Translation (PoC1: ~12ms) -> TTS -> Half-Duplex (PoC5: ~315ms) -> BlackHole (PoC4: pendiente) -> Zoom/Teams
```

### Budget de latencia estimado

| Componente | Medido | Budget | Estado |
|------------|--------|--------|--------|
| VAD | 0.01ms | <100ms | OK |
| STT (Apple Speech) | No medido* | <800ms | Pendiente |
| Translation | 12ms | <600ms | OK |
| TTS (AVSpeech) | No medido* | <600ms | Pendiente |
| Half-Duplex transition | 315ms | <400ms | OK |
| **Total estimado** | **~327ms + STT + TTS** | **<2500ms** | **Viable** |

*\*STT y TTS se validaran en Milestone 2 con FluidAudio y AVSpeechSynthesizer respectivamente.*

### Decisiones tomadas

| Decision | Justificacion |
|----------|--------------|
| Usar `.translationTask()` con SwiftUI oculto | Unica forma de acceder a modelos de traduccion desde la app |
| Diferir voice cloning a Phase 2 | Calidad DSP insuficiente (64.6% vs 70% minimo). MLX-Audio CSM-1B en Phase 2 |
| Usar Premium TTS voices para MVP | Alternativa practica mientras voice cloning no esta disponible |
| Half-duplex con buffer 300ms | Previene eco efectivamente con latencia aceptable |
| Firma de codigo con Apple Development | Requerida para que Translation framework reconozca idiomas instalados |

### Riesgos identificados

| Riesgo | Probabilidad | Impacto | Mitigacion |
|--------|-------------|---------|------------|
| BlackHole no funciona correctamente | Baja | Alto | Alternativas: Loopback, Soundflower |
| STT latencia > 800ms | Media | Alto | FluidAudio Parakeet como alternativa |
| Translation API cambia en futuras versiones macOS | Baja | Medio | Monitorear WWDC, mantener abstraccion |
| Usuarios no quieren instalar BlackHole | Media | Alto | Wizard de instalacion, documentacion clara |

### Proximos pasos (Milestone 1)

1. **Instalar BlackHole** y completar PoC4
2. **Crear proyecto Xcode principal** (TranslateCall.app)
3. **Implementar AudioManager** con AVAudioEngine
4. **Implementar TranslationBridge** (SwiftUI oculto con `.translationTask()`)
5. **Configurar CI/CD** con GitHub Actions

---

*Documento generado el 31 de enero de 2026*
*Proyecto: TranslateCall - Milestone 0 (Proof of Concepts)*
