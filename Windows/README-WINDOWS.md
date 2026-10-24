# Glasstube para Windows (primera versión: Inicio + reproductor)

Interfaz en **C# + WinUI 3** (Windows App SDK 1.7, sin empaquetar, x64). YTKit y GlasstubeCore siguen en Swift, compartidos
con la app de Mac, y llegan a la interfaz como una DLL con API en C. El video es libmpv pintando en un `SwapChainPanel`.

```
Windows/
  build.ps1            compila todo y deja la app en out/app/Glasstube.exe
  GlasstubeFFI/        paquete Swift → GlasstubeFFI.dll (YTKit + GlasstubeCore, @_cdecl + JSON)
    include/GlasstubeFFI.h   la API en C
  MPVBridge/           MPVBridge.c → MPVBridge.dll (libmpv en el SwapChainPanel; sale de winui-spike/step4-video)
  GlasstubeCore/       lógica sin interfaz (rama glasstube-core)
  Glasstube.App/       la app WinUI 3 (MainWindow, HomePage, PlayerPage, P/Invoke en Native/)
  Installer/           instalador (Inno Setup) e icono
  out/                 salida del build (ignorada por git)
```

## Compilar

Requisitos: Swift 6.4 (`winget install Swift.Toolchain`), VS Build Tools 2022 con el Windows SDK 10.0.26100, SDK de .NET 8
(`winget install Microsoft.DotNet.SDK.8`), runtime de Windows App SDK 1.7 y libmpv en `PlaybackKit/Vendor/windows-x64`
(`bash PlaybackKit/Scripts/fetch-libmpv-windows.sh`).

```powershell
cd Windows
.\build.ps1          # Swift release (~3–4 min la primera vez), MPVBridge, DLL nativas y dotnet build
.\build.ps1 -Run     # y abre la app
.\build.ps1 -SkipSwift   # solo C/C#, con la DLL de Swift ya compilada
```

`out/app` pesa ~250 MB: el runtime de Swift (~70 MB, se copia entero para no fallar por una DLL que falte), libmpv (~100 MB)
y GlasstubeFFI (31 MB en release).

## Instalador e icono

```powershell
winget install JRSoftware.InnoSetup          # una vez
.\Installeruild-installer.ps1 -Version 0.1.0   # build.ps1, dotnet build e Inno Setup
```

Deja `dist/Glasstube-<versión>-Windows-x64-Setup.exe` y su `.sha256` (como el `.dmg` de la app de Mac: `dist/` no va al
repositorio, se sube a GitHub Releases). La app va autocontenida (.NET 8 y Windows App SDK dentro), así que no pide
ningún runtime aparte; solo WebView2, que Windows 11 trae y el instalador avisa si falta. Se instala por usuario en
`%LOCALAPPDATA%\Programs\Glasstube` sin permisos de administrador (o para todos, si se elige al principio), con acceso
en Inicio, acceso opcional en el escritorio y desinstalador. Sin firma, SmartScreen avisa la primera vez («Más
información» → «Ejecutar de todas formas»).

El icono (`Glasstube.App/Assets/Glasstube.ico`) sale del de la app de Mac con `python Installer/make-icon.py` (Pillow):
cuadrado redondeado con margen, y la variante pequeña de `Glasstube-pequeno.svg` hasta 32 px.

## Cómo encajan las piezas

- **Hilos.** Todo YTKit vive en el actor principal de Swift, que fuera de Apple es la cola principal de libdispatch. En la app
  nadie corre `dispatchMain()`: `App.OnLaunched` pone un `DispatcherQueueTimer` de 15 ms que llama a `gt_pump()`
  (`_dispatch_main_queue_callback_4CF`). Así los trabajos del actor principal y los callbacks de la FFI corren en el hilo de
  la interfaz, que es el hilo principal del proceso. La primera llamada a la DLL se hace desde ese hilo.
