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
  abre con `audio-files`, el `User-Agent` del cliente y `Origin`/`Referer`. Los directos usan el manifiesto HLS.
- **Video.** `d3d11-output-mode=composition`: mpv crea su swapchain, el puente la lee de `display-swapchain` y la pone con
  `ISwapChainPanelNative::SetSwapChain`. El tamaño en píxeles físicos va a `d3d11-composition-size` y la escala con
  `SetMatrixTransform`. El manifiesto declara PerMonitorV2 (sin él, todo sale borroso al 125 %).

## Qué funciona (probado el 23-oct-2026 en esta PC)

- Ventana con Mica, barra de título propia, `NavigationView` (Inicio; Suscripciones y Biblioteca como «Próximamente») y la
  cuenta elegida al pie del panel.
- Inicio real de la cuenta: cuadrícula adaptable (columnas de al menos 260 DIP), miniatura, duración, título, canal, vistas y
  fecha; carga más al llegar al final; botón de actualizar.
- Reproductor: clic en una tarjeta → resuelve (~2–3 s) y reproduce 1080p60 VP9 con decodificación por hardware (d3d11va).
  Reproducir/pausa, barra de progreso (clic y arrastre), volumen y silencio, pantalla completa (botón, F o doble clic, Esc
  para salir), ←/→ ±5 s, volver (botón propio, el de la `NavigationView` o Esc). Los controles se ocultan a los 3 s.
- GlasstubeCore compila en Windows (antes solo se había probado en Linux); la FFI usa `cardSubtitle` y `durationBadge`.

## Qué falta

- **SABR.** El reproductor usa URLs directas (cliente TV_DOWNGRADED hoy). Si YouTube deja de darlas, hay que llevar
  `SabrMediaSource` de PlaybackKit a la FFI (mpv leyendo por `stream_cb`), como en la app de Mac.
- Calidad elegible, subtítulos, capítulos, SponsorBlock, reanudar donde se quedó y reportar el historial (`watchtime`).
- Página del video: descripción, comentarios, sugeridos y siguiente automático.
- Suscripciones, Biblioteca, búsqueda, canales, ajustes, iniciar y cerrar sesión desde la app (hoy se usa la sesión que dejó
  `ytkit signin`).
- Ocultar el cursor con los controles ocultos; atajos de volumen; recordar tamaño de ventana.
- Errores de red con reintento en el Inicio (hoy un aviso y el botón de actualizar).
- Empaquetado MSIX, icono, instalador y firma. El runtime de Swift se copia entero (se puede recortar).
- `gt_pump` con temporizador: se podría despertar solo cuando la cola tiene trabajo
  (`_dispatch_get_main_queue_handle_4CF`).
