#pragma once
#include <stdint.h>

// GlasstubeFFI.dll: YTKit + GlasstubeCore (Swift) para la interfaz de Windows. Implementación en
// Sources/GlasstubeFFI/ (GlasstubeFFI.swift: motor, sesión, Inicio y streams; Cards.swift: biblioteca local y Bandeja;
// Subscriptions.swift, Details.swift y Search.swift; desde la 0.3, Quality.swift, Captions.swift, WatchNext.swift y
// Comments.swift; Account.swift: cuenta en el reproductor; Channel.swift: canales, listas y páginas siguientes;
// LibraryPages.swift: Historial y Biblioteca; SignIn.swift: iniciar y cerrar sesión).
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

/// "GlasstubeFFI 0.3.0". Se libera con gt_free.
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
/// Desde la 0.3, también "qualities": [{"height", "fps", "label"}] (de mayor a menor, las que trae el cliente elegido),
/// "audioTracks": [{"id", "name", "isDefault"}] (vacío si hay una sola) y "audioTrackId" (la pista de `audio`).
void gt_resolve_stream(const char *video_id, int32_t max_height, gt_callback callback, void *context);
/// Como gt_resolve_stream con la pista de audio `audio_track_id` (un "id" de "audioTracks"; NULL = la predeterminada).
void gt_resolve_stream_with(const char *video_id, int32_t max_height, const char *audio_track_id, gt_callback callback,
                            void *context);

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
/// Resultados de búsqueda (solo videos): {"items", "hasMore", "notice", "signedIn", "channels"}, con "channels" (0.4) =
/// [{"id", "title", "handle", "avatar", "subscribers"}] de la primera página.
void gt_search(const char *query, gt_callback callback, void *context);
void gt_search_more(gt_callback callback, void *context);

// MARK: Reproductor (0.3)

/// Subtítulos: {"videoId", "tracks": [{"languageCode", "name", "title", "isAutomatic", "url"}]}, con `url` en WebVTT
/// (para `sub-add` de mpv). Sin subtítulos, `tracks` vacío.
void gt_captions(const char *video_id, gt_callback callback, void *context);
/// Sugeridos y comentarios: {"videoId", "suggestions": [VideoCard…], "next": VideoCard | null, "commentsToken",
/// "commentsCount", "commentSorts": [{"title", "token", "isSelected"}]}. `next` es el de la reproducción automática.
void gt_watch_next(const char *video_id, gt_callback callback, void *context);
/// Una página de comentarios: {"comments": [{"id", "author", "authorChannelId", "avatar", "text", "published", "likes",
/// "replyCount", "replyCountText", "repliesToken", "isPinned", "isHearted", "authorIsChannelOwner"}], "continuation"}.
/// `replies` 0: `token` es "commentsToken", el de un orden o una "continuation"; 1: el "repliesToken" de un comentario
/// (sus respuestas, sin él).
void gt_comments(const char *token, int32_t replies, gt_callback callback, void *context);

// MARK: Cuenta en el reproductor (Account.swift)

/// Estado de la cuenta en un video: {"videoId", "signedIn", "likeStatus" ("like" | "dislike" | "indifferent" | null),
/// "isSubscribed" (null sin sesión), "subscribeParams", "channelId", "channel", "channelAvatar", "subscribers",
/// "likeCountText", "likes", "dislikes"}. `likes` y `dislikes` son de Return YouTube Dislike (null si no respondió).
void gt_video_account(const char *video_id, gt_callback callback, void *context);
/// Me gusta: `status` 1 = me gusta, -1 = no me gusta, 0 = ninguno; `previous` es el estado anterior (para quitarlo).
/// Necesita sesión. Responde {"likeStatus"}.
void gt_set_like(const char *video_id, int32_t status, int32_t previous, gt_callback callback, void *context);
/// Suscribirse (`subscribe` 1) o anularla (0). `params`: el "subscribeParams" que se tenga, o NULL. Responde
/// {"isSubscribed"}.
void gt_subscribe(const char *channel_id, int32_t subscribe, const char *params, gt_callback callback, void *context);
/// {"signedIn", "isSubscribed", "params"} de un canal (`isSubscribed` null sin sesión).
void gt_subscription_state(const char *channel_id, gt_callback callback, void *context);

// MARK: Canales y listas (Channel.swift, 0.4)
//
// Las listas van como VideoCard con "playlistId" (y su id en "id"; "duration" lleva el número de videos). Las páginas
// paginadas traen "feed": se pasa a gt_feed_more para la siguiente, que trae otro "feed" (null al final).

/// Un canal ("UC…" o "@handle") con una pestaña (`tab`: "videos", "shorts", "live", "playlists"; NULL = videos):
/// {"channelId", "title", "handle", "description", "subscribers", "videoCount", "avatar", "banner", "tabs": [string],
/// "tab", "items": [VideoCard…], "hasMore", "feed"}.
void gt_channel(const char *channel_id, const char *tab, gt_callback callback, void *context);
/// Los videos de una lista ("PL…", "WL", "LL"…): {"playlistId", "title", "items", "hasMore", "feed"}.
void gt_playlist(const char *playlist_id, gt_callback callback, void *context);
/// Más elementos de una página paginada: {"items", "hasMore", "feed"}.
void gt_feed_more(const char *feed, gt_callback callback, void *context);

// MARK: Historial y Biblioteca (LibraryPages.swift, 0.4)

/// Quita un video del historial local. Responde {}.
void gt_history_remove(const char *video_id, gt_callback callback, void *context);
/// Borra todo el historial local (y lo escribe en disco ya). Responde {}.
void gt_history_clear(gt_callback callback, void *context);
/// La Biblioteca de la cuenta: {"signedIn", "playlists": [VideoCard con "playlistId"…], "watchLater": [VideoCard…],
/// "watchLaterFeed", "notice"}. Sin sesión, listas vacías y "signedIn" false.
void gt_account_library(gt_callback callback, void *context);

// MARK: Iniciar y cerrar sesión (SignIn.swift, 0.5)

/// Las cuentas guardadas: {"signedIn", "accounts": [{"id", "name", "byline", "avatar", "isBrand", "isSelected"}]}.
void gt_accounts(gt_callback callback, void *context);
/// Pide un código para youtube.com/activate: {"userCode", "verificationUrl", "expiresIn"} (segundos).
void gt_sign_in_begin(gt_callback callback, void *context);
/// Espera a que la persona apruebe el último código y guarda la sesión. Responde como gt_accounts; falla si el código
/// vence, si lo rechazan o tras gt_sign_in_cancel ("cancelado").
void gt_sign_in_wait(gt_callback callback, void *context);
/// Deja de esperar el código.
void gt_sign_in_cancel(void);
/// Elige una cuenta guardada. Responde como gt_accounts.
void gt_select_account(const char *account_id, gt_callback callback, void *context);
/// Cierra la sesión de Google de esa cuenta (con sus cuentas de marca); NULL = todas. Responde como gt_accounts.
void gt_sign_out(const char *account_id, gt_callback callback, void *context);

#ifdef __cplusplus
}
#endif
