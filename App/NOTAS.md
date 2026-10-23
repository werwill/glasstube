# Glasstube.app — notas (fase 1, interfaz; fase 2, cuentas; 15-oct-2026; fase 3, comunidad y reproductor; 16-oct-2026; fase 4, sistema y control remoto; distribución; 18-oct-2026; fase 5a, organizar y descubrir; 23-oct-2026)

App nativa de macOS que reimplementa SmartTube con el lenguaje Liquid Glass, sobre YTKit (catálogo, streams y cuentas)
y PlaybackKit (libmpv LGPL propia, SABR). Hecha según `smarttube-re/BRIEF-app-swiftui.md`. Mac de prueba: M1 Pro,
macOS 27.0.1, Swift 6.4 con Command Line Tools (sin Xcode). Desde la fase 2, con inicio de sesión de YouTube por código
(ver [Fase 2: cuentas](#fase-2-cuentas)). La fase 3 agrega DeArrow, Return YouTube Dislike, comentarios, chat en vivo,
el panel lateral del reproductor, el minirreproductor, la cola con reproducción automática y arreglos del motor (ver
[Fase 3](#fase-3-comunidad-panel-lateral-minirreproductor-y-cola)). La fase 4 suma el control remoto desde la app de
YouTube del teléfono, `glasstube://`, pegar y arrastrar enlaces, el menú Servicios, Spotlight y el menú del Dock (ver
[Fase 4](#fase-4-control-remoto-enlaces-y-sistema)). Para descargar desde GitHub Releases: el aviso de versiones nuevas,
`Scripts/release.sh` (DMG, suma, notas y notarización opcional) y los entitlements (ver [Distribución](#distribución)).
La fase 5a agrega grupos de canales, suscripciones de esta Mac por RSS, bloqueos en todos los feeds, el feed de Shorts y
los filtros de búsqueda (ver [Fase 5a](#fase-5a-organizar-y-descubrir)).

```bash
Scripts/package-app.sh             # swift build -c release + build/Glasstube.app firmado con «Glasstube Desarrollo» (o ad hoc)
OPEN=1 Scripts/package-app.sh      # y lo abre
CONFIG=debug Scripts/package-app.sh
Scripts/capturas.sh                # rehace capturas/ (necesita permiso de Grabación de pantalla)
CON_SESION=1 Scripts/capturas.sh sesion   # y las de la cuenta (con sesión iniciada en la app)
Scripts/capturas.sh panel          # las de la fase 3: panel, a-continuacion, dearrow, minirreproductor
Scripts/capturas.sh vincular       # las de la fase 4: la hoja «Vincular un teléfono» y Ajustes > Control remoto
Scripts/capturas.sh grupo          # las de la fase 5a que dicen «grupo» (también: filtros, suscripciones-esta-mac, ajustes-bloqueos)
Scripts/capturas-readme.sh         # las de la portada (../docs/capturas/) y el GIF, solo con Big Buck Bunny
swift test                         # 44 pruebas: cuentas (fase 2), cola, DeArrow, comentarios y chat (fase 3), QR y Spotlight (fase 4), aviso de versiones, minirreproductor, grupos, bloqueos y filtros (fase 5a)
Scripts/release.sh 0.5.0           # versión para GitHub Releases: ../dist/Glasstube-0.5.0.dmg, su SHA-256 y las notas (no sube nada)
open "glasstube://watch?v=aqz-KE-bpKQ&t=60"   # abre la app (o la que está abierta) en ese video
```

Antes, una vez: `../PlaybackKit/Scripts/fetch-libmpv.sh && ../PlaybackKit/Scripts/link-libmpv.sh`.

## Estado frente a "Terminado" del brief (fase 1)

| Criterio | Estado |
|---|---|
| Ya no existe `PlaybackKit/Sources/YouTubeSource/Spike/` | Borrada (y `Resources/`). `YouTubeSource` depende de `../YTKit`. Ver «Paso 0». |
| YTKit, PlaybackKit y la app compilan; pruebas de YTKit | `swift build` pasa en los tres; `swift test` en YTKit: 40 pruebas en 8 suites, todas pasan. La `PlaybackDemo` reproduce con YTKit ([reporte](../PlaybackKit/probes/demo-ytkit-2026-10-15.txt)). |
| `swift build` y el script producen `Glasstube.app`, que abre la ventana | Sí: release de 45 MB, `codesign --verify --strict` válido, abre la ventana principal. |
| Inicio con datos reales, búsqueda, clic en un video → PlaybackKit con controles de vidrio | Sí. Inicio sustituto de YTKit (sin cuenta), búsqueda con sugerencias y paginación, y un clic (evento de ratón real dentro de la app) en una tarjeta abre el reproductor: SABR por `MPVEngine`, VP9 por VideoToolbox, sigue donde se quedó. |
| Capturas de Inicio y Reproductor en claro y oscuro, comparadas con la maqueta | En `capturas/`, comparadas abajo. |

## Fase 2: cuentas

### Estado frente a "Terminado"

| Criterio | Estado |
|---|---|
| `swift build` y `swift test` en YTKit y en la app | Pasan: YTKit 64 pruebas en 11 suites; la app, 6 en `Tests/GlasstubeTests` (antes no tenía target de pruebas y `swift test` decía "no tests found"). |
| Con la cuenta de prueba cargan Suscripciones, Historial y Playlists | Sí, por la interfaz de TV (ver «TV y no WEB»). Suscripciones: "Más relevantes", "Más recientes" y Shorts; Historial con la barra de progreso de YouTube; Playlists: Me gusta y Ver más tarde, que se abren. También el Inicio personalizado y la cuenta de marca. |
| Me gusta y suscribirse funcionan | Sí, desde el reproductor con teclas reales (me gusta → «Te gusta este video»; suscribirse → «Te suscribiste a Rick Astley»; luego se deshicieron) y desde la cabecera del canal (Blender: Suscribirse → Suscrito → Suscribirse). |
| La posición vista se guarda | El video entra al Historial de la cuenta y YouTube lo marca como visto al pasar de cierto avance. En la interfaz de TV, YouTube solo devuelve «empezado» o «visto», no la posición exacta; la app reanuda con la posición local. Detalle en YTKit/NOTAS.md, Cuentas, punto 5. |
| Glasstube.app reempaquetada | `Scripts/package-app.sh`: versión 0.2.0, 48 MB, `codesign --verify` válido. |
| NOTAS de YTKit y de la app | Este apartado y «Cuentas (fase 2)» en YTKit/NOTAS.md. Sin datos personales. |

### Qué hay

- **Hoja de inicio de sesión** (`Account/AccountViews.swift`, `SignInSheet`): hoja del sistema con el código en 46 pt
  monoespaciado, «Copiar código», «Abrir www.youtube.com/activate», la espera con la cuenta regresiva del código y el
  aviso de usar una cuenta secundaria; al terminar, «Sesión iniciada como …». Si el código vence o se rechaza,
  «Pedir otro código». Se abre desde el menú de cuenta, desde los avisos de las secciones que requieren cuenta y desde
  Ajustes > Cuentas (que se cierra para que la hoja quede a la vista).
- **Menú de cuenta en la toolbar** (`AccountMenu`): `Menu` del sistema con el avatar de la cuenta elegida; dentro, las
  cuentas agrupadas por sesión de Google (la personal y las de marca, con la elegida marcada), «Agregar otra cuenta…»,
  «Cerrar sesión» y «Ajustes de cuentas…».
- **Barra lateral**: Suscripciones pierde el candado con sesión. Suscripciones, Historial y Playlists muestran la cuenta
  (`BrowseView` con `.subscriptions`, `.history`, `.library`); Historial y Playlists tienen un selector
  **YouTube | Esta Mac** junto al título (el historial y «Ver más tarde» locales siguen ahí). Sin sesión, como en la
  fase 1, con un aviso que ofrece iniciar sesión.
- **Tarjetas**: la barra roja en las páginas de la cuenta es la de YouTube (`percentWatched`); en las demás, la local si
  la hay. Menú contextual con sesión: «Ver más tarde» (lista de YouTube), «Guardar en una playlist…» (hoja con una
  casilla por lista: marcar agrega, desmarcar quita), «Quitar de «lista»» dentro de una lista, y «No me interesa» que
  también le avisa a YouTube (en Historial dice «Quitar del historial» y en Suscripciones «Ocultar», que es lo que hace
  el primer token del menú de YouTube).
- **Reproductor**: en la cápsula superior izquierda, «Suscribirse»/«Suscrito» (botón de texto, resaltado cuando no
  hay suscripción); en la de acciones, me gusta y no me gusta (pulgar relleno cuando está puesto). Optimistas: cambian
  al instante y vuelven si YouTube no acepta. Entran en el foco del teclado (fila de arriba) solo con sesión. Sin
  sesión, me gusta avisa «Inicia sesión para dar me gusta».
- **Posición vista**: con sesión y el ajuste activado, `updateHistoryPosition` cada minuto, al pausar, al terminar y al
  cerrar (además del historial local cada 5 s). Al abrir un video del historial de YouTube sin posición local, se usa
  `startTimeSeconds` de la tarjeta si YouTube lo da.
- **Ajustes > Cuentas** (`AccountSettings`): cada sesión de Google con sus cuentas (avatar, nombre, correo o
  «Cuenta de marca»), «En uso» o «Usar», «Cerrar sesión» (revoca en Google y borra del Llavero), agregar otra cuenta,
  actualizar nombres y avatares, el interruptor «Guardar lo que veo en el historial de YouTube» y dónde se guarda la
  sesión.
- **Canal**: el botón «Suscribirse» de la cabecera funciona con sesión (estado leído del canal por TV con la cuenta).
- **Avisos**: una cápsula de vidrio abajo del contenido para las acciones de cuenta («Se agregó a Ver más tarde») y
  para «Se cerró la sesión de YouTube» si Google revoca la sesión.

### Decisiones

- **TV y no WEB.** La sesión de la app de TV solo la acepta el cliente TVHTML5: con WEB, YouTube responde HTTP 400 a
  todo. YTKit manda la sesión solo por TV (Suscripciones, Historial, Playlists, Inicio con sesión, el estado de me
  gusta y suscripción, las acciones); búsqueda, canales y `next` siguen por WEB anónimo, que es mejor para escritorio.
- **Tokens solo en el Llavero.** La app no toca tokens: `AccountModel` solo ve nombres, avatares y el estado de la hoja.
  Nada de la cuenta se registra en stderr ni en archivos (el aviso de error de la posición vista no lleva URLs con
  parámetros).
- **Permiso del Llavero en cada compilación.** La app va firmada ad hoc (sin hardened runtime, por la LGPL; ver fase 1),
  así que macOS identifica a Glasstube por el hash del binario: después de reempaquetar, la primera lectura de la sesión
  muestra «Glasstube quiere usar información confidencial guardada en "mx.glasstube.cuentas"». Hay que elegir
  «Permitir siempre» (pide la contraseña de la Mac). No se usó el Llavero de protección de datos porque exige un
  entitlement con perfil de aprovisionamiento. Con una firma de Developer ID estable dejaría de pasar.
- **Capturas sin datos de la cuenta.** `-GTAnonimo` cambia en pantalla el nombre, el correo y el avatar por unos de
  prueba. Las capturas de `capturas/` con sesión son solo pantallas sin contenido de la cuenta (reproductor de Big Buck
  Bunny, la hoja de playlists sobre Música, Ajustes); Suscripciones, Historial e Inicio con sesión se revisaron pero
  no se guardaron.
- **Avatar de la toolbar como imagen del tamaño justo.** En la toolbar, macOS dibuja el ícono de un `Menu` con el
  tamaño de la imagen e ignora `.frame` y `.clipShape`: con la foto de 176 px de YouTube y `.resizable()`, el menú de
  cuenta salía como una burbuja de vidrio de ~190 pt debajo de la barra, tapando Recargar y Cuenta (lo encontró el dueño
  con su cuenta; las capturas con `-GTAnonimo` usaban el símbolo de persona y no lo mostraban). `AccountAvatar` dibuja
  la foto ya recortada en un círculo dentro de un `NSImage` de 22 pt (32 pt en Ajustes) y la muestra sin
  `.resizable()`; `AccountAvatarTests` comprueba el tamaño.
- **Suscripciones en una cuadrícula.** TV manda los videos recientes en tandas de tres sin título; YTKit las junta en
  «Más recientes» (también al paginar).

### Capturas nuevas

| Captura | Qué muestra |
|---|---|
| `cuenta-inicio-sesion-claro.png`, `cuenta-inicio-sesion-oscuro.png` | La hoja con un código real (ya vencido) |
| `ajustes-cuentas-claro.png` | Ajustes > Cuentas sin sesión |
| `sesion-ajustes-cuentas-claro.png` | Ajustes > Cuentas con la cuenta personal y la de marca (anonimizadas) |
| `sesion-reproductor-oscuro.png` | El reproductor con sesión: «Suscribirse», me gusta y no me gusta |
| `sesion-guardar-en-playlist-claro.png` | «Guardar en una playlist» (la cuenta de prueba solo tiene Ver más tarde) |

### Verificación (cómo)

- **Inicio de sesión**: el código se pidió con `ytkit signin` (el mismo `AccountManager` que usa la app) y el dueño lo
  escribió en youtube.com/activate; la app leyó la sesión del Llavero al abrir (con el permiso del sistema). La hoja se
  probó pidiendo códigos reales (`-GTSignIn`), sin completarlos.
- **Pantallas con sesión** (`-GTSection subscriptions|history|playlists`, Inicio, `-GTChannel`, `-GTPlaylistPicker`,
  `-GTOpenSettings -settingsTab accounts`), revisadas con `screencapture`. Clic real en «Ver más tarde» (Playlists):
  abre la lista con sus videos.
- **Reproductor** (`-GTPlay dQw4w9WgXcQ -GTKeys …`): ↑↑↑ lleva el foco a la fila de arriba, ← a me gusta, Retorno lo
  pone; ← a «Suscribirse», Retorno suscribe; luego se deshicieron los dos. El registro anota `me gusta like` y
  `suscrito sí/no`; la captura muestra el pulgar relleno, «Suscrito» y el aviso de YouTube.
- **Posición vista**: reproducción real de 2:20 de un video de 3:33 con los reportes a los 1, 62, 124 y 140 s (el
  último al cerrar con Esc): el video quedó primero en el Historial de la cuenta. Con la versión final (URL completas)
  y `ytkit watched`, un 73 % quedó como visto.
- **Errores encontrados y corregidos al probar**: la sesión con el cliente WEB (400); Suscripciones vacía (pestañas de
  TV); el `/player` sin `signatureTimestamp` (UNPLAYABLE); el reporte mínimo de SmartTube que solo marcaba «empezado»;
  Playlists repetía la página al paginar (continuación de TV que vuelve a dar lo mismo); el avatar de la toolbar
  enorme (ver Decisiones). Después del arreglo, la captura sin `-GTAnonimo` muestra el avatar de 22 pt dentro de la
  cápsula de Recargar y Cuenta, y Ajustes > Cuentas los dos avatares circulares de 32 pt.

### Qué falta (cuentas)

- **No verificado:** el menú de cuenta abierto (es un `Menu` del sistema; no se capturó), «No me interesa» mandado a
  YouTube (se verificó hasta obtener el token, sin mandarlo, para no cambiar las recomendaciones de la cuenta),
  agregar y quitar desde la hoja «Guardar en una playlist» con listas propias (la cuenta de prueba solo tiene Ver más
  tarde), cerrar sesión desde la app (la revocación y el borrado se probaron con el OAuth falso de las pruebas de YTKit),
  y una sesión revocada desde la cuenta de Google.
- **Posición exacta en YouTube:** no se puede leer por la interfaz de TV; si hace falta reanudar en otro dispositivo
  exactamente donde se quedó, habría que buscar otra fuente (p. ej. la interfaz WEB con cookies, que este proyecto no
  usa).
- **Lista de canales suscritos** (las pestañas por canal de Suscripciones de TV, como la columna de canales de
  SmartTube), crear y borrar listas desde la app, pausar el historial de YouTube desde Ajustes, y el aviso de la toolbar
  cuando la sesión vence mientras la app está abierta (hoy sale al siguiente pedido).
- **Firma estable** para que el Llavero no pida permiso después de cada compilación.

## Fase 3: comunidad, panel lateral, minirreproductor y cola

### Estado frente a "Terminado"

| Criterio | Estado |
|---|---|
| `swift build` y las pruebas pasan en los tres paquetes | Sí. YTKit 78 pruebas en 15 suites; PlaybackKit 6 en 2 (target nuevo: antes no tenía); la app 14 en 6. |
| Glasstube.app reempaquetada con `Scripts/package-app.sh` | Sí: versión 0.3.0, release de 50 MB, `codesign --verify` válido. |
| Capturas nuevas del panel lateral y del minirreproductor, contenido Creative Commons, sin caras | `capturas/panel-comentarios-oscuro.png`, `panel-descripcion-oscuro.png`, `minirreproductor.png`, más `a-continuacion-oscuro.png` y `dearrow-busqueda-claro.png`. Big Buck Bunny y Sintel (Blender Foundation, CC BY); quien comenta sale como `@personaN` con un círculo de color (`-GTSinPersonas`). |
| NOTAS actualizados | Este apartado, «Comunidad (fase 3)» en YTKit/NOTAS.md y «Fase 3» en PlaybackKit/NOTAS.md. |

### Qué hay

1. **DeArrow** (`Services/Community.swift`, `DeArrowStore`; Ajustes > DeArrow): apagado por omisión como en SmartTube,
   con «Reemplazar los títulos» y «Reemplazar las miniaturas». Cada tarjeta pide lo de su video al aparecer; los pedidos
   se juntan 150 ms y YTKit los consulta por prefijo de hash. El título cambia en tarjetas, banner del Inicio, sugeridos,
   «A continuación», minirreproductor y la barra del reproductor; la ayuda de la tarjeta y la pestaña Descripción dicen
   el original. La miniatura de DeArrow se pone encima de la de YouTube solo cuando ya cargó (`LateImage`): el servidor
   la genera y puede tardar o fallar.
2. **Return YouTube Dislike** (Ajustes > Reproductor, encendido): el número junto al pulgar abajo del reproductor
   (también sin sesión; sin sesión, tocarlo pide iniciarla) y, en Descripción, me gusta, no me gusta y la proporción.
3. **Panel lateral** (`Player/SidePanel.swift`, `Player/PanelModels.swift`), reemplaza al popover de descripción: una
   pieza más del `GlassEffectContainer` del reproductor, a la derecha, de 392 pt. El video se encoge a la izquierda para
   no quedar tapado y los controles se quedan visibles mientras está abierto. Pestañas según el video:
   - **Descripción**: título (y el original si DeArrow lo cambió), vistas y fecha, votos, canal (Retorno lo abre y el
     video pasa al minirreproductor), suscribirse con sesión y la descripción en párrafos.
   - **Capítulos**: miniatura, título y tiempo; el actual marcado; Retorno o clic busca.
   - **Comentarios**: número, orden (Principales / Más recientes), comentarios con foto, fecha, me gusta y «N
     respuestas» que se abren en línea (con «Más respuestas»), y «Más comentarios» al llegar al final. Con sesión, si
     YouTube da las acciones: me gusta (optimista, vuelve si falla) y «Responder» con un campo de texto.
   - **Chat** (directos): sondea solo mientras la pestaña está a la vista, guarda los últimos 300 mensajes y baja solo;
     Super Chat con su color, dueño, moderadores y miembros con color propio.
   - **Sugeridos**: el interruptor de reproducción automática, la cola («En cola · playlist», quitar y vaciar) y los
     sugeridos; menú contextual con «Reproducir a continuación» y «Agregar a la cola».
   - **Teclado**: D abre y cierra el panel (con el foco dentro); en la fila de pestañas ←/→ cambian de pestaña, ↓ baja a
     las filas, ↑/↓ las recorren, Retorno activa, Esc cierra y devuelve el foco al botón de comentarios, Tab vuelve a los
     controles; G me gusta, R responder, Q agregar a la cola, N a continuación, Supr quita de la cola. → desde el último
     botón de arriba entra al panel. Las demás teclas (espacio, J/K/L…) siguen yendo al video.
4. **Minirreproductor** (`Player/MiniPlayer.swift`): botón PiP de la cápsula, I o «Minirreproductor» en Más acciones.
   Con mpv es un `NSPanel` sin marco de 448×252 pt, siempre visible y en todos los Spaces, con esquinas redondeadas y
   proporción 16:9, que recuerda dónde se dejó. Se arrastra desde el video y, al soltarlo, se pega al borde de la
   pantalla más cercano en el punto donde quedó (cerca de una esquina, a los dos bordes; también al abrirlo y tras
   cambiarle el tamaño). Al pasar el puntero muestra título, volver a la ventana, cerrar, ±10 s, play/pausa, siguiente y
   el progreso (todo en un `GlassEffectContainer`, que entran y salen del árbol: a opacidad 0 el vidrio seguía a la
   vista), y se ocultan con el puntero quieto tras el tiempo de Ajustes. Doble clic o Retorno vuelven, Esc cierra,
   espacio/K/J/L/M funcionan con él enfocado. La ventana principal vuelve a la navegación y el video no se corta (la
   vista del motor se pasa de una a otra). Con `AVEngine` (directos) es el **PiP del sistema**; al restaurarlo o
   cerrarlo, el video vuelve a la ventana. Reproducir otro video desde la navegación lo devuelve a la ventana.
5. **Cola y reproducción automática** (`App/PlayQueue.swift`): «Reproducir a continuación» (primero) y «Agregar a la
   cola» (al final) en el menú de las tarjetas y de los sugeridos; abrir un video de una playlist pone el resto de la
   lista en la cola. Al terminar, la tarjeta «A continuación» (cuenta atrás de 8 s ajustable, «Reproducir ahora» con
   Retorno y «Cancelar» con Esc) sigue con la cola y, si está vacía y la reproducción automática está encendida (ahora
   por omisión, como `PLAYBACK_MODE_ALL` de SmartTube), con el siguiente sugerido. «Siguiente», Shift+N y la tecla
   multimedia toman también la cola.
6. **Robustez** (detalle en PlaybackKit/NOTAS.md, «Fase 3»): hasta el primer cuadro, la miniatura del video con un
   indicador en lugar de negro; la posición durante la llegada es la de reanudación (antes 0:00); mpv se entera de los
   cambios de tamaño (panel, minirreproductor, pantalla completa); vigilante de reproducción atascada; reintento del
   PoToken; indicador mientras espera datos.

### Decisiones

- **Panel encogiendo el video, no encima.** El contenido manda (hallazgos/05): con el panel encima se perdía un cuarto
  del video. El panel queda sobre el negro de la ventana, a la derecha, con el mismo radio que la cápsula de controles.
- **Sin vidrio dentro del panel ni de «A continuación»** (nunca vidrio sobre vidrio): las pestañas, filas y botones
  son texto con resalte; el interruptor de reproducción automática es el del sistema.
- **Comentarios por TV** (YTKit): la forma WEB es otra; el token del `next` de WEB vale con TV.
- **Abrir el canal desde el reproductor deja el video en el minirreproductor** (como YouTube) en lugar de cerrarlo.
- **`PlayerVideoView(isActive:)`** (PlaybackKit): sin eso, la vista del video quedaba en la superficie que se iba y el
  minirreproductor salía en negro (se vio en la primera prueba).
- **Ajustes booleanos de arranque**: `-deArrowEnabled YES` llega como texto; `AppSettings` ahora lee todos los
  booleanos con `bool(forKey:)` (antes `as? Bool` ignoraba estas opciones).

### Capturas nuevas

| Captura | Qué muestra |
|---|---|
| `panel-comentarios-oscuro.png` | Big Buck Bunny con el panel en Comentarios: 5.2 K, orden, respuestas; el foco del teclado en el segundo comentario; el video a la izquierda sin recortar; RYD junto a los pulgares |
| `panel-descripcion-oscuro.png` | La pestaña Descripción: votos con la proporción de RYD, el canal Blender y la descripción |
| `minirreproductor.png` | La ventana flotante con el video y los controles de vidrio |
| `a-continuacion-oscuro.png` | El final de Big Buck Bunny con Sintel en la cola: «Sigue en la cola · 3 s» |
| `dearrow-busqueda-claro.png` | Búsqueda con DeArrow: «Big Buck Bunny (2008) [60fps 4K]» y «… [24fps]» en lugar de los títulos de YouTube |

La pestaña Sugeridos, el chat y los capítulos se revisaron pero no se guardaron: las miniaturas sugeridas y los
directos de noticias muestran caras de personas reales.

### Verificación (cómo)

Con `build/Glasstube.app` (debug para iterar, release al final), `-GTSinLlavero` (sin leer el Llavero: sin sesión y sin
el aviso de permiso tras recompilar) y la automatización (`-GTPanel`, `-GTPanelFocus`, `-GTMini`, `-GTMiniExpand`,
`-GTQueue`, `-GTCubrir`, `-GTKeys`), revisando el registro y capturas de la ventana:

- **Panel**: comentarios reales de Big Buck Bunny, 9+ por página con respuestas; `-GTKeys "3:d,4:left,5:right,6:right,
  7:down,8:down,9:return,12:escape"`: D abre (Comentarios, la última pestaña), ← Descripción, → Comentarios, →
  Sugeridos, ↓ «sug:autoplay», ↓ el primer sugerido, Retorno lo reproduce, Esc cierra y el foco vuelve a Comentarios.
  Capítulos con un video de 35 capítulos (cuatro pestañas caben; foco en la fila 4; el actual marcado).
- **Tamaño del video**: la primera captura con el panel salió recortada (mpv seguía en 2880×1800); con
  `syncOutputSize` el registro dice «capa 2024x1800; mpv seguía en 2880x1800 → VO reconfigurada: ahora coincide» y la
  captura muestra el video completo.
- **Minirreproductor**: `-GTMini 3 -GTMiniExpand 12`: «capa 896x504 … ahora coincide», video en la ventana flotante, y
  de vuelta en la ventana 9 s después en 2:16 sin cortes («capa 2880x1800 … ahora coincide»).
- **Directo** (noticias, público): pestaña Chat con 67 mensajes a los 10 s («live»); `-GTMini` con `AVEngine` →
  «PiP del sistema activo».
- **A continuación**: Big Buck Bunny desde 626 s con Sintel en la cola: tarjeta con la cuenta atrás y, al terminar,
  carga de Sintel desde 0.
- **DeArrow**: `-deArrowEnabled YES -GTSearch "big buck bunny blender"`: títulos de la comunidad en las tarjetas.
- **Video en negro**: ventana tapada desde el arranque (`-GTCubrir 15`) reanudando en 300 s: reproduce tapada y se ve
  al destaparla; no se repitió el negro. Durante la carga la barra dice 6:40 (la posición de reanudación) y se ve la
  miniatura con el indicador.

### Arranque colgado en «Cargando…» (16-oct-2026)

El dueño vio la app quedarse cargando al arrancar. Causa: después de cada compilación macOS pide permiso para leer la
sesión del Llavero (firma ad hoc) y, mientras el aviso espera respuesta, el actor de cuentas de YTKit queda bloqueado; el
Inicio preguntaba primero si había sesión y esperaba con él. Reproducido: con el aviso del sistema abierto
(`SecurityAgent`) el Inicio llegó solo cuando se respondió. Arreglo: el catálogo ya no espera al Llavero (YTKit,
«Permiso del Llavero» en Cuentas) y la app muestra abajo «macOS pide permiso para leer tu sesión de YouTube: busca el
aviso… y elige «Permitir siempre»» si la lectura tarda más de 2 s. Además, la petición que se cancela al recargar la
página ya no se toma como error (`URLError.cancelled`). Verificado con `-GTLlaveroLento 25` (un Llavero que tarda
25 s): el Inicio sale a los 3,6 s sin cuenta, con el aviso. Opciones nuevas: `-GTLlaveroLento N` y `-GTVerbose`
(registro de red de YTKit).

### «Inicia sesión para confirmar que no eres un bot» (16-oct-2026)

El dueño vio a veces, con sesión iniciada, «No se pudo reproducir · player: LOGIN_REQUIRED Inicia sesión para
confirmar que no eres un bot». El player de SABR iba siempre anónimo; ahora va con la cuenta cuando hay sesión, como
SmartTube, y ante un LOGIN_REQUIRED se reintenta con visitante y PoToken nuevos (detalle en YTKit/NOTAS.md, Cuentas).
La app pasa `accounts.manager` a `SabrMediaSource(account:)`. Si aun así YouTube no da el video, el aviso muestra su
motivo tal cual (no el texto técnico del motor) y, sin cuenta, explica que YouTube a veces lo pide a quien ve sin
cuenta y ofrece «Iniciar sesión…» (al iniciarla queda solo «Reintentar»). Verificado: `-GTSimularBot 2` (aviso con
el botón), `-GTSimularBot 1` (se recupera solo y reproduce Sintel) y, con la cuenta, «player con la cuenta» en el
registro (`-GTVerbose`, que ahora también anota las notas del motor) con Big Buck Bunny reproduciendo. Opción nueva:
`-GTSimularBot N`.

### Qué falta (fase 3)

- **Con cuenta, sin verificar:** me gusta y responder comentarios (ver YTKit/NOTAS.md: hace falta el permiso del
  Llavero para el binario nuevo y responder publica un comentario en un video público). Si la interfaz de TV no da
  `actionButtons`, los botones no aparecen.
- **Sin probar a simple vista**: el minirreproductor arrastrado, redimensionado y en otro Space o sobre una app en
  pantalla completa; el PiP del sistema más allá de que arranca (restaurar y cerrar desde su ventana); el teclado
  dentro del minirreproductor (las teclas automáticas van a la ventana principal); el campo de respuesta.
- **Comentarios**: comentar en el video (no hay botón), los emojis propios de los canales en el chat (salen como
  `:atajo:`), la repetición del chat de un directo terminado.
- **Cola**: no se guarda entre sesiones; los mixes (`RD…`) siguen con el autoplay de YouTube, no como cola.
- **El negro en 0:00 original no se reprodujo**; se corrigió lo que da ese síntoma y queda el vigilante con
  diagnóstico (PlaybackKit).

## Fase 4: control remoto, enlaces y sistema

### Estado frente a "Terminado"

| Criterio | Estado |
|---|---|
| `swift build` y `swift test` en los paquetes tocados | Pasan: YTKit 90 pruebas en 18 suites (10 nuevas: Lounge y enlaces); la app 18 en 7 (4 nuevas). PlaybackKit no se tocó. |
| Glasstube.app reempaquetada con `Scripts/package-app.sh` | Sí: versión 0.4.0, release de 51 MB, `codesign --verify` válido; el Info.plist declara `glasstube://` y el servicio. |
| Emparejamiento Lounge probado con el teléfono del usuario | Sí (18-oct-2026): el dueño vinculó su teléfono con el código de la hoja, mandó un video y probó pausa, reproducir, adelantar y volumen; todo llegó y Glasstube le respondió (detalle en «Verificación»). El dueño confirmó que el teléfono mostraba bien el video, el tiempo y el volumen. |
| `glasstube://` y pegar enlaces funcionan | Sí (ver «Verificación»): con la app abierta y en frío, ⌘V, soltar y el menú Servicios. |
| Capturas nuevas de la hoja de vinculación sin datos personales | `capturas/vincular-telefono-claro.png`, `vincular-telefono-oscuro.png` y `ajustes-control-remoto-claro.png`: código DE PRUEBA (123-456-789-012, sin pedirlo a YouTube), nombre «Glasstube en la Mac» y de fondo una búsqueda de Big Buck Bunny (Blender, CC BY), sin el historial de esta Mac ni caras. |
| NOTAS actualizados | Este apartado y «Control remoto y enlaces (fase 4)» en YTKit/NOTAS.md. |

### Qué hay

1. **Control remoto desde el teléfono** (`App/RemoteControl.swift` sobre `LoungeScreen` de YTKit; `RemoteController` de
   SmartTube). La Mac aparece en la app de YouTube como una tele («Glasstube en <nombre de la Mac>», se cambia en
   Ajustes). Lo que manda el teléfono:
   - `setPlaylist`: abre el video (o, si ya suena, busca la posición) y trae la ventana al frente; con `currentTime` del
     teléfono sigue desde ahí, con 0 sigue donde lo dejó esta Mac. La cola del teléfono (`videoIds`) queda para
     siguiente y anterior; `updatePlaylist` la actualiza.
   - `play`, `pause`, `seekTo`, `next`, `previous` (primero la cola del teléfono, luego la de la app y los sugeridos),
     `setVolume` (nivel o `delta` de los botones del teléfono; el volumen se conserva para los videos siguientes),
     `stopVideo` (cierra el reproductor), `setSubtitlesTrack` (por idioma: los escritos a mano antes que los
     automáticos; vacío los quita).
   - `dpadCommand`: la cruceta como las teclas (↑ ↓ ← → Retorno Esc) por `KeyInjector` (el mismo camino que
     `-GTKeys`), así que mueve el foco de las cuadrículas, de los controles del reproductor y del panel lateral.
   - De vuelta al teléfono: `nowPlaying` al cargar un video (también uno elegido en la Mac), `onStateChange` en cada
     cambio de estado y al terminar una búsqueda, `onVolumeChanged`, `onSubtitlesTrackChanged` y
     `onHasPreviousNextChanged`. Solo si hay un teléfono conectado (como `isRemoteDisabled` de SmartTube). Al cerrar el
     reproductor, «nada suena».
   - Aviso de vidrio abajo de la ventana: «"<teléfono>" se conectó…» (uno por minuto como mucho: el teléfono repite
     `remoteConnected` al volver a la app).
2. **Hoja «Vincular un teléfono»** (`Remote/RemoteViews.swift`, `PairingSheet`; `AddDevicePresenter`): hoja del sistema
   con el código de 12 dígitos en 40 pt monoespaciado (`XXX-XXX-XXX-XXX`), el QR que abre lo mismo con la cámara
   (generado con CoreImage, sobre blanco para que se lea en modo oscuro), «Copiar código», «Pedir otro código», el
   estado del enlace («Esperando al teléfono… Aparecerá como …», «Conectando…», «Sin conexión… reintento en N s») y, al
   conectarse, «"<teléfono>" se conectó». Se abre desde Ajustes, desde el menú Glasstube («Vincular un teléfono…») o con
   `-GTPairing`.
3. **Ajustes > Control remoto** (`RemoteSettings`; `RemoteControlSettingsPresenter`): activar (apagado por omisión,
   como SmartTube), estado con un punto de color, nombre en el teléfono, teléfonos conectados ahora, «Vincular un
   teléfono…» y «Desvincular todos los teléfonos…» (con confirmación: identidad nueva de pantalla, `resetData`). El
   enlace vive mientras la app está abierta: arranca 1,5 s después de abrirla si está activado.
4. **Enlaces** (`App/SystemIntegration.swift`, con `YouTubeLink` de YTKit):
   - **`glasstube://`** declarado en el Info.plist (`CFBundleURLTypes`); `package-app.sh` registra la app con
     `lsregister`. Video (`watch?v=…&t=…&list=…`; con `list` el resto de la lista pasa a la cola), canal, playlist,
     búsqueda y `open?url=…`. También abre enlaces de YouTube pasados a la app (`open -a Glasstube https://youtu.be/…`).
   - **⌘V** fuera de un campo de texto: el delegado de la app está al final de la cadena de respuesta y atiende
     `paste:` cuando nadie más lo hace; si el portapapeles no tiene un enlace de YouTube, lo dice en un aviso. En el campo
     de búsqueda ⌘V pega como siempre, y un enlace buscado con Retorno se abre en lugar de buscarse. Además, Edición >
     «Abrir el enlace copiado» (⇧⌘V).
   - **Soltar** un enlace (o texto con uno) en la ventana: aparece una cápsula de vidrio «Suelta el enlace para abrirlo
     en Glasstube».
   - **Servicios > «Abrir en Glasstube»** para texto o enlaces seleccionados en cualquier app (`NSServices`).
   - Con un video en la ventana, abrir un canal, una lista o una búsqueda deja el video en el minirreproductor.
5. **Spotlight** (`Services/Spotlight.swift`): al reproducir, el video (título, canal, duración, miniatura JPEG) y su
   canal van al índice de Core Spotlight de la app; también los canales que se abren. Vencen al año. Al elegir un
   resultado, macOS manda la actividad `CSSearchableItemActionType` y la app reproduce el video o abre el canal. Ajustes
   > General: «Agregar a Spotlight los videos que veo y sus canales» (encendido) y «Quitar todo de Spotlight».
6. **Menú del Dock** (clic secundario en el ícono): Inicio, Suscripciones y Seguir viendo (los 6 últimos a medias con lo
   que falta, y «Todo el historial»). Con un video en la ventana, pasa al minirreproductor.
7. **«Ahora suena» y teclas multimedia**: ya estaban (fase 1); ahora «Reproducir» y «Pausa» del sistema no alternan, sino
   que reproducen o pausan (`PlayerModel.play()`/`pause()`).

### Decisiones

- **Identidad de la pantalla en `UserDefaults`**, no en el Llavero: no es una credencial de la cuenta y así no aparece
  el aviso de permiso del Llavero tras cada compilación (firma ad hoc). Solo sirve para que un teléfono vinculado
  encuentre esta Mac; «Desvincular todos» la cambia.
- **El nombre por omisión lleva el nombre de la Mac** (como SmartTube: «<dispositivo> (<app>)»), que suele incluir el
  de la persona. Se cambia en Ajustes; las capturas usan `-remoteName "Glasstube en la Mac"`.
- **La app pasa al frente con `setPlaylist` y con la cruceta**: el teléfono «transmitió» a esta pantalla, como la app de
  TV. Con `play`, `pause`, `seekTo` y el volumen no (se pueden usar con la app atrás).
- **QR propio**: el de YouTube es un PNG de 256 px; el contenido es solo `https://youtube.com/pair/<código>?qr=1`, así
  que se genera nítido a cualquier tamaño.
- **Cierres de Core Spotlight `@Sendable`**: con el aislamiento al actor principal por omisión, el `foundItemsHandler`
  de `CSSearchQuery` quedaba aislado y la app caía en `dispatch_assert_queue` («BUG IN CLIENT OF LIBDISPATCH») al
  llegar el resultado. Se vio en la primera prueba (registro del sistema: «Found: 1 items» y el fallo).

### Verificación (cómo)

Con `build/Glasstube.app` (debug para iterar, release al final), `-GTSinLlavero` y las opciones nuevas
(`Support/Automation.swift`):

- **Con el teléfono del dueño** (release, `-GTRemoto -GTVerbose`, identidad guardada: el teléfono queda vinculado para
  usarlo después). Registro: «teléfonos conectados: 1», «← remoteConnected» → «→ onVolumeChanged 100», «← getNowPlaying»
  → «→ nowPlaying (nada)», «← setPlaylist» → el reproductor abrió el video y «→ nowPlaying buffering» y «→ onStateChange
  playing 0 s»; «← pause» → «en pausa en 76,5 s» → «→ onStateChange paused 76 s»; «← seekTo» → «→ onStateChange paused
  239 s»; «← play» → reproduciendo; «← seekTo» → 354 s; «← setVolume» seis veces (97 → 42); al volver la app del
  teléfono, «← remoteConnected» y «← getNowPlaying» → «→ nowPlaying playing» y «→ onSubtitlesTrackChanged apagados».
  **Dos errores encontrados y corregidos después** (no se volvió a probar con el teléfono): (1) cada `setVolume`
  reportaba primero el volumen viejo (el estado del motor lo confirma un instante después) y luego el nuevo; ahora se
  reporta una vez, con el valor puesto; (2) al adelantar lejos (fuera de lo descargado) SABR da la posición 0 un instante
  y se reportó «onStateChange playing 0 s» (el teléfono se corrigió solo con el siguiente reporte); ahora
  `PlayerModel` sigue mostrando el destino de la búsqueda hasta que la posición llega (o 4 s), lo que también quita ese
  0:00 de la barra. Comprobado sin teléfono: tecla 8 (al 80 %) y J dejan la barra en 8:20 en un video de 10:35. Además,
  `pause` con el video ya en pausa (y `play` reproduciendo) confirma el estado al teléfono.

- **Lounge sin teléfono**: la app abre la sesión («← loungeStatus, getNowPlaying, getDiscoveryDeviceId», «estado
  connected») y, al pedir el código, la reabre con un token nuevo. Con `ytkit lounge --seconds 80 -v` el canal siguió
  abierto 80 s y el reporte `nowPlaying` dio HTTP 200.
- **`glasstube://` con la app abierta**: `open "glasstube://watch?v=aqz-KE-bpKQ&t=60"` → reproduciendo en 60,0 s;
  `glasstube://channel/@BlenderOfficial` → canal (el video pasó al minirreproductor); `glasstube://search?q=…` →
  resultados. **En frío** (app cerrada): `open "glasstube://watch?v=eRsGyueVLvQ&t=300"` abrió la app con Sintel en 5:00.
- **Servicios**: `pbs -dump_pboard` lista «Abrir en Glasstube» con sus tipos; `NSPerformService("Abrir en Glasstube", …)`
  desde otro proceso, con un portapapeles propio y el texto «Mira este corto: https://www.youtube.com/watch?v=…&t=120
  (Sintel)» → «servicios → video(…, start: 120)» y reproduciendo en 120,0 s. Con un texto sin enlace, el servicio
  responde con error y la app no hace nada.
- **⌘V** (`-GTPegar url`: guarda el portapapeles, pone el enlace, manda ⌘V por el menú y lo repone): «atajo cmd+v →
  atendido», «pegar → video(…, start: 30)», reproduciendo en 30,0 s. Con el foco en el campo de búsqueda, el enlace se
  pegó en el campo (captura revisada) y no se abrió nada.
- **Soltar** (`-GTSoltar url`, un `NSItemProvider` como el de un arrastre): «arrastrar → channel(@BlenderOfficial)». El
  gesto real de arrastrar desde otra app no se probó (ver «Qué falta»).
- **Spotlight**: al reproducir Big Buck Bunny, «indexado video:aqz-KE-bpKQ» y «indexado channel:UCSMOQeB…»;
  `-GTSpotlightQuery Bunny` (una `CSSearchQuery` sobre el índice de la app) → «video:aqz-KE-bpKQ «Big Buck Bunny 60fps
  4K…»». `-GTSpotlightOpen video:…` y `channel:…` (la misma actividad que manda Spotlight, al delegado) → reproduce y
  abre el canal.
- **Dock**: `-GTDockMenu "Big Buck"` escribe el menú (Inicio, Suscripciones, Seguir viendo con 6 videos y lo que falta
  de cada uno, Todo el historial) y elige el video: reproductor abierto en 25 s.
- **«Ahora suena» y teclas multimedia**, desde otro proceso con MediaRemote (`MRMediaRemoteGetNowPlayingApplicationPID`,
  `…GetNowPlayingInfo`, `…SendCommand`), con Big Buck Bunny reproduciéndose: el PID de «Ahora suena» es el de Glasstube;
  la información trae título, canal («Blender»), duración 635 s, posición, velocidad 1, tipo video y la carátula (JPEG
  600×338). Los comandos que mandan las teclas multimedia y el Centro de control llegaron al reproductor: pausa → «en
  pausa», reproducir → «reproduciendo», alternar dos veces, y siguiente → cargó el sugerido («Caminandes 2», también de
  Blender) y «Ahora suena» cambió al título nuevo.

### Capturas nuevas

| Captura | Qué muestra |
|---|---|
| `vincular-telefono-claro.png`, `vincular-telefono-oscuro.png` | La hoja «Vincular un teléfono» con el código de prueba, el QR (de ese código), los botones y «Esperando al teléfono… Aparecerá como "Glasstube en la Mac"» con el enlace conectado de verdad (una pantalla desechable, `-GTRemotoEnMemoria`) |
| `ajustes-control-remoto-claro.png` | Ajustes > Control remoto: activado, «Listo; ningún teléfono conectado», el nombre, vincular y desvincular |

Rehacerlas: `Scripts/capturas.sh vincular` y `Scripts/capturas.sh control-remoto`. Con una hoja abierta y otra app al
frente, la ventana salía inactiva (botones atenuados, como la hoja de la fase 2); `-GTPairing` y `-GTOpenSettings`
ahora la traen al frente con `activateIgnoringOtherApps:` (solo en la automatización: `activate()` es cooperativo y
macOS lo ignora mientras la persona usa otra app).

### Fuera de alcance (necesitan Xcode)

- **App Intents / Atajos**: los metadatos de App Intents los genera `appintentsmetadataprocessor` dentro del build de
  Xcode; con SwiftPM y Command Line Tools no hay manera de producir `Metadata.appintents`.
- **Widgets** (WidgetKit) y la **extensión de compartir** (para «Compartir > Glasstube» en Safari): son extensiones
  `.appex` con su propio target, Info.plist de extensión y firma con entitlements; SwiftPM no las arma. Mientras tanto,
  el menú Servicios cubre «abrir este enlace en Glasstube» desde cualquier app.

### Qué falta (fase 4)

- **Solo a simple vista**: «Ahora suena» dibujado en el Centro de control (el sistema tiene los datos y la carátula; ver
  «Verificación») y una tecla multimedia física del teclado (se probó el mismo comando por MediaRemote); un resultado de
  Spotlight en la ventana de Spotlight (⌘ espacio) y abrirlo con clic (se probó la consulta al índice y la misma
  actividad); el menú del Dock con clic secundario de verdad (se probó el menú que da la app y sus acciones); arrastrar un
  enlace desde Safari a la ventana (se probó la ruta del `NSItemProvider`).
- **Control remoto**: la voz (`voiceCommand`) se ignora; «No guardar en el historial lo que llega del teléfono» y «Cerrar
  la app al desconectarse» de SmartTube no están; la calidad no se reporta (`onVideoQualityChanged`); los Shorts del
  teléfono se abren como un video normal.
- **Aviso fuera de la app**: el «se conectó» es un aviso dentro de la ventana; no hay notificación del sistema.

## Distribución

Versión 0.4.0 lista para descargar desde GitHub Releases (18-oct-2026), sin publicar: crear la versión y subir los
archivos lo hace el dueño. Se empieza sin notarizar, como «vista previa», con un aviso de versiones nuevas; la
notarización queda lista para cuando haya un Developer ID.

### Estado frente a "Terminado"

| Criterio | Estado |
|---|---|
| `swift build` y `swift test` | Pasan. La app: 29 pruebas en 8 suites (11 nuevas en `UpdateCheckerTests`). PlaybackKit (se tocó una opción de mpv): 6 en 2. YTKit no se tocó. |
| `Scripts/release.sh 0.4.0` produce el `.dmg` y sus notas | Sí: `dist/Glasstube-0.4.0.dmg` (16,8 MB, ULMO), `.dmg.sha256` (`shasum -c` OK) y `RELEASE-NOTES-0.4.0.md`. Firmada con el certificado propio «Glasstube Desarrollo» (lo creó el dueño el 18-oct-2026: solo nombre y país, válido hasta 2036; requisito designado = identificador + hoja del certificado, así que el «Permitir siempre» del Llavero sirve para las versiones siguientes firmadas con él). Sin Developer ID. Montado: `codesign --verify --deep --strict` válido, `allow-jit` en los entitlements, versión 0.4.0, `GlasstubeGitHubRepository` = `werwill/glasstube`. Ventana de Finder revisada en captura (fondo, ícono a la izquierda, flecha, acceso a Applications, ícono del volumen). La app abre desde el DMG y reproduce (Big Buck Bunny de 30 a 43,6 s; con la versión anterior del DMG, Sintel). `spctl` la rechaza, como corresponde a una app sin notarizar. |
| Aviso probado contra una respuesta simulada | Unitarias con un GitHub falso (versión mayor, igual, 404, 403, JSON roto, sin conexión, límite diario, apagado, sin `Info.plist`). En la app del DMG con `-GTActualizacionesURL file://…/latest.json` (tag `v0.5.0`): el aviso sale abajo a la derecha en claro y en oscuro, y un clic real en «Ahora no» lo cierra. «Descargar» no se pulsó (abriría el navegador en una página que aún no existe); lo cubre la prueba de `update(from:)`. Contra la API real, la app recibió 404 (el repositorio no existe todavía), no avisó y guardó la hora de la consulta. |
| README y PROMPT | `README.md` y `README.en.md`: sección «Descargar» (Releases, requisitos, suma, pasos de Gatekeeper), «Aviso de versiones nuevas», `release.sh` en «Compilar a mano» y la pregunta frecuente sobre la notarización. `PROMPT.md`: preguntar si quiere compilar o solo usar la app, y el aviso. |
| `dist/` en `.gitignore` | Sí, en el de la raíz. |

### Qué hay

1. **Aviso de versiones nuevas** (`Services/UpdateChecker.swift`, sin Sparkle). Al abrir (en `didFinishLaunching`) y
   como mucho una vez al día, `GET https://api.github.com/repos/<dueño/repo>/releases/latest` con `URLSession`
   efímera (sin cookies ni caché), `User-Agent: Glasstube` y nada más. Si `tag_name` es mayor que
   `CFBundleShortVersionString`, `UpdateNotice`: tarjeta de vidrio abajo a la derecha (los botones son cápsulas planas,
   sin vidrio sobre vidrio, como «A continuación»), oculta mientras el reproductor ocupa la ventana. «Descargar» abre
   `html_url` en el navegador (solo `https`/`http`); «Ahora no» la cierra hasta la siguiente consulta.
   - **Un solo lugar para dueño y repo:** `GITHUB_REPO` en `Scripts/package-app.sh` (por omisión `werwill/glasstube`,
     el de los README), que va al `Info.plist` como `GlasstubeGitHubRepository`. De ahí lo leen la app y `release.sh`.
     `GITHUB_REPO=` arma una app sin aviso; sin `Info.plist` (`swift run`, pruebas) no se consulta nada.
   - **Comparación:** `AppVersion` (SemVer: número por número, `v` inicial, `1.0` = `1.0.0`, prerreleases antes de la
     final). Borradores y prerreleases no cuentan (`releases/latest` ya los excluye, así que **las versiones no deben
     marcarse como «pre-release» en GitHub** o el aviso no las verá; `release.sh` lo recuerda).
   - **Límite diario:** `updatesLastCheck` en `UserDefaults`, que se guarda solo si GitHub contestó (sin conexión se
     reintenta al siguiente arranque). 404 (sin versiones todavía) cuenta como «al día».
   - **Ajustes › General › Actualizaciones** (primera sección): «Avisarme cuando haya una versión nueva» (encendido),
     «Buscar ahora» con el resultado, la última consulta y el enlace a las versiones. «Acerca de» ahora lee la versión
     del `Info.plist` (antes decía «0.4 · fase 4» fijo).
   - Automatización: `-GTActualizacionesURL url` (también `file://`) consulta esa dirección sin el límite diario.
2. **`Scripts/release.sh <versión>`**: pone `VERSION` en `package-app.sh`, compila y empaqueta, arma el DMG con
   `hdiutil` (la app, un enlace `Applications` y `.fondo/fondo.tiff` de `Packaging/dmg-fondo.svg` a 1x y 2x; Finder
   acomoda la ventana por AppleScript; `.VolumeIcon.icns`), lo convierte a ULMO, lo comprueba montado (`hdiutil
   verify`, `codesign --verify --deep --strict`, versión, enlace) y escribe la suma y las notas (requisitos, suma,
   pasos de Gatekeeper o «notarizada», código fuente de Glasstube en la etiqueta y de libmpv, y un resumen en inglés).
   Al final dice cómo publicarla con `gh release create`, sin correrlo. `SKIP_BUILD=1` rehace solo el DMG.
3. **Notarización opcional** en el mismo script: si `security find-identity -v -p codesigning` tiene una
   «Developer ID Application» (o la que diga `DEVELOPER_ID`), empaqueta con `HARDENED_RUNTIME=1` (`--options runtime
   --timestamp` y `Glasstube.entitlements`) y firma el DMG. Si además `xcrun notarytool history --keychain-profile
   glasstube-notarizacion` funciona (`NOTARY_PROFILE` lo cambia), `notarytool submit --wait`, `stapler staple` y
   `stapler validate`; si Apple no la acepta, muestra el registro y termina con error. El perfil lo crea el dueño con
   `xcrun notarytool store-credentials`; el script nunca pide ni guarda contraseñas. Sin Developer ID sigue con la firma
   de `package-app.sh` y lo dice. `package-app.sh` se niega a usar hardened runtime sin Developer ID (ver abajo).

### Hallazgos: firma y entitlements

Probado en esta Mac (M1 Pro, macOS 27.0.1) con copias firmadas ad hoc con y sin `--options runtime`:

- **JavaScriptCore no usa JIT sin `com.apple.security.cs.allow-jit`, con o sin hardened runtime.** No falla: corre en el
  intérprete. Un bucle de prueba en `JSContext`: 610 ms sin el entitlement (sin runtime y con runtime) y 50–65 ms con
  él. El solver de yt-dlp/ejs con un player real de YouTube: preprocesar el player (la primera vez con cada versión
  nueva del player) 2,2 s → 0,45 s; con la caché del player, 0,06 s en los dos casos; `ytkit sabr-player` completo, sin
  diferencia medible (2 s, lo domina la red). Con el entitlement, `vmmap` muestra regiones «JS JIT» en la app.
  **Decisión:** `Glasstube.entitlements` con solo `allow-jit`, y `package-app.sh` lo pone siempre (también en la firma
  ad hoc y la propia, donde también activa el JIT).
- **Validación de bibliotecas.** Con hardened runtime y firma sin Team ID (ad hoc, y también el certificado propio),
  dyld no carga `Libmpv.framework`: «mapping process and mapped file (non-platform) have different Team IDs» y la app
  no arranca. Con Developer ID la app y el framework llevan el mismo Team ID, así que no hace falta
  `disable-library-validation` (es lo que exige dyld; no se pudo probar sin un Developer ID). Por eso
  `HARDENED_RUNTIME=1` exige una identidad Developer ID. Para la LGPL: `codesign --force --deep --sign -` sobre una app
  con runtime deja una firma ad hoc sin runtime ni entitlements (comprobado: `flags=0x2(adhoc)`), así que quien
  reemplace la biblioteca la puede cargar; `Licenses/THIRD-PARTY-NOTICES.md` lo explica.
- **LuaJIT mataba la app con hardened runtime.** Con runtime, `allow-jit` y `disable-library-validation` (para poder
  probar sin Developer ID), la app moría al abrir el primer video: SIGKILL «Code Signature Invalid», «Invalid Page», en
  `load_builtin` → `load_scripts` → `script_thread` de Libmpv. `load-scripts=no` solo apaga la carpeta de scripts; mpv
  igual carga los suyos (estadísticas, consola, selector, menús…) con LuaJIT, que ejecuta memoria sin firmar.
  **Arreglo** (PlaybackKit, `MPVEngine`): `load-stats-overlay`, `load-console`, `load-auto-profiles`, `load-select`,
  `load-commands`, `load-positioning` y `load-context-menu` en `no`; Glasstube no usa ninguno. Después, con hardened
  runtime: Big Buck Bunny reproduciendo a 1080p60 (posición 30 → 43,8 s, captura revisada) y sin informes de fallo. No
  hace falta `allow-unsigned-executable-memory`.
- **Con hardened runtime se probó** arrancar, el Inicio con datos de YouTube y reproducir por SABR con el solver de
  JavaScriptCore (JIT activo) a 1080p60. **No se probó con runtime:** el Llavero (las pruebas usan `-GTSinLlavero`), el
  audio a oído, los directos (AVPlayer) ni el control remoto. No deberían pedir entitlements: la app no está en el
  sandbox, y el hardened runtime solo los pide para cámara, micrófono, ubicación, contactos, calendarios, fotos y
  eventos de Apple, que Glasstube no usa.

### Hallazgos: el DMG

- **Finder borra `.VolumeIcon.icns`** al acomodar la ventana por AppleScript: el ícono del volumen se copia y se marca
  (`SetFile -a C`) después.
- **Finder tarda en ver el disco recién montado:** a veces `tell disk "Glasstube"` daba -1728 («No puede obtenerse
  disk»). El script espera hasta 20 s a que `exists disk` sea verdadero. Si aun así falla (o macOS no deja controlar
  Finder: la primera vez pide permiso de Automatización), el DMG sale sin fondo y el script lo avisa.
- **Los límites de la ventana incluyen la barra de título** (32 pt sin barra de herramientas): para ver el fondo de
  660×400 entero, la ventana mide 660×432.
- **Etiquetas de Finder:** en modo claro son negras y en oscuro blancas, sobre el mismo fondo. El verde azulado del
  ícono con luminancia de 0,17 a 0,22 deja las dos legibles (≥ 3,9:1).
- **`qlmanage` siempre rasteriza a un cuadrado:** el SVG de 660×400 se centra en uno de 660×660 (`viewBox` desde
  y = -130) y `sips` recorta la franja del medio; `--cropOffset 0 0` de `sips` no recorta desde arriba.
- **`hdiutil` está obsoleto en macOS 27** (avisa en cada llamada que lo reemplaza `diskutil image`), pero funciona; el
  script calla ese aviso.

### Revisión de lo que se publica

Antes de subir el repositorio y la versión (18-oct-2026):

- **Imágenes del repositorio** (`docs/`, `PlaybackKit/probes/capturas-5min/`, el ícono), revisadas a ojo, con el GIF
  cuadro por cuadro: solo Big Buck Bunny (CC BY) y sus miniaturas, quienes comentan como `@personaN`, el código de
  vinculación de prueba y «Glasstube en la Mac»; sin sesión, historial ni caras. Metadatos: solo resolución y
  «Screenshot» (sin ubicación ni equipo).
- **Texto:** sin rutas de la Mac, nombre ni IP (las que hay son de ejemplo); las claves `AIza…` son las públicas de los
  clientes de YouTube; los `Cgt…` de las fixtures son continuaciones del video de prueba.
- **Dentro del DMG había rutas de esta Mac:** el ejecutable (83 entradas de depuración, `OSO`) y `Libmpv` (239) llevaban
  `/Users/<usuario>/…/REA/glasstube/…/.build/…`. `package-app.sh` ahora quita la información de depuración
  (`strip -S`, que conserva los símbolos y las 54 `mpv_*` exportadas) antes de firmar, y `release.sh` se detiene si
  la app montada contiene `$HOME/` (`LC_ALL=C grep -rlaF`: sin `-a`, `grep -r` se salta los binarios). Las rutas
  `/Users/runner/…` que quedan en Libmpv son de las máquinas de compilación de MPVKit en GitHub.

### Qué falta

- **La notarización no se probó de verdad:** no hay Developer ID ni perfil de `notarytool` en esta Mac. El camino del
  script (detección, `HARDENED_RUNTIME=1`, firma del DMG, `submit --wait`, `staple`, `validate`) está escrito y la app
  con hardened runtime se probó con firma ad hoc más `disable-library-validation`, que es lo único que cambia frente a
  Developer ID. La primera corrida con Developer ID conviene revisarla. Solo se notariza y engrapa el DMG (como pide la
  tarea); la app copiada a Aplicaciones se valida en línea la primera vez.
- **Abrir una copia descargada de verdad** (con cuarentena) y «Abrir de todos modos» no se recorrió aquí: es una acción
  del dueño en Ajustes del Sistema. Los pasos son los de la fase 1 y de Apple para macOS 15 o posterior.
- **LGPL al pie de la letra:** las notas enlazan el código de MPVKit en su commit y de mpv y FFmpeg en sus etiquetas
  (servidores de terceros). Para no depender de ellos, se pueden adjuntar a cada versión los tarballs de las fuentes.
- **El repositorio `werwill/glasstube` aún no existe en GitHub** (la cuenta `werwill` sí): hasta que se suba y tenga
  una versión publicada, la consulta da 404 y la app no avisa nada. Si se publica con otro nombre, cambiar
  `GITHUB_REPO` y los enlaces de los README y de `PROMPT.md`.
- **«Ahora no» vuelve a avisar en la siguiente consulta** (al día siguiente como pronto); no hay «saltar esta versión».
- **Las notas de cada versión** traen un comentario para escribir qué cambió: el script no lo inventa.

## Fase 5a: organizar y descubrir

Grupos de canales, suscripciones sin cuenta, bloqueos, el feed de Shorts y los filtros de búsqueda (23-oct-2026). La
parte de red está en YTKit (`Sources/YTKit/Discover/`, ver «Organizar y descubrir (fase 5a)» en YTKit/NOTAS.md). La 5b
(respaldo, Sparkle, accesibilidad y modo TV) va después.

### Estado frente a "Terminado"

| Criterio | Estado |
|---|---|
| `swift build` | Pasa en los tres paquetes. La app no tiene avisos nuevos (los que salen son los de OpenGL de PlaybackKit). |
| Todas las pruebas pasan | YTKit 106 en 22 suites (16 nuevas en `DiscoverTests`), PlaybackKit 6 en 2, la app 44 en 10 (11 nuevas en `Phase5aTests`; incluye las 4 de `MiniPlayerTests`, que estaban sin commit). |
| Capturas nuevas con `Scripts/capturas.sh` | Diez, en `capturas/` (tabla abajo). Contenido Creative Commons sin caras: videos del canal oficial de Blender (licencia CC comprobada en `next`) y Big Buck Bunny; nada de la cuenta ni del historial (grupos e historial en memoria). |
| `Scripts/package-app.sh` | Release de 51 MB, versión 0.4.0 (no se cambió), firmado con «Glasstube Desarrollo», `codesign --verify` válido. |
| Informe de lo no verificado | «Qué falta (fase 5a)», abajo. |

### Qué hay

1. **Grupos de canales** (`App/ChannelGroups.swift`, como `ChannelGroupServiceImpl` de SmartTube):
   - **Barra lateral, «Mis grupos»**: un renglón con carpeta por grupo (como la maqueta), «+» para «Nuevo grupo…» o
     «Importar…», y sin grupos, esos dos renglones. Se ordenan arrastrando (`onMove`) o con «Subir»/«Bajar»; el menú de
     cada grupo también tiene «Canales del grupo…», «Renombrar…» y «Borrar grupo…» (con confirmación; solo borra el
     grupo). Nombres sin repetir («Música 2»).
   - **Feed del grupo** (`Browse/ChannelFeedView.swift`): lo nuevo de sus canales por RSS, del más nuevo al más viejo,
     en cuadrícula, y los Shorts aparte en su fila. Arriba, los canales en cápsulas (foto o inicial; clic abre el canal,
     menú para quitarlo) y, en vidrio, «Canales…» y «…» (renombrar, ordenar, borrar). Abajo dice qué canales no
     respondieron. ⌘R vuelve a pedir los feeds sin caché.
   - **Agregar canales**: «Agregar a un grupo» en el menú de las tarjetas (cada grupo con su marca, y «Nuevo grupo con
     este canal…») y en la cabecera del canal («Agregar a un grupo» o «En <grupo>»/«En N grupos»); en la hoja «Canales
     del grupo», por @handle, enlace o id.
   - **Importar** (Ajustes › Respaldo o el «+» de la barra lateral): PocketTube,
     GrayJay y NewPipe, los mismos formatos que SmartTube. Un grupo con el mismo nombre recibe los canales que le falten
     en lugar de duplicarse; NewPipe va a las suscripciones de esta Mac, como en SmartTube. El aviso dice qué entró y
     cuántas entradas no eran canales de YouTube.
   - **Nombres y fotos**: lo importado solo trae ids. Los nombres se completan con el feed RSS; las fotos, al abrir el
     canal, al agregarlo desde una tarjeta y, en el feed, de hasta 8 canales por visita (de su página). Todo queda
     guardado.
2. **Suscripciones de esta Mac, sin cuenta**: «Suscribirse» en la cabecera del canal (sin sesión ya no pide iniciar
   sesión) y «Suscribirse en esta Mac» en el menú de las tarjetas. Suscripciones muestra su feed RSS (como
   `BrowseService2Wrapper` de SmartTube cuando no hay cuenta). Con sesión, Suscripciones sigue siendo la de YouTube y
   tiene el selector **YouTube | Esta Mac** (como Historial y Playlists). Los grupos funcionan igual con o sin cuenta.
   La barra lateral ya no pone candado en Suscripciones.
3. **Bloqueos**: «Bloquear canal» en el menú de las tarjetas y en el «…» de la cabecera del canal. Sus videos, Shorts,
   listas y su tarjeta de canal desaparecen de Inicio (también de «Seguir viendo»), Explorar, Suscripciones, grupos,
   Shorts, búsqueda, sugeridos del reproductor y la reproducción automática. Su página dice «Canal bloqueado» con
   «Desbloquear». La lista para desbloquear está en una pestaña nueva, **Ajustes › Bloqueos** (antes al fondo de
   General), con «Contenido oculto».
4. **Feed de Shorts**: la sección Shorts es el feed de YouTube (`reel_watch_sequence` por WEB, como SmartTube), con más
   al llegar al final. Se abren en el reproductor normal (el video vertical con franjas; sin visor especial).
5. **Filtros de búsqueda** (`Browse/SearchFilterMenu.swift`): junto al título de los resultados, un menú de vidrio con
   los grupos del diálogo de YouTube: Prioridad (Relevancia, Popularidad), Fecha de carga (Hoy, Esta semana, Este mes,
   Este año), Tipo (Videos, Shorts, Canales, Playlists, Películas), Duración (menos de 3, de 3 a 20, más de 20 minutos) y
   Características (En vivo, 4K, HD, Subtítulos, Creative Commons, HDR). El botón dice lo que está puesto («Videos ·
   3–20 min · Creative Commons») y al lado aparece × para quitarlos. Con tipo Shorts, los resultados van en
   cuadrícula; sin resultados, el aviso ofrece «Quitar los filtros».

### Decisiones

- **El feed de un grupo es RSS siempre**, con cuenta o sin ella, como SmartTube (`getRssFeed`). No necesita sesión ni
  Innertube, y la caché de YTKit (15 min en memoria y disco) hace que volver a un grupo sea instantáneo. Lo que no da el
  RSS: duración, directos y estrenos (ver «Qué falta»).
- **`groups.json` aparte de `library.json`**, con el mismo esquema (JSON en Application Support escrito 400 ms después
  del último cambio). Así el respaldo de la 5b puede exportar los grupos solos, como SmartTube.
- **El filtro es parte del destino** (`Destination.search(texto, filtro)`): cambiarlo reemplaza la página sin dejar otra
  entrada en «Atrás» (`Navigator.replace`), y volver a una búsqueda anterior la trae con sus filtros.
- **Solo los filtros que hoy ofrece YouTube.** El orden por fecha de subida y «Última hora» ya no existen (YouTube ignora
  `CAI=`); «Orden» es la «Prioridad» del diálogo actual. Detalle en YTKit/NOTAS.md.
- **Bloqueo por id del canal y, si la tarjeta no lo trae** (la búsqueda de TV), por el nombre.
- **Botones de la cabecera del canal**: «Agregar a un grupo» va antes de «Suscribirse» para que su menú, que se abre
  hacia la derecha, quepa en la ventana; el título del menú va sin ícono porque el botón de menú de macOS lo pega al
  texto.
- **Vidrio**: los controles nuevos (filtros, «Canales…», «…», botones de la cabecera) son `.glass`/`.glassProminent`
  dentro de un `GlassEffectContainer`; las cápsulas de canales y las tarjetas son contenido (sin vidrio). Sin `Material`
  ni `blur` propios.

### Verificación (cómo)

Con `build/Glasstube.app` (debug para iterar, release al final), `-GTSinLlavero -GTGruposEnMemoria
-GTBibliotecaEnMemoria -remoteEnabled NO` (sin tocar los grupos, el historial ni el teléfono vinculado del dueño) y las
opciones nuevas de `Support/Automation.swift` (`-GTGrupos`, `-GTGrupo`, `-GTSuscripcionesLocales`, `-GTImportar`,
`-GTBloquear`, `-GTFiltro`, `-GTEditarGrupo`, `-GTNuevoGrupo`, `-GTSoloVideos`, `-GTRegistroGrupos`):

- **Grupo**: «Blender» + «Blender Studio» → «feed de 2 canales → 30 videos (13 Shorts) en 0,08 s; de caché 1». Con un
  tercer id que no existe: «sin respuesta 1», el aviso al pie y «fotos completadas 2 de 3» (las fotos se piden solas).
- **Importar**: `pockettube.json` de las pruebas → «PocketTube: 3 grupos nuevos, 5 canales, 1 entrada omitida», los tres
  en la barra lateral en el orden del archivo y el primero abierto; `newpipe_subscriptions.json` → «NewPipe: 2
  suscripciones nuevas en esta Mac, 1 entrada omitida», Suscripciones abierta con su feed. Con `ytkit importar`, también
  los archivos de prueba del propio SmartTube.
- **Suscripciones sin cuenta**: la página de Blender Studio muestra «Suscrito en esta Mac» y «En Animación abierta»;
  Suscripciones, las cápsulas y el feed.
- **Bloqueos**: con Blender bloqueado, `ytkit search blender` da 2 resultados del canal oficial y la app no muestra
  ninguno (el canal «BLENDER» que sí sale es otro); su página dice «Canal bloqueado».
- **Shorts**: 14 en la primera página (3,6 s) y 15 más al bajar; Retorno en la sección abre el primero en el reproductor
  («SABR …: video 780 vp9 608x1080@30»); `-GTPlay` con un Short de Spring (Blender Studio) también. Un clic en un Short
  de una búsqueda filtrada por Shorts lo abre.
- **Filtros**: «big buck bunny blender» con Videos + 3–20 min + Creative Commons → solo videos de esa duración; el menú
  abierto con un clic real; «blender open movie» con Shorts + Creative Commons → «Sin resultados con estos filtros».
- **Menús**: el de grupos de la cabecera del canal, abierto con un clic real, muestra los tres grupos con su marca y
  «Nuevo grupo con este canal…».

### Capturas nuevas

`Scripts/capturas.sh` (bloque «Fase 5a»). Los feeds son los RSS reales; `-GTSoloVideos` deja a la vista solo cuatro
videos del canal oficial de Blender con licencia Creative Commons y sin caras (dos portadas de BCON26 y los Shorts
«Default Cube» y «Blender on Android»), elegidos el 23-oct-2026 entre los 15 últimos de cada canal: los demás eran
charlas con personas, y los de Blender Studio no son CC. Si dejan de salir en el RSS, el script dice cómo elegir otros.

| Captura | Qué muestra |
|---|---|
| `grupo-claro.png`, `grupo-oscuro.png` | El grupo «Blender»: la barra lateral con tres grupos, la cápsula del canal con su foto, «Canales…» y «…», videos y la fila de Shorts |
| `grupo-canales-claro.png` | La hoja «Canales del grupo»: nombre, canales y «Agregar un canal» |
| `grupo-nuevo-oscuro.png` | El aviso «Nuevo grupo de canales» con su campo |
| `canal-grupos-oscuro.png` | La página del canal oficial de Blender con el menú «En 3 grupos» abierto (los videos son reels de Blender, CC) |
| `suscripciones-esta-mac-oscuro.png` | Suscripciones sin cuenta: dos canales seguidos en esta Mac y su feed |
| `filtros-busqueda-claro.png` | Búsqueda de Big Buck Bunny con Videos · 3–20 min · Creative Commons y el menú de filtros abierto |
| `filtros-sin-resultados-oscuro.png` | Shorts + Creative Commons sin resultados, con «Quitar los filtros» |
| `ajustes-bloqueos-claro.png` | Ajustes › Bloqueos con dos canales de prueba (ids inventados) |
| `ajustes-respaldo-claro.png` | Ajustes › Respaldo tras importar el PocketTube de las pruebas: grupos y el botón «Importar…» |

Las dos con un menú abierto se capturan con `screencapture -R` (el rectángulo de la ventana): el script solo captura si
Glasstube está al frente (`lsappinfo front`), porque si no saldría lo que haya en pantalla (pasó una vez al probar: se
borró). Con `-GTWindowFrameFile`, la app se trae al frente varias veces en los primeros segundos.

**Sin captura del feed de Shorts**: son recomendaciones de YouTube al azar, casi todas con caras y sin licencia CC (se
revisó, no se guardó).

### Qué falta (fase 5a)

- **Sin probar a mano** (la automatización no llega): un clic en una tarjeta de la **sección Shorts** solo le da el foco
  a la cuadrícula (el mismo clic sintético en un Short de una búsqueda sí lo abre, y Retorno en la sección también; con
  el ratón de verdad no se probó); escribir en la hoja «Canales del grupo» (las teclas automáticas van a la ventana
  principal, no a la hoja: la resolución de @handle se probó con `ytkit channel @BlenderStudio`); marcar o desmarcar un
  grupo y «Bloquear canal» desde los menús (los menús abiertos no reciben clics sintéticos; el almacén y el bloqueo
  tienen pruebas); reordenar arrastrando en la barra lateral; el selector de archivos de «Importar…» (se probó la misma
  importación con `-GTImportar`).
- **Con cuenta, sin verificar**: el selector YouTube | Esta Mac de Suscripciones y los grupos con sesión iniciada (la
  sesión de prueba no se usó: solo la secundaria y solo si la inicia el dueño). El feed de los grupos no usa la cuenta.
- **RSS**: sin duración, directos ni estrenos en las tarjetas (SmartTube los completa pidiendo la pestaña de cada canal,
  una petición más por canal); solo los 15 últimos videos de cada canal; tope de 200 canales por feed.
- **Shorts**: siempre anónimos (SmartTube, con cuenta, pone antes los de las suscripciones); unos 2,5 MB por página de
  diez (un `reel_item_watch` por Short, como SmartTube).
- **Bloqueo por nombre** cuando la tarjeta no trae el id del canal: un canal homónimo también se oculta.
- **Exportar** grupos y suscripciones (y el respaldo de SmartTube) llega con el respaldo de la 5b.
- **El botón «…»** de la cabecera del canal y del grupo sale como un círculo más chico que los botones con texto: el
  botón de menú de macOS no toma el alto de su etiqueta.

## Paso 0: un solo YTKit

- La copia de `Spike/` era idéntica a YTKit salvo el `public` y el reloj (`SabrPlaybackClock` → `PlaybackClock`), así que
  se borró sin tocar lógica.
- Público mínimo agregado a YTKit: protocolo `SabrClock` (`SabrSession.stream(…clock:)` ahora lo recibe;
  `SabrPlaybackClock` lo cumple), `SabrError.init`, y en `YouTubeService` `poTokenSource` y un `resolver` único.
- `SabrMediaSource.init(videoId:options:catalog:poTokenProvider:)`: la app le pasa su `ClientCatalog` y su
  `PoTokenWebViewProvider`. **Un solo WKWebView de BotGuard** para catálogo y reproductor, y un solo juego de
  `PlayerScriptStore`/`ChallengeSolver`/`SabrTransport`. La fuente no cierra un proveedor que no creó.
- NOTAS de YTKit y PlaybackKit actualizadas.

## Estructura

| Archivo | Qué hace |
|---|---|
| `App/GlasstubeApp.swift` | `@main`: escena `Window` (una sola ventana) y `Settings`; menús (⌘[ ⌘] ⌘R ⌘K, ⇧⌘V, Reproducción, «Vincular un teléfono…») |
| `App/AppModel.swift` | Servicios compartidos (`YouTubeService` con la sesión, `PoTokenWebViewProvider`, extras, SponsorBlock), `Navigator` (atrás/adelante), búsqueda, reproductor abierto, acciones de cuenta y avisos |
| `App/AccountModel.swift` | Cuentas en la app sobre `AccountManager` de YTKit: estado, hoja de inicio de sesión, elegir y cerrar sesión (fase 2) |
| `Account/AccountViews.swift` | Avatar, menú de cuenta, hoja del código, Ajustes > Cuentas y «Guardar en una playlist» (fase 2) |
| `App/AppSettings.swift` | Preferencias en `UserDefaults` (se pueden fijar al lanzar: `-appearance dark`) |
| `App/LocalLibrary.swift` | Historial con posiciones, Ver más tarde, ocultos y canales bloqueados (JSON en Application Support) |
| `App/MainWindow.swift` | `NavigationSplitView`, toolbar, `.searchable` + sugerencias, capa del reproductor |
| `Browse/*` | Barra lateral, Inicio (banner), tarjetas, cuadrícula y teclado, páginas de YTKit con paginación, canal, historial, playlists |
| `Player/*` | `PlayerModel` (motor, metadatos, SponsorBlock, historial, panel, «A continuación»), vista y controles de vidrio, barra, menús, teclado, Ahora suena; `SidePanel` y `PanelModels` (panel lateral, comentarios, chat), `MiniPlayer` (minirreproductor y PiP del sistema), fase 3 |
| `App/PlayQueue.swift`, `Services/Community.swift` | Cola de reproducción y DeArrow en la app (fase 3) |
| `Services/*` | Imágenes con caché, storyboard y subtítulos (VISIONOS), SponsorBlock |
| `Settings/SettingsView.swift` | `TabView` + `Form` `.grouped` |
| `Support/Automation.swift` | Opciones `-GT…` para pruebas y capturas (teclas y clics reales dentro de la app; fase 2: `-GTSignIn`, `-GTPlaylistPicker`, `-GTAnonimo`; fase 4: `-GTRemoto`, `-GTRemotoEnMemoria`, `-GTPairing`, `-GTCodigoDePrueba`, `-GTEnlaces`, `-GTPegar`, `-GTSoltar`, `-GTSpotlight`, `-GTSpotlightQuery`, `-GTSpotlightOpen`, `-GTDockMenu`; fase 5a: `-GTGruposEnMemoria`, `-GTBibliotecaEnMemoria`, `-GTGrupos`, `-GTGrupo`, `-GTSuscripcionesLocales`, `-GTImportar`, `-GTBloquear`, `-GTFiltro`, `-GTEditarGrupo`, `-GTNuevoGrupo`, `-GTSoloVideos`, `-GTRegistroGrupos`) |
| `Tests/GlasstubeTests` | Pruebas de la lógica de cuentas de la app (fase 2) y de cola, DeArrow, comentarios y chat con servicios falsos (fase 3) |
| `App/RemoteControl.swift`, `Remote/RemoteViews.swift` | Control remoto desde el teléfono sobre `LoungeScreen`: comandos, reportes, hoja «Vincular un teléfono» con QR y Ajustes > Control remoto (fase 4) |
| `App/SystemIntegration.swift` | Delegado de la app: `glasstube://`, Spotlight, menú del Dock, Servicios y ⌘V; abrir enlaces, soltar (fase 4) |
| `Services/Spotlight.swift`, `Support/KeyInjector.swift` | Índice de Core Spotlight; teclas reales dentro de la app (automatización y cruceta del teléfono) (fase 4) |
| `Scripts/package-app.sh`, `Scripts/capturas.sh`, `Licenses/` | Empaquetado (Info.plist con `glasstube://` y `NSServices` desde la fase 4), capturas y avisos de licencias |
| `Services/UpdateChecker.swift`, `Scripts/release.sh`, `Glasstube.entitlements`, `Packaging/dmg-fondo.svg` | Aviso de versiones nuevas; versión para GitHub Releases (DMG, suma, notas, notarización opcional); entitlements (`allow-jit`); fondo del DMG (distribución) |
| `App/ChannelGroups.swift`, `Browse/ChannelFeedView.swift`, `Browse/SearchFilterMenu.swift` | Grupos de canales y suscripciones de esta Mac (groups.json); feed RSS de un grupo o de las suscripciones, hoja «Canales del grupo», avisos de nombre y borrado; menú de filtros de búsqueda (fase 5a) |

## Alcance (puntos 1–7)

1. **Ventana:** `NavigationSplitView` con la barra lateral del sistema (Inicio, Suscripciones, Historial, Playlists,
   Shorts; Explorar: Música, Gaming, Noticias, En vivo; Mis grupos con los grupos de canales desde la fase 5a; Ajustes al pie, que abre la escena
   `Settings`). Toolbar: atrás/adelante (`ToolbarItemGroup(.navigation)`), búsqueda centrada (`.searchable(placement:
   .toolbarPrincipal)` + `.searchSuggestions` de YTKit con 180 ms de pausa), recargar y cuenta separados por
   `ToolbarSpacer(.fixed)`.
2. **Inicio:** banner del primer video de "Para ti" con `.backgroundExtensionEffect()` (se ve bajo la barra lateral) y
   desde el borde superior (bajo la toolbar); "Seguir viendo" con el historial local; "Para ti" mezcla las filas del
   Inicio de YTKit; luego el resto de filas con su título y "Ver todo". `LazyVGrid` adaptable (≥ 220 pt) y
   `.scrollEdgeEffectStyle(.soft, for: .top)`.
3. **Tarjeta:** miniatura opaca 16:9 de 16 pt, duración en un `ConcentricRectangle` (concéntrico a la miniatura vía
   `.containerShape`), progreso visto; al pasar el puntero (o con el foco del teclado) se eleva 4 pt, recorre 14 cuadros
   del storyboard con "Vista previa · m:ss" y muestra "…" (botón de vidrio). Menú contextual: reproducir, agregar a
   playlist (Ver más tarde local), no me interesa, abrir canal, bloquear canal, compartir, copiar enlace.
4. **Búsqueda y canal:** resultados con paginación (`continueGroup`/`continuePage` al llegar al final; probado: 19 → 39
   resultados). Canal por id, @handle o URL con sus pestañas (Principal, Videos, Shorts, En vivo, Programas,
   Playlists…), cabecera con banner y avatar.
5. **Reproductor:** ver la sección siguiente.
6. **Teclado y sistema:** espacio y K, J/L (±10 s), ←/→ (±5 s), F, C, Shift+. y Shift+, (también con la distribución
   latinoamericana, donde dan «:» y «;»), M, 0–9; cualquier tecla muestra los controles y el foco entra en ellos
   (play/pausa; con ←/→, la barra). Desde la fase 3: D (panel lateral), I (minirreproductor). Flechas, Tab/Shift+Tab y Retorno recorren los controles; Esc oculta y luego
   cierra. En las cuadrículas: flechas por filas y secciones, Tab, Retorno/espacio abren, ← en la primera columna va a
   la barra lateral y → vuelve (ver «Verificación»). `MPNowPlayingInfoCenter` (título, canal, duración, posición, carátula) y
   `MPRemoteCommandCenter` (play/pausa, siguiente/anterior, ±10 s, posición).
7. **Ajustes:** escena `Settings` con `TabView` (General, Interfaz, Reproductor, Subtítulos, SponsorBlock, DeArrow,
   Cuentas, Control remoto, Respaldo) y `Form(.grouped)`. Funcionan Control remoto (desde la fase 4), DeArrow (desde la fase 3), Cuentas (desde la fase 2), Interfaz (apariencia, vista previa, Shorts en
   Inicio, tiempo de los controles), Reproductor (calidad máxima, códec, búfer, seguir donde lo dejé, siguiente al
   terminar), Subtítulos (activar al empezar, idioma), SponsorBlock (activar, saltar solo) y General; ocultos y
   bloqueados están en su propia pestaña, Bloqueos, desde la fase 5a. Las demás explican en qué fase llegan.

### Reproductor

- Ocupa la ventana encima de la navegación (que queda intacta y desactivada); la toolbar se oculta. F = pantalla completa.
- **Un solo `GlassEffectContainer`** con todo el vidrio: cápsula superior izquierda (volver, título, «Canal · Capítulo
  N: …»), cápsula de acciones (me gusta, comentarios, descripción y capítulos, más), cápsula de controles
  (`.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))`), burbuja del storyboard, avisos y «Saltar
  patrocinio» (`.regular.tint(color).interactive()`). Al ocultarse, la cápsula pasa a una barra mínima de progreso con el
  mismo `glassEffectID` y `@Namespace`: el cambio de forma lo hace el sistema.
- Degradados oscuros arriba (160 pt) y abajo (300 pt) que aparecen con los controles. Vidrio `.regular`, nunca `.clear`.
- Barra: visto, descargado, cortes de capítulo (de `next`), tramos de SponsorBlock con borde oscuro, marca y burbuja al
  pasar el puntero (cuadro del storyboard, tiempo y capítulo), arrastrar busca al soltar.
- Menús como popovers del sistema: calidad (una por resolución, códec preferido, códec/búfer/decodificación), velocidad,
  subtítulos (pistas de YouTube en WebVTT, las del idioma preferido primero), pista de audio y más acciones (abrir
  canal, minirreproductor, Ver más tarde, copiar enlace con o sin tiempo, estadísticas). Descripción y capítulos pasaron
  al panel lateral en la fase 3.
- SponsorBlock **real**, no de prueba: API pública con consulta por prefijo de hash (no se envía el id del video). En
  Big Buck Bunny sale el tramo de créditos; en `qF4vZxbSmjo` un patrocinio de 399–440 s. `-GTSponsorDemo` agrega un tramo
  de prueba solo si se pide al lanzar.
- Directos: por HLS con `AVEngine` (probado con un directo público de noticias; la barra dice «EN VIVO»).
- Historial: guarda la posición cada 5 s, en pausa y al cerrar; al volver a abrir, sigue 2 s antes.

## Capturas y comparación con la maqueta

`capturas/` (2880×1800, ventana de 1440×900 pt; Ajustes a su tamaño). Rehacerlas: `Scripts/capturas.sh`.

| Captura | Qué muestra |
|---|---|
| `inicio-claro.png`, `inicio-oscuro.png` | Inicio con datos reales; la primera tarjeta de "Para ti" en vista previa (estado por omisión de la maqueta) |
| `reproductor-claro.png`, `reproductor-oscuro.png` | El estado de la maqueta: menú de calidad abierto, burbuja del storyboard, «Saltar patrocinio» |
| `reproductor-controles-ocultos.png` | La cápsula encogida a la barra mínima |
| `reproductor-foco-teclado.png` | Foco del teclado en un control tras ↓ → → → |
| `busqueda-claro.png`, `canal-oscuro.png` | Resultados con el foco en una tarjeta; canal @MKBHD con pestañas |
| `ajustes-reproductor-claro.png`, `ajustes-interfaz-oscuro.png` | Ajustes |

**Igual que la maqueta:** la jerarquía y las proporciones (barra lateral de ~236 pt con las mismas secciones y orden;
toolbar en tres cápsulas; banner de 392 pt que pasa bajo la barra lateral y la toolbar, con insignia, título de 34 pt,
canal · duración · fecha, «Reproducir» destacado y «Ver más tarde»; secciones de 20 pt con «Ver todo»; cuadrícula de 4
columnas con miniaturas de 16 pt, duración, progreso y la tarjeta elevada con «Vista previa» y «…»). En el reproductor,
la posición de cada cápsula, la burbuja de 188 pt, la cápsula verde con el tiempo restante que se aparta cuando hay un
menú abierto, y los mismos controles y orden.

**Diferencias y por qué:**

1. **Barra lateral.** En macOS 27 la del sistema va de borde a borde (la maqueta dibujaba un panel flotante con margen).
   Se usa la del sistema, como pide el brief; el banner se ve a través de ella como tinte del vidrio.
2. **Contenido.** Sin cuenta, YouTube no recomienda nada: «Para ti» sale de Explorar (aviso al pie) y la insignia dice
   «Destacado en Explorar» en lugar de «Nuevo de tus suscripciones». Las miniaturas son reales (y a veces estridentes).
3. **Mis grupos** era un renglón «Grupos de canales — Llegan en la fase 5» (desde la fase 5a son los grupos de verdad,
   con la carpeta de la maqueta); **Cuenta** es un símbolo en lugar del avatar «T»; **Suscripciones** llevaba un candado
   hasta la fase 5a (ahora sin cuenta muestra las suscripciones de esta Mac).
4. **⌘K** no se dibuja dentro del campo (el campo del sistema no lo admite); está en el menú Edición.
5. **Botones del sistema.** «Reproducir» es `.glassProminent` (acento, más bajo que el de la maqueta) y «Ver más tarde»
   `.glass`; la insignia del banner es una cápsula oscura, no vidrio (es información, no un control).
6. **Reproductor:** el video real es 2:1 con franjas negras; hay un botón más, **Pista de audio** (el brief pide ese
   menú); el menú de calidad es el popover del sistema (con flecha, fila elegida en acento y una fila más,
   «Decodificación»); no hay «Automática» porque la fuente SABR no hace ABR (arranca en la calidad máxima de Ajustes);
   subtítulos abre un menú (C los activa o quita); el volumen es un `Slider` del sistema; la velocidad muestra la actual
   («1×»). «Saltar» sube sobre la burbuja si coinciden (en la maqueta no chocaban).
7. **El reproductor es siempre oscuro**, también en modo claro (como la maqueta y los reproductores del sistema), así que
   `reproductor-claro` y `reproductor-oscuro` son iguales salvo el cuadro del video. Los popovers del reproductor también
   van oscuros.
8. **Semáforos:** con el reproductor abierto la toolbar se oculta y macOS esconde los botones de la ventana; la cápsula
   superior queda a 24 pt del borde, como en la maqueta.

## Decisiones

- **`@State` no compila con Command Line Tools:** en el SDK de macOS 27 es una macro (`SwiftUIMacros.StateMacro`) cuyo
  plugin no viene sin Xcode. Se usa el mismo tipo con otro nombre: `typealias ViewState<Value> = SwiftUI.State<Value>`
  (`@ViewState`). Por lo mismo se evitó SwiftData (`@Model` es macro): la biblioteca local es un JSON.
- **Swift 6 con `defaultIsolation(MainActor.self)`**: la app no tiene avisos de concurrencia. Lo que llaman otros hilos
  va `@Sendable` (manejadores de `MPRemoteCommandCenter` y la carátula de Ahora suena: sin eso la app caía en
  `dispatch_assert_queue` cuando MediaPlayer pedía la imagen desde su cola).
- **Foco del teclado propio** en el reproductor y en las cuadrículas: una vista enfocable por página con la tarjeta (o el
  control) enfocada como estado en un objeto `@Observable`. Motivos, todos comprobados: `.focusable(interactions:
  .activate)` solo enfoca con «Navegación con teclado» del sistema activada; asignar el foco a tarjetas dentro de un
  `LazyVGrid` no surte efecto; el cierre de `onKeyPress` leía un `@State` viejo; y una lectura hecha dentro del cierre
  del `ForEach` no redibujaba la vista. El anillo usa el color de foco del sistema y solo aparece al usar el teclado (al
  arrancar, las flechas ya funcionan sin marcar nada a quien usa el ratón).
- **Tab desde el campo de búsqueda** no entra al contenido (la toolbar está fuera de la jerarquía de SwiftUI del
  contenido). Por eso, al buscar con Retorno el foco pasa al primer resultado, y la barra lateral ↔ contenido va con las
  flechas.
- **Storyboard y subtítulos por VISIONOS** (`/player` sin `n`, firma ni PoToken; los subtítulos se descargan sin `pot`).
  Vive en la app (`Services/PlayerExtras.swift`) usando la API pública de YTKit; es candidato a pasar a YTKit.
- **Calidades con el nombre de YouTube:** altura equivalente en 16:9 (un 3840×1920 es «2160p», no «1920p»), una por
  resolución con el códec preferido.
- **Shorts:** hasta la fase 5a la sección mostraba los Shorts de una búsqueda; desde entonces es el feed de
  `reel_watch_sequence` (ver [Fase 5a](#fase-5a-organizar-y-descubrir)).
- **Firma ad hoc sin hardened runtime:** con hardened runtime y sin Team ID, la validación de bibliotecas impediría cargar
  un `Libmpv.framework` reconstruido por el usuario (lo que pide la LGPL). Identificador `mx.glasstube.Glasstube`
  (el framework ya usaba `mx.glasstube.libmpv`). Desde la distribución, hardened runtime solo con Developer ID (ver
  [Distribución](#distribución)).
- **Automatización de pruebas** (`-GT…`, documentadas en `Automation.swift`): abre videos, búsquedas, canales o Ajustes,
  fuerza el estado de las capturas y envía teclas y clics reales por `NSApp.sendEvent` (no mueve el puntero del sistema
  ni toca otras apps). Con `-GTKeys`/`-GTClicks` la app anota cada tecla y el estado resultante en stderr.

## Verificación (cómo)

- **Teclado del reproductor** (`-GTKeys`, con el registro de estado): espacio pausa y reanuda; → busca +5 s y pone el foco
  en la barra; L/J ±10 s; Shift+. dos veces 1 → 1,25 → 1,5 y Shift+, vuelve a 1,25; C carga los subtítulos en español;
  ↑ (con los controles ocultos) los muestra con el foco en play/pausa; →/Tab mueven el foco; Retorno activa; Esc oculta;
  X solo muestra los controles. Hallazgo: dos búsquedas seguidas (L y luego J mientras la primera aún cargaba) usaban la
  posición vieja; se corrigió sumando al destino pendiente, sin volver a probarlo con teclas.
- **Cuadrícula:** →, ↓×3, Tab, ← recorren 1, 5, 9, 13, 14, 13, 12; ← en la primera columna ya no mueve la selección y
  pide el foco de la barra lateral (no se comprobó que la lista lo tome, ni el → de vuelta). La página se desplaza a la
  tarjeta (`ScrollPosition`).
- **Atajos de menú:** ⌘, abre Ajustes (probado con la automatización). ⌘K, ⌘[, ⌘] y ⌘R están en los menús pero no se
  probaron.
- **Clic** en una tarjeta de «Seguir viendo» → reproductor, carga g1 en 1513,4 s, «reproduciendo» a los 0,85 s.
- **Directo** (`p2AzyIEuFak`): HLS por `AVEngine`, reproduciendo a los 15 s.

## Qué falta

- **Verificar con «Reducir transparencia» y «Aumentar contraste».** Son ajustes del sistema que esta sesión no puede
  cambiar. Todo el vidrio es del SDK (no hay `Material` ni `blur` en la app), así que debería adaptarse solo, pero no se
  vio. Quien tenga el Mac a mano: activarlos en Accesibilidad > Pantalla y correr `Scripts/capturas.sh`.
- **No verificado a simple vista:** «Ahora suena» dibujado en el Centro de control y una tecla multimedia física (desde
  la fase 4 se comprobó por MediaRemote que el sistema tiene a Glasstube como la app que suena, con sus datos y carátula,
  y que sus comandos llegan; ver «Fase 4»), el audio (nadie escuchó) y la pantalla completa (F la alterna; no se
  capturó).
- **Una vez**, en el primer clic de prueba, el video quedó en negro en 0:00 a los 9 s; no se repitió (la segunda corrida
  cargó en 0,85 s). En la fase 3 se probó con la ventana tapada, oculta y minimizada sin repetirlo, y se corrigió lo que
  da ese síntoma (ver «Fase 3», punto 6, y PlaybackKit/NOTAS.md).
- **Licencias:** los textos de LGPL-2.1, LGPL-3.0 y GPL-3.0 y el MIT de SmartTube van en
  `Contents/Resources/Licenses/` (los dos de la v3 se descargaron de gnu.org con permiso). Ajustes > General menciona
  mpv y FFmpeg, y desde la distribución las notas de cada versión enlazan el código fuente (ver
  [Distribución](#distribución), «Qué falta»). Ver `Licenses/THIRD-PARTY-NOTICES.md`.
- **Ícono:** hay uno estático (concepto B «Ventana», elegido en el canvas de la maqueta). `Icon/Glasstube.svg` va **a
  sangre completa** (cuadrado de 1024, sin esquinas ni sombra): así macOS 26 le aplica su propia forma; con margen y
  esquinas propias el sistema lo mete en una placa blanca (se probó con cuatro variantes). `Icon/Glasstube-pequeno.svg`
  es la versión simplificada para 16 y 32 px. `Scripts/make-icon.sh` genera `Icon/AppIcon.icns` (qlmanage + sips +
  iconutil) y `package-app.sh` lo copia y lo declara en `CFBundleIconFile`. Falta el ícono "vivo" (vidrio del
  sistema, modos teñido y transparente): se arma en Icon Composer con `Icon/capas/` y necesita Xcode (`actool`).
- **Pendientes del producto:** respaldo, Sparkle, accesibilidad y modo «TV» (fase 5b). Comentarios, chat, panel
  lateral, minirreproductor, DeArrow y la cola llegaron en la fase 3; el control remoto en la fase 4; grupos de canales,
  suscripciones sin cuenta, bloqueos, feed de Shorts y filtros de búsqueda en la 5a.
- **Atajos:** Tab desde la búsqueda no llega al contenido (ver Decisiones); ⌘K, ⌘[, ⌘] y ⌘R sin probar.
- **Solo arm64** (como PlaybackKit) y probado en una sola Mac y región (MX, `es-419`).
