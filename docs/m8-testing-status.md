# M8 Testing Status — 2026-03-23 (updated)

## Resumen

M8 (Full Language Coverage) implementado. Pipeline end-to-end **verificado**: ES→EN funciona con STT + Translation + TTS + Monitor local.

## Lo que funciona ✅

### F8.1 — WhisperKit STT
- **99+ idiomas** on-device via CoreML + ANE
- Probado con español → transcripción correcta
- Latencia media: **133ms** (modelo `base`)
- Confianza media: **0.69-0.78**
- Auto-carga al relanzar si fue la preferencia anterior
- UI: picker de engine, fallback badge, download sheet con selector de tamaño de modelo

### F8.3 — Translation Engine Abstraction
- `TranslationEngineSelector` funciona, `AppContainer` rewired
- Preparado para futuros backends (Opus-MT, LibreTranslate)

### Traducción ES→UK / EN→UK
- Apple Translation funciona perfectamente
- "Hola familia ¿qué tal estáis?" → "Привіт, сім'я, як справи?"
- "Hello my name is Santiago and I go to bed" → "Привіт, мене звати Сантьяго, і я іду спати."

### UI / UX
- Language pickers reactivos (fix @EnvironmentObject)
- STT/TTS engine selectors reactivos (fix @EnvironmentObject)
- Edge TTS consent dialog funciona
- Métricas: columnas Whisper y Edge TTS añadidas
- Cloud badge cuando Edge TTS está activo

## Bloqueantes 🔴

### 1. Edge TTS WebSocket Connection

> **Update 2026-10-03:** migrated to Starscream 4.0.8 in `d685654` (2026-04-11). End-to-end
> verification and the playback-completion bug found in the 2026-10-03 audit are tracked in
> M8.5 (`specs/m8.5-stabilization/`).
**Problema**: El servidor de Microsoft (`speech.platform.bing.com`) rechaza el WebSocket handshake desde las APIs nativas de Apple.

**Intentos fallidos**:
1. `URLSessionWebSocketTask` con `URLRequest` headers → Apple filtra el header `Origin`
2. `URLSessionWebSocketTask` con `httpAdditionalHeaders` en config → misma limitación
3. `NWConnection` con `NWProtocolWebSocket.Options.setAdditionalHeaders` → handshake rejected (`nw_ws_validate_server_response`)
4. `NWConnection` con `.tls` (sin WebSocket options) → conecta pero no hay framing WebSocket
5. `NWConnection` con WebSocket options pero sin custom headers → handshake rejected

**Root cause**: Las APIs nativas de Apple no permiten enviar el header `Origin: chrome-extension://...` en WebSocket upgrades, que Microsoft requiere.

**Solución propuesta**: Añadir **Starscream** (MIT, Swift WebSocket library) como dependencia SPM. Permite control total sobre headers WebSocket.

**Alternativa**: Explorar si `TTSKit` (incluido en WhisperKit package) soporta ucraniano o más idiomas que nuestro Qwen3-TTS actual.

### 2. ~~No se puede escuchar TTS durante testing local~~ RESUELTO 2026-03-23
**Estado**: RESUELTO. TTSAudioMonitor funciona correctamente.

**Fixes aplicados**:
1. **`ttsMonitor.isEnabled` nunca se seteaba** — `enableTTSMonitor()` seteaba `ttsMonitorEnabled` (UI) pero no `ttsMonitor.isEnabled` (guard en `process()`)
2. **Channel mismatch crash** — `playerNode→mixer` con `format:nil` resolvía a stereo, pero AVSpeechSynthesizer produce mono. Fix: reconexión lazy con formato del primer buffer, tanto en `AVSpeechService` como en `TTSAudioMonitor`
3. **Recording file format mismatch** — archivo WAV se creaba con formato del output node (stereo) pero recibía buffers mono. Fix: creación lazy del archivo en `process()` con el formato del primer buffer
4. **AsyncStream single-iterator bug** — `audioStream16kHz` era `lazy var` creado una vez; tras stop/start el nuevo VAD iteraba un stream consumido. Fix: `recreateStreams()` en cada `startCapture()`, `finish()` de continuations en `stopCapture()`
5. **Monitor engine invalidation** — tras stop/start, el engine del monitor podía quedar inválido. Fix: auto-restart en `process()` si `!engine.isRunning`