- **API C.** Funciones `gt_*` con callback `(context, status, json)`; en C# el contexto es un `GCHandle` de un
  `TaskCompletionSource`, así que cada llamada es un `Task<T>`. Ver `include/GlasstubeFFI.h`.
- **Sesión.** `AccountManager` lee la bóveda del Administrador de credenciales (la misma que usa `ytkit`), así que la app
  arranca con la cuenta ya iniciada. Con sesión, el Inicio es el de la cuenta (por TV).
- **Streams.** `gt_resolve_stream` usa la rotación de clientes de YTKit (`formatInfo`: firma, `n`, validación de las URLs y,
  si hace falta, PoToken con WebView2), hasta 1080p, VP9 > H.264 > AV1. Devuelve la URL de video y la de audio, y mpv las
  abre con `audio-files`, el `User-Agent` del cliente y `Origin`/`Referer`. Los directos en curso (TV_DOWNGRADED no los
  marca: se notan en que los formatos no traen `contentLength`) usan el manifiesto HLS del cliente VISIONOS, como
  `YouTubeLive` en PlaybackKit. Los videos con restricción de edad fallan con «Sign in to confirm your age» (falta pedir el
  player con la cuenta).
- **Video.** `d3d11-output-mode=composition`: mpv crea su swapchain, el puente la lee de `display-swapchain` y la pone con
  `ISwapChainPanelNative::SetSwapChain`. El tamaño en píxeles físicos va a `d3d11-composition-size` y la escala con
  `SetMatrixTransform`. El manifiesto declara PerMonitorV2 (sin él, todo sale borroso al 125 %).

## Registro y diagnóstico

