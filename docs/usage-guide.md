# Guía de uso de TranslateCall

TranslateCall traduce una videollamada en los dos sentidos, como un intérprete simultáneo:
tú hablas en tu idioma y el otro te oye en el suyo; el otro habla en el suyo y tú le oyes en el tuyo.

## 1. Usa auriculares

Con auriculares, el micrófono no oye la voz traducida del otro, así que **los dos sentidos están
siempre activos** y no se pierde ninguna frase: puedes hablar aunque esté sonando una traducción.

Si tienes que usar los altavoces del Mac, activa **«I use speakers»** en la ventana principal
(sección 4).

## 2. Haz una pausa para enviar cada frase

TranslateCall traduce frase a frase. Una frase termina cuando haces una **pausa clara**: en ese momento
se traduce y se oye en el otro idioma.

- Habla con normalidad y haz una pausa breve al final de cada frase, como al dictar.
- Las pausas cortas dentro de una frase (respirar, dudar) no la cortan.
- Si hablas sin pausas durante más de 14 s, la frase se envía igualmente.
- Si dices varias frases seguidas mientras aún suena una traducción, se juntan y se dicen de una vez
  para recuperar el retraso. Nunca se descarta ninguna. Si el retraso llega a 20 frases, aparece el
  aviso «Translation running behind».

## 3. «Pause to translate»: cuánto dura la pausa que envía una frase

En la ventana principal, el control **«Pause to translate»** (de 0,4 s a 1,2 s; por defecto 0,6 s)
fija cuánto silencio cierra una frase:

- **Más corto** (0,4–0,5 s): la traducción empieza antes, pero una pausa a mitad de frase puede
  partirla en dos.
- **Más largo** (0,8–1,2 s): las frases largas no se parten, pero la traducción tarda más en empezar.

El cambio se aplica **en la siguiente sesión** (Stop → Start). El detector de voz (Silero) analiza
el audio en bloques de unos 0,25 s, así que la pausa real puede variar en ese margen.
La etiqueta «VAD» indica qué detector está activo: **Silero** (el normal) o **Energy**
(el de respaldo, si el modelo de Silero aún no está disponible). Antes de la primera sesión muestra «VAD: —».

## 4. «I use speakers»: altavoces en lugar de auriculares

Con los altavoces, el micrófono oye la traducción del otro y la volvería a traducir (eco).
Con **«I use speakers»** activado, TranslateCall **pone el micrófono en pausa mientras suena la
traducción del otro** (y 0,3 s después). El estado muestra **«Mic paused (speakers)»**.

Mientras el micrófono está en pausa, lo que digas **no se envía**: espera a que termine la traducción.
Por eso recomendamos auriculares. El ajuste se aplica al momento, también en mitad de una sesión.

## 5. Probar la voz traducida tú solo

No hace falta otra persona para comprobar que todo suena. Prepara primero el audio:

1. En Ajustes del Sistema → Sonido → Salida, elige los altavoces del Mac.
2. En la ventana de la app, en **«Microphone»**, elige el micrófono de tus auriculares.
3. Activa **«Monitor»**: la voz traducida que se envía a la llamada también suena en la salida del sistema.
4. Activa **«I use speakers»**: la traducción **entrante** sale por los altavoces y podría colarse en el
   micrófono; con este ajuste la app lo pone en pausa mientras suena y no se forma un bucle de eco.
   (La traducción saliente que oyes por Monitor no pausa el micrófono; con el micrófono de los
   auriculares es muy poco probable que se cuele.)

**Tu voz traducida (sentido saliente):**

1. Pulsa Start, habla y haz una pausa: oirás tu frase en el otro idioma por los altavoces (gracias a Monitor).

**La voz traducida del otro (sentido entrante):**

1. Cierra Zoom, Teams, Meet y Discord (cualquier app de llamada) antes de abrir TranslateCall; si ya
   estaba abierta, ciérrala y vuelve a abrirla. Si hay una app de llamada abierta, «Capture» solo
   lista esas apps y el navegador no aparece; la lista no se actualiza mientras TranslateCall sigue abierta.
   Después, en **«Capture»**, elige Safari o Chrome.
2. Reproduce en el navegador un vídeo o audio de alguien hablando en el idioma del otro.
3. Pulsa Start: oirás la traducción en tu idioma por los altavoces.

Mientras suena la traducción entrante, el micrófono está en pausa («Mic paused (speakers)»): es lo esperado.

## 6. Problemas frecuentes

| Qué pasa | Qué hacer |
|----------|-----------|
| Las frases se cortan a mitad | Sube «Pause to translate» (por ejemplo, a 0,8 s) y reinicia la sesión. |
| La traducción tarda en empezar | Baja «Pause to translate» (por ejemplo, a 0,5 s) y reinicia la sesión. |
| El otro oye su propia frase traducida de vuelta | Usa auriculares o activa «I use speakers». |
| «Mic paused (speakers)» y no te oyen | Espera a que termine la traducción del otro, o usa auriculares y desactiva «I use speakers». |
| «VAD: Energy» | El modelo de Silero no estaba listo; la siguiente sesión lo vuelve a intentar. Funciona igual, pero distingue peor la voz del ruido. |