## Próximos pasos

### Prioridad 1: Edge TTS WebSocket
- Añadir **Starscream** SPM dependency (MIT, Swift WebSocket library)
- Reescribir `EdgeTTSWebSocket` usando Starscream (control total sobre headers)
- Verificar que el audio ucraniano se reproduce
- Esto desbloquea cobertura de 100+ idiomas para TTS

### Prioridad 2: Calidad Whisper STT
- El modelo `base` a veces tiene confianza baja (~0.43) para audio casual
- Evaluar modelo `small` (500 MB, mejor calidad)
- Considerar bajar `minimumConfidence` threshold para Whisper (0.60 → 0.40-0.50)
- Apple Speech con `minimumConfidence=0.60` funciona bien para español claro

### Prioridad 3: Tests
- Ejecutar los 38 tests escritos (21 Whisper + 17 Edge TTS)
- Verificar que tests pre-existentes siguen pasando

### Prioridad 4: Audio overload mitigation
- `HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload` aparece con 3 engines simultáneos
- Evaluar si se puede compartir el engine del monitor con el TTS service
- O reducir buffer sizes / sample rates para aliviar carga

## Bugs menores detectados
- "Picker: the selection nil is invalid" — aparece al iniciar antes de cargar idiomas (cosmético)
- "Publishing changes from within view updates is not allowed" — al cambiar STT engine desde el picker
- Badge "Cloud" se muestra incluso cuando Edge TTS no está activo (stale `currentTargetLocale`)
- Los controles se deshabilitan durante captura pero el cambio de engine requiere relanzar

## Commits de M8 (esta sesión)
```
60d069c Fix BUG-1 (EN→UK translation) + cleanup ~65 warnings
258aacb Eliminate remaining build warnings
04fafab Fix remaining 6 compiler warnings
3adc227 F8.3 — Translation engine abstraction
d4d0b70 F8.1 — WhisperKit STT core (T0-T4)
1d3b822 F8.1 — Whisper UI (T5)
d116396 F8.2 — Edge TTS fallback
7ac9512 F8.1/F8.2 tests (38 tests)
39605e1 Whisper auto-load on relaunch
94d3d58 Fix consent trigger + metrics panels
3b67f33 Force re-render for Whisper state
9019f35 Fix blank language pickers (@EnvironmentObject)
e2433d2 Inject STT/TTS selectors as @EnvironmentObject
2a87c0b Fix consent: proactive check before start
e42e3eb Fix consent: check language pair directly
a1669f8 Fix hasVoice: exact language code match
a34f4be Fix Edge TTS: honor manual selection + premium voice filter
d055d65 Fix consent: dialog before pipeline start
1e33038 Update Edge TTS headers
8295e35 Try URLSessionConfiguration headers
cf16ef4 Simplify NWConnection WebSocket
bf8eeb8 Add WebSocket protocol options
9c5f388 Rewrite with NWConnection
0c84555 Revert hasVoice premium filter
b20133e Fix AVSpeech: revert async scheduleBuffer
65c5a07 Bump version to 0.8.0
```

## Arquitectura M8 final
```
STT: Apple Speech ← Parakeet (EN) ← Whisper (99+ langs) [NEW]
     ↕ STTEngineSelector routes by preference + locale

Translation: Apple Translation (via TranslationEngineSelector) [REFACTORED]
     ↕ Pluggable for future backends

TTS: AVSpeech (all) ← Kokoro (EN) ← Voice Clone (10 langs) ← Edge TTS (100+ langs) [NEW]
     ↕ TTSEngineSelector with automatic fallback chain
     ↕ Edge TTS needs Starscream for WebSocket (BLOCKED)
```