- Todo va a `%LOCALAPPDATA%\Glasstube\logs\glasstube.log`: `[app]` (C#), `[ffi]` (resolución: cliente, formatos, tiempo),
  `[ytkit]` (cada intento de la rotación con HTTP, playability y comprobación de URLs) y `[mpv]` (avisos y errores).
  Pasa de 5 MB → `glasstube.old.log`. La ruta sale también en el mensaje de error del reproductor.
- Una app de ventana lanzada con doble clic **no tiene stderr**: `FileHandle.write(_: Data)` aborta el proceso si falla
  (crash `0xc000001d` en swiftCore.dll). Por eso `Log` de YTKit tiene `sink` y usa `write(contentsOf:)` con `try?`.
  No uses `FileHandle.standardError.write(Data)` en código que corra dentro de la DLL.
- `Glasstube.exe --abrir <videoId>` abre ese video al arrancar (pruebas). Con `--medir`, el reproductor anota cada 5 s la
  posición, los segundos en caché y si está esperando datos (`[medir]`); con `--volcar-urls`, guarda las URLs y cabeceras
  que recibe mpv en `logs\stream-<id>.json` (para medirlas con curl). Cada resolución anota además, sin la URL, lo que
  importa de ella: itag, bitrate, tamaño, servidor y si lleva `n`, `pot`, `ratebypass` o `sabr`.
- **Rangos de 10 MB.** YouTube frena las peticiones con rango abierto (`Range: bytes=0-`, lo que pide FFmpeg) de archivos
  de más de ~10 MB: medido con curl, el video a 300–475 KB/s y el audio hasta 30 KB/s, contra ~15 MB/s pidiendo rangos de
  10 MB con las mismas URLs. Si el freno queda por debajo del pico del video, se atasca (un segundo de video cada 20 s).
  Por eso MPVBridge pone `stream-lavf-o=request_size=10485760` (y `curl-max-request-size`), como el ytdl_hook de mpv.
- El reproductor da error claro si la resolución pasa de 45 s o mpv no muestra imagen en 30 s.

## Qué funciona (probado el 24-oct-2026 en esta PC)

- Ventana con acabado Vidrio (DesktopAcrylicBackdrop, o Mica si no hay acrílico), tema y acento de Windows. Barra de
  título integrada de 48 px: atrás, menú, búsqueda centrada (Ctrl+K, con resultados) y la cuenta. Panel lateral propio y
  flotante (Inicio, Suscripciones con el contador de no vistos, Biblioteca, Historial, los canales suscritos y
  Configuración): solo iconos por debajo de 1000 DIP y encima del contenido por debajo de 640. El Frame ocupa toda la
  ventana; las páginas `IFullBleedPage` (Inicio, reproductor) van detrás del panel y de la barra y usan
  `MainWindow.ContentInset` y `SetTitleBarStyle`.
- Inicio en estilo Cine: portada con el video más nuevo de Suscripciones (miniatura con máscara que se funde con el
  acrílico), filas de Continuar viendo, Nuevos de tus canales y En vivo ahora, y "Para ti" (el Inicio de la cuenta) en la
  cuadrícula con carga incremental. Tarjetas con barra de lo visto y EN VIVO.
- Suscripciones como Bandeja: agrupadas por día, pestañas Sin ver / Más tarde / Archivados, vista previa con descripción y
  capítulos, J/K, Intro, W, E y Mayús+U; al volver del reproductor queda visto y pasa al siguiente. Elegir un canal del
  panel filtra la Bandeja. Visto y archivado van en `%LOCALAPPDATA%\Glasstube\inbox.json`; historial y Ver más tarde en
  la biblioteca local de GlasstubeCore.
- Reproductor a ventana completa con la cápsula de controles flotante: clic en una tarjeta → resuelve (~2–3 s) y reproduce
  1080p60 VP9 con decodificación por hardware (d3d11va), desde donde se quedó (guarda la posición cada 10 s, al salir y al
  cerrar). Reproducir/pausa (espacio o K), −10/+10 s (botones, J/L), ←/→ ±5 s, volumen y silencio (M), calidad que da mpv
  («1080p60»), pantalla completa (F o doble clic) y mini reproductor siempre encima (I; Esc o doble clic vuelve). Barra
  partida por capítulos con el capítulo actual junto al canal, segmentos de SponsorBlock sombreados y «Saltar patrocinio»
  (o intro, créditos…) con botón o S, sin salto automático. Controles, título, botón de atrás y cursor se ocultan a los 3 s.
- `--probar-ffi` anota en el registro un resumen de Suscripciones, biblioteca, detalles y búsqueda.
- `--tema claro|oscuro` fuerza el tema (capturas); sin él sigue al de Windows.
- Aviso de versiones nuevas (`Models/UpdateCheck.cs`), como el de la Mac: al abrirse, como mucho una vez al día, busca
  en GitHub la Release `windows-v…` más nueva (sin borradores ni prereleases) y, si es más nueva que la del exe, avisa
  abajo a la derecha con «Descargar» (abre su página) y «Ahora no». `--sin-aviso-de-versiones` no consulta.
- GlasstubeCore compila en Windows (antes solo se había probado en Linux); la FFI usa `cardSubtitle` y `durationBadge`.

## Qué falta

- **SABR.** El reproductor usa URLs directas (cliente TV_DOWNGRADED hoy). Si YouTube deja de darlas, hay que llevar
  `SabrMediaSource` de PlaybackKit a la FFI (mpv leyendo por `stream_cb`), como en la app de Mac.
- Calidad elegible, subtítulos y reportar el historial a YouTube (`watchtime`).
- Página del video: descripción, comentarios, sugeridos y siguiente automático.
- Biblioteca e Historial como páginas, página de canal, ajustes, iniciar y cerrar sesión desde la app (hoy se usa la sesión
  que dejó `ytkit signin`). Grupos de canales: se muestran si GlasstubeCore tiene alguno, pero no se crean desde aquí.
- Atajos de volumen; recordar tamaño de ventana.
- Errores de red con reintento en el Inicio (hoy un aviso y el botón de actualizar).
- Firma del instalador y del exe (sin ella SmartScreen avisa) y actualizaciones automáticas. El runtime de Swift se copia entero (se puede recortar).
- `gt_pump` con temporizador: se podría despertar solo cuando la cola tiene trabajo
  (`_dispatch_get_main_queue_handle_4CF`).
