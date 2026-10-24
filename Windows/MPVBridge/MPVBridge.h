#pragma once
#include <stdint.h>

// MPVBridge.dll: libmpv dentro de un SwapChainPanel de WinUI 3 (d3d11-output-mode=composition). mpv crea su propia
// swapchain de composición; el puente la lee de `display-swapchain` y la pone en el panel con
// ISwapChainPanelNative::SetSwapChain. Sale del spike de winui-spike (step4-video), con un handle por reproductor y
// los controles del reproductor de la app.
//
// Todas las funciones, desde el hilo de la interfaz.

#ifdef MPVB_BUILD
#define MPVB_API __declspec(dllexport)
#else
#define MPVB_API __declspec(dllimport)
#endif

typedef struct mpvb_player mpvb_player;

/// Recibe cada línea de registro del puente y los avisos/errores de mpv (en el hilo que llama a mpvb_poll).
typedef void (*mpvb_logger)(const char *line);
MPVB_API void mpvb_set_logger(mpvb_logger callback);

/// Estado para la interfaz (se lee en cada `mpvb_poll`).
typedef struct mpvb_state {
    double position;   // segundos
    double duration;   // segundos (0 si aún no se sabe)
    double buffered;   // segundos por delante de la posición en caché
    double volume;     // 0–100
    int32_t paused;
    int32_t idle;      // sin archivo (terminó o falló)
    int32_t buffering; // esperando datos
    int32_t has_video; // ya hay swapchain en el panel
    int32_t ended;     // llegó al final
    int32_t error;     // el archivo falló (end-file con error)
    int32_t file_loads; // archivos abiertos (FILE_LOADED) desde mpvb_create: cambia en cada loadfile que abre
} mpvb_state;

/// `panel` es el IInspectable* del SwapChainPanel (WinRT.MarshalInterface en C#). Tamaño en píxeles físicos y escala
/// DIP→píxel del panel (CompositionScaleX).
MPVB_API mpvb_player *mpvb_create(void *panel, int32_t width, int32_t height, float scale);
/// Abre un video: `url` (video, o HLS/combinado), `audio_url` opcional (pista de audio aparte), `user_agent` y
/// `headers` ("Clave: valor" separados por '\n'). 0 = bien.
MPVB_API int32_t mpvb_load(mpvb_player *player, const char *url, const char *audio_url, const char *user_agent,
                           const char *headers, double start_seconds);
/// Vacía los eventos de mpv, engancha la swapchain si cambió y rellena `state`.
MPVB_API void mpvb_poll(mpvb_player *player, mpvb_state *state);
MPVB_API void mpvb_resize(mpvb_player *player, int32_t width, int32_t height, float scale);
MPVB_API void mpvb_set_pause(mpvb_player *player, int32_t paused);
MPVB_API void mpvb_seek(mpvb_player *player, double seconds);
MPVB_API void mpvb_set_volume(mpvb_player *player, double volume);
/// Velocidad de reproducción (propiedad `speed`, 0.1–4). Se mantiene entre archivos.
MPVB_API void mpvb_set_speed(mpvb_player *player, double speed);
/// Cualquier propiedad de mpv como cadena ("sub-margin-y", "sub-font-size"…). Asíncrono.
MPVB_API void mpvb_set_property(mpvb_player *player, const char *name, const char *value);
/// Subtítulos externos: quita la pista externa seleccionada y, si hay `url` (WebVTT u otro que lea mpv), la añade
/// seleccionada con `title` y `language`. `url` NULL o vacía = sin subtítulos. Asíncrono; las descargas usan las
/// cabeceras y el User-Agent del video. `loadfile` los descarta: hay que volver a ponerlos tras cargar otro archivo.
MPVB_API void mpvb_set_subtitle(mpvb_player *player, const char *url, const char *title, const char *language);
/// Altura del video (0 si aún no se sabe) y cuadros por segundo del contenedor (0 si no se saben), para mostrar la
/// calidad ("1080p60"). Son propiedades observadas: no bloquea esperando al núcleo de mpv.
MPVB_API void mpvb_video_format(mpvb_player *player, int32_t *height, double *fps);
/// Última línea de error de mpv (vale hasta la siguiente llamada).
MPVB_API const char *mpvb_last_error(mpvb_player *player);
MPVB_API void mpvb_destroy(mpvb_player *player);
