# PlaybackKit — notas (fase 1, 15-oct-2026; fase 3, 16-oct-2026)

Motor de reproducción de Glasstube (reimplementación de SmartTube para macOS). Mac de prueba: Apple M1 Pro, macOS
27.0.1, Swift 6.4 con solo Command Line Tools (sin Xcode). Solo videos públicos, sin cuentas.

```bash
Scripts/fetch-libmpv.sh && Scripts/link-libmpv.sh   # una vez: crea Vendor/Libmpv.xcframework
swift build
swift test                                          # 6 pruebas de la lógica del motor (desde la fase 3)
.build/debug/PlaybackDemo aqz-KE-bpKQ               # ventana: espacio pausa, ← → ±10 s, ↑ +60 s, - y = calidad
```

Lo de la fase 3 (robustez, PiP del sistema, pruebas) está en [Fase 3](#fase-3-robustez-y-pip-16-oct-2026).

## Qué hay

| Producto | Qué es |
|---|---|
| `PlaybackKit` | Protocolo `PlayerEngine` y sus tipos; `MPVEngine` (libmpv); `AVEngine` (AVPlayer, directos HLS); `PlayerVideoView` (SwiftUI); `StreamedMediaSource` (contrato de las fuentes propias, como SABR) |
| `YouTubeSource` | `SabrMediaSource` (SABR del cliente TV con su PoToken, por `mpv_stream_cb`) y `YouTubeLive.hlsManifest` (HLS de un directo por VISIONOS), sobre glasstube/YTKit (dependencia local, ver abajo) |
| `PlaybackDemo` | Ventana mínima (AppKit + SwiftUI, sin diseño) que reproduce un `videoId` público con `MPVEngine`; con `--seek-at`, `--switch-at`, `--stop-at`… corre sola y deja un reporte |

Opciones de la demo: `--renderer metal|opengl`, `--max-height N`, `--start S`, `--seek-at A:B,…`,
`--switch-at T:ALTURA|T:+|T:-,…`, `--fault-at T:403|403+|403pot|cdn|net|stall,…`, `--keys-at T:space|left|right|up|-|=,…`,
`--resize-at T:ANCHOxALTO,…`, `--stop-at S`, `--max-wall S`, `--url-ttl S`, `--potoken-ttl S`, `--hwdec VALOR`,
`--shots DIR`, `--log-sabr`, `--verbose`, `--on-top`, `--report ARCHIVO` y `--live` (directo por `AVEngine`). Desde la
fase 3: `--cover S`, `--hide S` y `--minimize S` (la ventana tapada por otra opaca, la app oculta o la ventana
minimizada desde el arranque, con la oclusión en la bitácora), `--fill` (la vista del video llena la ventana en lugar de
quedar en 16:9), `--window-file ARCHIVO` (número de ventana para `screencapture -l`) y `--resize-probe
"prop=valor;…"` (propiedades de mpv que se fijan tras cada `--resize-at`).

### `PlayerEngine`

Todo en el actor principal. `load(_:)`, `play()`, `pause()`, `togglePause()`, `seek(to:mode:)` (`.exact` o
`.keyframe`; vuelve cuando la imagen ya está en la posición), `seek(by:)`, `setRate`, `setVolume` (0…1), `setMuted`,
`select(track:)` (video = calidad, audio, subtítulos), `disableSubtitles()`, `addSubtitle(url:language:title:)`,
`stop()`, `shutdown()`.

- **Estado** en `status` (`PlayerStatus`, `@Observable`): estado, posición, duración, velocidad, volumen, búfer, pistas
  de video/audio/subtítulos, decodificador por hardware, cuadros descartados.
- **Eventos** con `events()`: un `AsyncStream<PlayerEvent>` nuevo por suscriptor (`.state`, `.time` ~4/s, `.buffer`,
  `.tracks`, `.seekCompleted`, `.error`, `.note`). Así cada controlador (SponsorBlock, VideoState, Suggestions…)
  escucha por su cuenta y actúa con la misma API, sin saber qué motor hay debajo.
- **Fuentes** (`PlaybackItem.source`): `.url(video, audio:, headers:)` (archivo, HLS o DASH con URL directa) o
  `.streamed(StreamedMediaSource)` (bytes propios; solo `MPVEngine`).
- Una búsqueda o un cambio de pista que llega durante otra carga espera su turno (hasta 15 s) en lugar de perderse.

### `MPVEngine`

- **Salida Metal** (predeterminada, `MPVRenderer.metal`): `vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=moltenvk` y
  `wid` = el puntero a un `CAMetalLayer` propio (`MPVMetalView`). Es el contexto que añade el parche
  `0001-player-add-moltenvk-context.patch` de MPVKit; mpv crea su swapchain de Vulkan sobre la capa y presenta desde su
  hilo de VO, y MoltenVK lo traduce a Metal. La vista solo mantiene `drawableSize` al día.
  - **Por qué no la API de render:** la API de render de libmpv (`render.h` de 0.41) solo ofrece OpenGL y software;
    no hay Metal ni Vulkan. Para Metal, mpv dibuja directo en la capa.
- **Respaldo OpenGL** (`MPVRenderer.openGL`, documentado y elegible en `MPVEngine.Configuration`): `vo=libmpv` con la
  API de render de OpenGL en un `CAOpenGLLayer`, como la fase 0 (`MPVOpenGLView`, port de `MPVVideoLayer`). OpenGL
  está obsoleto en macOS, pero funciona y da control cuadro a cuadro.
- **Decodificación por hardware:** `hwdec=videotoolbox,auto-safe` (VideoToolbox primero y, si no puede, la lista de
  `auto-safe`). Con `auto-safe` a secas y la salida Vulkan, mpv prueba primero el decodificador Vulkan Video de FFmpeg,
  que MoltenVK no tiene (`VK_KHR_video_decode_queue`): falla, deja errores de referencias en los primeros paquetes y
  luego cae en VideoToolbox. Se puede cambiar en `Configuration.hwdec`.
- **SABR por `mpv_stream_cb`:** es el código de `sabrplay` del spike movido a un motor: dos flujos
  `glasstube://<id>/{video,audio}?g=N` sin `seek_fn` ni `size_fn`, búferes bloqueantes (`StreamBuffer`), el reloj de la
  fuente (`PlaybackClock`) alimentado por `time-pos` desde el hilo de eventos, `audio-files` como lista NODE, y el
  arreglo del crash de `cancel_fn` tras `close_fn` (los búferes cerrados se sueltan 10 s después).
  - **Búsqueda:** dentro de la caché del demuxer, `seek` de mpv; fuera, otra carga desde T (generación nueva). mpv
    arranca al inicio del segmento que contiene T; el motor espera en pausa a que la caché llegue a T, hace el seek
    exacto y reanuda («llegada», como `--hold-exact` del spike).
  - **Retención de la imagen:** mientras tanto se sigue viendo el último cuadro anterior a la carga. En Metal mpv
    presenta directo en la capa, así que no hay FBO propio que congelar: antes del `loadfile` se pide el cuadro actual
    con `screenshot-raw video` (con gpu-next lo dibuja la VO, también con VideoToolbox) y se muestra en una subcapa
    encima hasta llegar a T. En OpenGL, los dos FBO del spike.
  - **Cambio de calidad:** `select(track:)` con una pista de `status.videoTracks` (`itag:N`): otra carga en la posición
    actual con el formato nuevo (`SabrSession.switchFormat`).
  - **Renovación de URL y PoToken, 403 y CDN caída:** los hace `SabrSession` (copiada del spike tal cual), dentro de la
    tarea de streaming; el motor recibe sus hechos como `.note`. Si la sesión se rinde, mpv agota lo que tiene y el
    estado pasa a `.failed`.
- `keep-open=yes`: al final se queda en el último cuadro (`.ended`). `load-scripts=no`, `config=no`, `ytdl=no`.
- Sin scripts internos de mpv (18-oct-2026): `load-stats-overlay`, `load-console`, `load-auto-profiles`, `load-select`,
  `load-commands`, `load-positioning` y `load-context-menu` en `no` (`load-scripts=no` solo apaga la carpeta de scripts).
  Así no se crea ningún estado de Lua. Con hardened runtime (versiones notarizadas), el LuaJIT de libmpv ejecutaba
  memoria sin firmar al cargarlos y macOS mataba la app al abrir el primer video (SIGKILL, «Code Signature Invalid»,
  pila en `load_builtin` → `load_scripts` → `script_thread`). Ver App/NOTAS.md, «Distribución».

### `AVEngine`

AVPlayer con un `AVPlayerLayer`, para directos HLS (o cualquier URL que AVFoundation abra). Pistas de video: «Auto» y
las variantes del manifiesto maestro; elegir una fija `preferredMaximumResolution` y `preferredPeakBitRate` (AVPlayer
no deja elegir una variante exacta). Audio y subtítulos por `AVMediaSelectionGroup`. No admite `.streamed` ni
subtítulos externos.

## libmpv: origen, licencia y enlace

### Origen exacto

Binarios publicados por **MPVKit 1.1.0-n9.0.2** (github.com/mpvkit/MPVKit, etiqueta en el commit
`98c3453e252922e3136422da3fbb2e341ed9edc8`, release del 7-oct-2026 subida por `github-actions[bot]`: se compilan en
GitHub Actions con los scripts públicos de `Sources/BuildScripts`). Versiones: mpv v0.41.0 (con los parches de MPVKit,
por eso `mpv v0.41.0-dirty`), FFmpeg n9.0.2, libplacebo 7.360.1, MoltenVK 1.4.2, libass 0.17.5, dav1d 1.5.3,
OpenSSL 3.3.5, GnuTLS 3.8.11 y las demás de la lista. Se descargaron **solo las variantes LGPL** (sin `-GPL` y sin
Libsmbclient, que es GPL): 29 zips, 350 MB.

- `Scripts/libmpv-sources.txt`: nombre, SHA-256 y URL de cada zip, copiados del `Package.swift` de MPVKit en esa
  etiqueta (es el `checksum` que SwiftPM verifica). Coinciden con el `digest` que GitHub da para cada archivo de la
  release.
- `Scripts/fetch-libmpv.sh` descarga, **verifica cada SHA-256** (borra el archivo si no coincide) y extrae la rebanada
  de macOS de cada uno en su propio directorio (`Vendor/extracted/<nombre>/`).

### Licencia verificada

- **mpv:** la cadena de configuración dentro del binario (también la propiedad `mpv-configuration` en ejecución)
  dice `-Dgpl=false`. Con eso mpv es LGPL-2.1-o-posterior.
- **FFmpeg:** la configuración embebida trae `--enable-version3` y no trae `--enable-gpl` ni `--enable-nonfree`;
  `libavcodec` dice `libavcodec license: LGPL version 3 or later`.
- **Resto** (todo compatible con LGPLv3): libplacebo LGPL-2.1+, libass ISC, FreeType FTL, FriBidi LGPL-2.1+,
  HarfBuzz MIT, libunibreak zlib, MoltenVK Apache-2.0, shaderc Apache-2.0, Little-CMS MIT, libdovi MIT, dav1d BSD-2,
  uavs3d BSD-3, uchardet MPL-1.1/LGPL-2.1+, LuaJIT MIT, libbluray LGPL-2.1+, GnuTLS (bibliotecas) LGPL-2.1+,
  Nettle y GMP LGPL-3+/GPL-2+, OpenSSL 3 Apache-2.0. (Comprobado en la metadata de GitHub o en el archivo de licencia
  de cada proyecto, salvo dav1d, libbluray, uchardet, Nettle y GMP, que no están en GitHub: de conocimiento general,
  por confirmar al empaquetar.)
- El conjunto que va en `Libmpv.framework` queda, como obra, bajo **LGPL-3.0-o-posterior** (FFmpeg en versión 3).

### Cómo se enlaza: dinámico

MPVKit publica todo como **bibliotecas estáticas** (frameworks con archivos `ar`). Enlazarlas estáticas en la app la
haría parte de un ejecutable que el usuario no podría reemplazar. Por eso `Scripts/link-libmpv.sh`:

1. Saca la rebanada arm64 de cada biblioteca (`lipo -thin`).
2. Las enlaza en **una sola biblioteca dinámica** con `swiftc -emit-library` (libmpv trae código Swift de cocoa, así que
   hace falta el enlazador de Swift): `-force_load` de `libmpv.a`, el resto solo en lo que haga falta, `-dead_strip` y
   `-exported_symbols_list` con `_mpv_*` (exporta las 54 funciones de la API cliente y nada de FFmpeg).
   Install name `@rpath/Libmpv.framework/Versions/A/Libmpv`, compatibilidad 2.0 (API cliente 2.5), firma ad hoc,
   `minos` 15.0.
   Depende solo de bibliotecas del sistema.
3. Arma `Libmpv.framework` (cabeceras `client.h`, `render.h`, `render_gl.h`, `stream_cb.h`, ISC; module map) y un
   `Vendor/Libmpv.xcframework` escrito a mano (`xcodebuild -create-xcframework` necesita Xcode completo).

`Package.swift` lo usa como `.binaryTarget(name: "Libmpv", path: "Vendor/Libmpv.xcframework")`: el ejecutable lleva
`LC_LOAD_DYLIB @rpath/Libmpv.framework/…` y SwiftPM copia el framework junto a él (`rpath @loader_path`). En la app irá
en `Contents/Frameworks/`. Resultado de esta corrida: 35 MB, SHA-256
`11a08c7abb2857bfc41966241ae42b2e5469f2470026042e2c50a6587009d928`. Es reproducible en este equipo: se borraron
`Vendor/extracted`, `Vendor/work` y el xcframework, se volvieron a correr los dos scripts (los zips ya estaban; se
verificaron otra vez) y salió el mismo hash. Con otra versión de las Command Line Tools podría cambiar; lo que se
garantiza son las entradas.

### Para distribuir

Hecho el 18-oct-2026 (detalle en App/NOTAS.md, «Distribución»): los textos de licencia van en la app y «Acerca de»
menciona mpv y FFmpeg; las notas de cada versión enlazan MPVKit en su commit, mpv y FFmpeg; para reemplazar el
framework se vuelve a firmar la app ad hoc (la firma nueva no lleva hardened runtime), sin
`disable-library-validation`. Lo que se había anotado:

- Incluir los textos de LGPL-2.1, LGPL-3.0 y GPL-3.0 (LGPLv3 se apoya en ella) y los avisos de las demás bibliotecas,
  y mencionar en «Acerca de» que la app usa mpv y FFmpeg bajo LGPL.
- Ofrecer el código fuente exacto: la etiqueta de MPVKit (con sus parches), las fuentes de cada biblioteca y estos dos
  scripts. Con eso cualquiera puede rehacer `Libmpv.framework`.
- **Reemplazar el framework:** la LGPL pide que el usuario pueda cambiar la biblioteca por otra versión. Con
  *hardened runtime* y validación de bibliotecas, macOS no carga un `Libmpv.framework` firmado por otro. Opciones:
  documentar cómo volver a firmar la app ad hoc, o firmar con
  `com.apple.security.cs.disable-library-validation`. No se decidió.
- La licencia de la app no debe prohibir la ingeniería inversa necesaria para depurar esas modificaciones (LGPL-2.1 §6,
  LGPL-3.0 §4).

## Pruebas

Con `PlaybackDemo` (Big Buck Bunny, `aqz-KE-bpKQ`, 634 s; ventana flotante con `--on-top` para que no quede tapada).
Reportes completos en [probes/](probes/).

| Corrida | Resultado |
|---|---|
| **Principal**, Metal: `--shots … --seek-at 310:450 --switch-at 470:720,490:+ --stop-at 520` ([reporte](probes/demo-5min-2026-10-15.txt), [capturas](probes/capturas-5min/)) | **0 → 310,2 s seguidos** (310,2 s de video en 316,1 s de reloj), VP9 1080p60 + AAC 5.1, **VideoToolbox** en todas las muestras reproduciendo (1457 de 1459; en las otras 2 mpv todavía no informaba el decodificador tras una carga). Búsqueda 310 → 450 s **fuera de lo descargado** (la caché llegaba a 326,6 s): retención del cuadro y **en 450,00 s a los 5,0 s**. Cambios de calidad 1080p60 → 720p60 en 470 s (**0,83 s**) y 720p60 → 1080p60 en 490 s (**0,58 s**), cada uno con la resolución pedida según mpv. 0 pausas por falta de datos, 0 cuadros descartados por el decodificador, `vo-delayed-frame-count` 0. Descartados por la VO: 22 en el primer archivo (310 s, con 5 capturas periódicas que cuestan ~2 cada una) y 21 en el último (30 s: 4 junto a dos capturas seguidas y 17 entre 500 y 510 s sin nada en la bitácora) |
| Respaldo **OpenGL**: `--renderer opengl --seek-at 15:200 --switch-at 210:720 --stop-at 225` ([reporte](probes/demo-opengl-2026-10-15.txt)) | Búsqueda fuera de caché en 0,43 s, cambio a 720p en 0,42 s, VideoToolbox, **0 cuadros descartados**, `current-vo libmpv` |
| **Directo** con `AVEngine`: `1-LpQekNa9g --live --max-wall 40` ([reporte](probes/demo-directo-2026-10-15.txt)) | Manifiesto HLS por VISIONOS, 36,8 s seguidos a 720p, sin pausas ni cuadros descartados |
| Directo, calidad: `--switch-at 0:360` ([reporte](probes/demo-directo-calidad-2026-10-15.txt)) | El tope a 360p pasa la variante a 640x360 |
| **Botones de la ventana**: `--keys-at 8:space,9:space,12:right,26:-,34:=,42:up` ([reporte](probes/demo-teclas-2026-10-15.txt)); eventos de teclado por `NSApp.sendEvent`, como una tecla real, que llegan a los `keyboardShortcut` de los botones | Espacio pausa (3 s quieto en 8,0 s) y reanuda; → 12,2 → 22,2 s dentro de la caché; `-` baja a 720p60 (llega en 0,33 s); `=` vuelve a 1080p60 (1,34 s); ↑ 42 → 102 s fuera de lo descargado (0,35 s) |
| Primeras pruebas, Metal: búsquedas 20 → 300 s y 12 → 200 s; cambios a 720p y a 1440p60 | Llegadas en 0,47 y 0,48 s; cambios en 0,33 s (720p) y 1,10 s (1440p, VP9 2560x1440 por VideoToolbox) |

Las corridas de OpenGL y del directo tuvieron, sin querer, otra instancia de la demo reproduciendo en paralelo (la
lancé con `--help` y no la cerré); aun así no perdieron cuadros. La principal fue antes y estuvo sola.

**Sobre la verificación visual:** no hay permiso de grabación de pantalla, así que `screencapture` no pudo capturar la
ventana. Las capturas son `screenshot-raw` de mpv: prueban que la VO dibuja el cuadro correcto (el de T tras una
búsqueda, 1280x720 tras bajar a 720p), no lo que compone la ventana. Que la capa presenta lo dicen MoltenVK (crea la
swapchain sobre la capa con el tamaño de la vista) y los contadores de mpv (cuadros descartados y retrasados). Nadie miró
la ventana durante las corridas.

**La búsqueda de 5,0 s** de la corrida principal es más lenta que las demás (0,4–0,5 s en las otras cuatro y
0,5–1,95 s en el spike). En esa corrida no se registraban las peticiones SABR, así que no se sabe si fue la red; ahora
`--log-sabr` (o `SabrSourceOptions.logRequests`) las anota.

**Resistencia** (Metal, `--log-sabr --url-ttl 60 --potoken-ttl 150 --fault-at 80:403,140:cdn,200:stall,260:403pot
--resize-at 110:960x540,170:1280x720 --stop-at 320`, [reporte](probes/demo-resistencia-2026-10-15.txt)): **0 → 320,1 s
seguidos** (en 320,7 s de reloj), 0 pausas por falta de datos, VideoToolbox. Dentro del motor, la sesión SABR renovó la
URL 6 veces y el PoToken 2 sin cortar, y se recuperó de los 4 fallos provocados (todos son errores reales de red o del
servidor, ver el spike): 403 → player nuevo en 0,5 s; CDN inexistente → reintento y CDN de respaldo en 0,7 s; CDN que
no contesta → 8,2 s sin datos y la de respaldo (quedaban ~10 s por delante); 403 que solo se va con PoToken nuevo →
player, player + PoToken, en 1,6 s. Al cambiar el tamaño de la ventana, MoltenVK recreó la swapchain con el tamaño
nuevo (1688x950 y 2328x1310 píxeles) y la reproducción siguió.

**Cuadros descartados con Metal:** 65 en esos 320 s (0 en el decodificador, `vo-delayed-frame-count` 0), en ráfagas de
7, 30, 8, 8, 1, 1 y 10. No coinciden con los fallos ni con los cambios de tamaño; la de 30 cae junto a una renovación
del player (el solver de `n` en JavaScriptCore). Comparación A/B, 120 s cada una sin
capturas ni fallos ([Metal](probes/demo-ab-metal-2026-10-15.txt), [OpenGL](probes/demo-ab-opengl-2026-10-15.txt)):
**Metal 22** (15 entre 71 y 81 s y 7 entre 91 y 101 s) y **OpenGL 25** (24 en los primeros 10 s y 1 después); la
corrida corta de OpenGL anterior tuvo 0. Las dos salidas tienen ráfagas que cambian de una corrida a otra, así que no
parece un defecto de la salida Metal. El equipo estaba cargado (carga media de 6–8 en 10 núcleos: otra sesión
compilando con `swift-frontend`, una máquina virtual, Chrome, Teams), y es la explicación más probable, sin probar. mpv
no da `display-fps` en ninguna de las dos salidas (`video-sync=audio`): con Metal no sabe la frecuencia de la pantalla
(la del MacBook Pro es variable, ProMotion), y eso queda por revisar junto con `display-resample`.

## Fase 3: robustez y PiP (16-oct-2026)

### El video en negro en 0:00

La app vio una vez, al reanudar un video desde «Seguir viendo», el reproductor en negro y en 0:00 a los 9 s, y la
sospecha era la VO bloqueada con la ventana tapada (Vulkan con FIFO). **No se repitió** en ninguna de estas pruebas:

| Prueba | Resultado |
|---|---|
| Demo, ventana tapada por otra opaca 20 s desde el arranque (`--cover 20`), desde 0 | reproduce a los 3,8 s, avanza tapada (9,3 s a los 13,6) y sigue al destaparla |
| Demo `--cover 18`, `--hide 18` (app oculta) y `--minimize 18`, reanudando en 300 s (carga desde T con retención) | las tres llegan a 300 s en 0,5–0,9 s y avanzan mientras no se ven (309,5–309,9 s a los 12,6–13,1 s) |
| App, `-GTCubrir 15` (ventana tapada) reanudando en 300 s | llegada en 0,62 s, reproduce tapada; al destaparla se ve el video |

Lo que sí se encontró y se corrigió, porque da el mismo síntoma o uno parecido:

1. **Durante la llegada a T la posición pública era la de mpv** (el principio del segmento o 0), y en la primera carga
   no hay cuadro anterior que retener: la app mostraba negro y 0:00 hasta que la caché llegaba a T. Con red lenta o
   un PoToken lento, eso es exactamente «negro en 0:00 durante 9 s». Ahora `status.position` es T mientras la llegada no
   termina (visto: «pos 400.0» en lugar de «pos 0.0» durante la llegada), y la app muestra la miniatura con un
   indicador hasta el primer cuadro.
2. **mpv no se enteraba de los cambios de tamaño de la capa.** El contexto `moltenvk` de MPVKit
   (`0001-player-add-moltenvk-context.patch`) solo lee `drawableSize` al reconfigurar la VO; su `control` devuelve
   `VO_NOTIMPL`. MoltenVK rehace la swapchain con el tamaño nuevo, pero mpv sigue calculando el rectángulo del video
   para el anterior: con la vista en otra proporción (panel lateral de la app, pantalla completa, ventana más angosta)
   la imagen salía **recortada**. La demo no lo mostraba porque fija la vista en 16:9 (con `--fill` sí cambia la
   proporción). Ahora `MPVMetalView` avisa cada cambio de `drawableSize` y `MPVEngine.syncOutputSize` compara lo que mpv
   cree (`osd-width`/`osd-height`) con la capa; si no coincide, fuerza una reconfiguración de la VO cambiando
   `video-aspect-override` un 0,05 % un instante (dos cambios separados por 120 ms: juntos, mpv solo ve el último).
   Visto en la app: «capa 2024x1800; mpv seguía en 2880x1800 → VO reconfigurada: ahora coincide» al abrir el panel, y
   lo mismo al pasar al minirreproductor (896x504) y volver.
3. **`StallWatchdog`**: si mpv debería avanzar (sin pausa, sin carga ni llegada en curso, con ≥ 2 s en caché) y
   `time-pos` no se mueve en 6 s, el motor anota ventana visible o no, tamaño de la capa, `vo-configured`,
   `vo-delayed-frame-count`, `frame-drop-count` y `estimated-vf-fps`, y hace un seek exacto en la misma posición (dos
   veces como máximo por carga). No se disparó en ninguna corrida; queda para que, si vuelve a pasar, la bitácora diga
   qué fue.
4. **PoToken** (en YTKit): BotGuard terminó una vez sin `webPoSignalOutput` y el video no arrancaba; ahora se reintenta
   una vez.
5. Al cargar otro video con el mismo motor, el estado salía un instante con la posición del anterior (llegaba un
   `time-pos` viejo antes del `loadfile`): el filtro de `time-pos` (`TimeGate`) ahora se cierra al empezar `load`.

### Otras piezas

- **`PlayerVideoView(engine:isActive:)`**: una vista de AppKit solo puede estar en un lugar. Con dos superficies del
  mismo motor a la vez (la ventana y el minirreproductor de la app), la que se iba se la quitaba a la nueva en su última
  actualización y el minirreproductor quedaba en negro; ahora solo la activa la toma.
- **PiP del sistema con `AVEngine`** (`PictureInPicture`, AVKit): `engine.makePictureInPicture()` sobre su
  `AVPlayerLayer`, con `onRestore` y `onStop`. Probado en la app con un directo: «PiP del sistema activo». Con mpv no
  hay PiP del sistema; la app usa una ventana flotante propia.
- `MPVEngine.setMPVProperty(_:_:)` para diagnóstico (lo usa `--resize-probe`).
- **Pruebas** (`Tests/PlaybackKitTests`, Swift Testing con el mismo `-plugin-path` que YTKit): el vigilante (umbral,
  progreso, pausa, red, sin `time-pos`), `MPVEngine.tracks(from:)`, `screenshot-raw` → `CGImage` y `TimeGate`. 6
  pruebas en 2 suites.

## YTKit (unificado el 15-oct-2026)

Hasta la fase 1, `Sources/YouTubeSource/Spike/` llevaba una copia interna del YTKit de glasstube-spike. En la sesión de
la app (paso 0 de `smarttube-re/BRIEF-app-swiftui.md`) se unificó:

- `YouTubeSource` depende de `../YTKit` (`.package(path:)` en `Package.swift`). Se borraron `Spike/` y
  `Resources/` (clients.json, solver y página del PoToken salen del bundle de YTKit). La copia era idéntica a YTKit
  salvo el `public` y el reloj, así que la lógica no cambió.
- `SabrMediaSource.init(videoId:options:catalog:poTokenProvider:)` acepta el `ClientCatalog` y el
  `PoTokenWebViewProvider` de la app: catálogo y reproductor comparten **un solo WKWebView de BotGuard** (y los
  singletons de YTKit: `PlayerScriptStore`, `ChallengeSolver`, `SabrTransport`). Sin ellos (la demo), crea los suyos.
  Un proveedor compartido no se cierra al soltar la fuente. `YouTubeLive.hlsManifest(videoId:catalog:)` igual.
- El reloj del motor (`PlaybackClock`) llega a `SabrSession` por un adaptador del protocolo nuevo `SabrClock` de YTKit.
- Lo público mínimo que se agregó a YTKit: `SabrClock`, `SabrError.init`, y en `YouTubeService` `poTokenSource` y un
  `resolver` (`StreamResolver`) único por servicio.
- Verificado: `swift build`, las 40 pruebas de YTKit, y la demo (`aqz-KE-bpKQ --seek-at 12:200 --stop-at 30`): SABR
  con PoToken de TV, VP9 1080p60 por VideoToolbox, búsqueda fuera de lo descargado en 0,60 s, 0 cuadros descartados
  ([reporte](probes/demo-ytkit-2026-10-15.txt)).

## Qué falta

- **Validar `RELOAD_PLAYER_RESPONSE`** contra el servidor: sigue sin aparecer (tampoco en estas corridas).
- **Directos por SABR** (`LIVE_METADATA`, `SABR_SEEK`): no hechos; los directos van por HLS con `AVEngine`.
- **`AVEngine` es mínimo:** sin subtítulos externos; la calidad es un tope, no una variante exacta; AVPlayer no dice
  qué decodificador usa. El PiP y AirPlay del sistema solo existirán con este motor.
- **Solo arm64.** Para Intel habría que enlazar también la rebanada x86_64 (MPVKit la trae) y hacer un binario
  universal.
- **Distribución LGPL:** textos de licencia, fuentes y la decisión sobre la validación de bibliotecas (ver arriba).
- **Metal, sin probar:** HDR y EDR (`CAMetalLayer.wantsExtendedDynamicRangeContent`, `target-colorspace-hint`),
  `video-sync=display-resample`, varias pantallas o cambio de pantalla, otro Space y la pantalla completa a la vista de
  alguien (el cambio de tamaño ya se corrige con `syncOutputSize`). La ventana tapada, oculta o minimizada se probó en
  la fase 3 y no bloqueó la VO.
- **El arreglo de tamaño es un rodeo:** lo limpio sería que el contexto `moltenvk` informara `VO_EVENT_RESIZE` en
  `VOCTRL_CHECK_EVENTS` (comparando `drawableSize` con `vo->dwidth`), lo que pide recompilar libmpv.
- **Cuadros descartados por la VO** en ráfagas, con las dos salidas (de 22 a 65 en 120–320 s): falta medir con el
  equipo sin carga, con la ventana a la vista de alguien y con `display-fps` conocido.
- **AV1 por hardware** (M3 o posterior) no se probó: en el M1 Pro no hay.
- **Subtítulos de YouTube:** `addSubtitle(url:)` está listo, pero los timedtext/WebVTT los tiene que dar YTKit.
- **Audio:** con AAC 5.1, CoreAudio rechaza el mapa de canales (-50) y mpv usa la salida AVFoundation
  (`current-ao avfoundation`), igual que en la fase 0. No se oyó: nadie escuchó las corridas.
- **Pruebas automáticas:** solo la lógica sin red ni ventana (6); el resto se verificó con la demo y la app.
- **Concurrencia:** el paquete compila en modo Swift 5; pasar a Swift 6 estricto pediría revisar los `@unchecked
  Sendable` (búferes, reloj, la copia de SabrSession).
