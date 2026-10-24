#pragma once
#include <stdint.h>

// GlasstubeFFI.dll: YTKit + GlasstubeCore (Swift) para la interfaz de Windows. Implementación en
// Sources/GlasstubeFFI/ (GlasstubeFFI.swift: motor, sesión, Inicio y streams; Cards.swift: biblioteca local y Bandeja;
// Subscriptions.swift, Details.swift y Search.swift).
//
// Reglas:
// - Lo asíncrono responde por `gt_callback`: status 0 = bien y `json` es el resultado; distinto de 0 = error y `json` es
//   {"error": "…"}. `json` (UTF-8, terminado en 0) solo vale durante la llamada: el cliente lo copia.
// - Los callbacks corren en el actor principal de Swift, que es la cola principal de libdispatch, y esa cola solo
//   avanza dentro de `gt_pump()`. La app llama a `gt_pump()` desde su hilo principal con un temporizador (~15 ms), así
//   que los callbacks llegan en el hilo de la interfaz.
// - La primera llamada a la DLL debe hacerse desde el hilo principal del proceso.
// - Las cadenas de entrada se copian antes de volver: el cliente puede soltarlas al regresar la llamada.

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*gt_callback)(void *context, int32_t status, const char *json);

/// Crea el motor: catálogo de clientes, sesión guardada (Administrador de credenciales) y servicio. `language` y
/// `region` del catálogo ("es-419", "MX"); NULL = los del sistema.
/// Responde {"language", "region", "version"}.
void gt_init(const char *language, const char *region, gt_callback callback, void *context);

/// Ejecuta los trabajos pendientes del actor principal (y entrega los callbacks). Solo desde el hilo principal.
void gt_pump(void);

/// Suelta el motor.
void gt_shutdown(void);

/// "GlasstubeFFI 0.1.0". Se libera con gt_free.
char *gt_version(void);
void gt_free(char *string);

/// Registro en %LOCALAPPDATA%\Glasstube\logs\glasstube.log (YTKit, la FFI y lo que mande el cliente). Una app de
/// ventana no tiene stderr: todo lo que antes iba ahí va a este archivo. Desde cualquier hilo.
void gt_log(const char *source, const char *message);
/// Carpeta del registro. Se libera con gt_free.
char *gt_log_directory(void);

/// Sesión guardada: {"signedIn", "selected": {"name", "byline", "avatar", "isBrand"} | null, "accountCount"}.
void gt_load_session(gt_callback callback, void *context);

/// Inicio (con sesión, el de la cuenta). {"items": [VideoCard…], "hasMore", "notice", "signedIn"}, con
/// VideoCard = {"id", "title", "channel", "channelId", "thumbnail", "duration", "views", "published", "subtitle",
/// "isLive", "shelf", "thumbnailLarge", "avatar", "durationSeconds", "publishedAt", "position", "progress"}. Solo
/// videos (sin Shorts, canales ni listas), sin repetir. `publishedAt` (segundos Unix) es aproximado: sale del texto
/// relativo. `position` y `progress` (0–1) vienen de la biblioteca local.
void gt_home(gt_callback callback, void *context);

/// Página siguiente del Inicio, con la misma forma (items vacío y hasMore false al final).
void gt_home_more(gt_callback callback, void *context);

/// URLs para mpv: {"videoId", "title", "author", "client", "video": Track | null, "audio": Track | null,
/// "hls": string | null, "durationSeconds", "userAgent", "headers": {…}}, con Track = {"url", "itag", "codec", "label",
/// "height"}. `max_height` 0 = 1080.
void gt_resolve_stream(const char *video_id, int32_t max_height, gt_callback callback, void *context);

// MARK: Suscripciones (con sesión)

/// Videos nuevos de los canales suscritos, del más reciente al más viejo, y los canales:
/// {"items": [VideoCard…], "hasMore", "channels": [{"id", "name", "avatar", "hasNew"}],
/// "groups": [{"id", "title", "channels": [id…]}], "notice", "signedIn"}. `hasNew`: YouTube marca el canal con
/// contenido nuevo. `groups` son los grupos locales de GlasstubeCore (vacío si no hay).
void gt_subscriptions(gt_callback callback, void *context);
/// Página siguiente: {"items", "hasMore", "notice", "signedIn"}.
void gt_subscriptions_more(gt_callback callback, void *context);

// MARK: Biblioteca local (GlasstubeCore LocalLibrary) y Bandeja (%LOCALAPPDATA%\Glasstube\inbox.json)

/// {"history": [VideoCard…], "continueWatching": [VideoCard…], "watchLater": [VideoCard…], "seen": [id…],
/// "archived": [id…]}.
void gt_library(gt_callback callback, void *context);
/// Guarda la posición de `card` (una VideoCard en JSON) en el historial. Responde {}.
void gt_library_record(const char *card, double position, double duration, gt_callback callback, void *context);
/// Escribe la biblioteca en disco ya. Responde {}.
void gt_library_save(gt_callback callback, void *context);
/// {"position", "duration"} guardados de un video (0 si no hay).
void gt_saved_position(const char *video_id, gt_callback callback, void *context);
/// Pone o quita `card` de Ver más tarde. Responde {"inWatchLater"}.
void gt_watch_later_toggle(const char *card, gt_callback callback, void *context);
/// Visto y archivado en la Bandeja: 1 sí, 0 no, -1 sin cambio. Responde {"seen", "archived"}.
void gt_inbox_set(const char *video_id, int32_t seen, int32_t archived, gt_callback callback, void *context);

// MARK: Video y búsqueda

/// {"videoId", "title", "description", "author", "channelId", "avatar", "views", "published",
/// "chapters": [{"title", "start"}], "segments": [{"start", "end", "category", "title"}]} (segundos; SponsorBlock).
void gt_video_details(const char *video_id, gt_callback callback, void *context);
/// Resultados de búsqueda (solo videos): {"items", "hasMore", "notice", "signedIn"}.
void gt_search(const char *query, gt_callback callback, void *context);
void gt_search_more(gt_callback callback, void *context);

#ifdef __cplusplus
}
#endif
