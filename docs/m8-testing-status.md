# M8 Testing Status — 2026-03-17

## Resumen

M8 (Full Language Coverage) implementado. El core funcional está listo pero hay dos bloqueantes para testing end-to-end completo.

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

### 2. No se puede escuchar TTS durante testing local
**Problema**: El outgoing TTS está diseñado para rutear audio a **BlackHole** (para que el participante remoto lo oiga en Zoom/Teams). Sin BlackHole o sin una llamada activa, el audio no se reproduce por los altavoces locales.

**El usuario NUNCA ha escuchado TTS en el pipeline de traducción** — solo en la preview de voz (VoicePreviewService, que tiene su propio AVAudioEngine ruteado a altavoces).

**Soluciones propuestas**:
1. **Monitor local**: Opción para duplicar el audio TTS a los altavoces locales además de BlackHole (como "monitor" en DAWs). Toggle en la UI.
2. **Test mode**: Modo de prueba sin BlackHole donde el TTS va directo a altavoces. Para development/testing.
3. **Grabación + playback**: Grabar el audio TTS a un archivo y reproducirlo después para verificar.

## Plan para mañana

### Prioridad 1: Hacer TTS audible para testing
- Implementar "monitor local" o "test mode" para escuchar TTS por altavoces
- Esto desbloquea TODO el testing de TTS (AVSpeech, Voice Clone, y futuro Edge TTS)

### Prioridad 2: Edge TTS WebSocket
- Añadir Starscream SPM dependency
- Reescribir `EdgeTTSWebSocket` usando Starscream
- Verificar que el audio ucraniano se reproduce

### Prioridad 3: Calidad Whisper
- El modelo `base` a veces tiene confianza baja (~0.43) para audio casual
- Evaluar modelo `small` (500 MB, mejor calidad)
- Considerar ajustar `minimumConfidence` threshold para Whisper (puede ser menor que para Apple Speech)

### Prioridad 4: Tests
- Ejecutar los 38 tests escritos (21 Whisper + 17 Edge TTS)
- Verificar que tests pre-existentes siguen pasando

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
