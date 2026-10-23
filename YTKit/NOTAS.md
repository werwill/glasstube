# YTKit: notas de las fases 1 (red y catálogo), 2 (cuentas), 3 (comunidad), 4 (control remoto y enlaces) y 5a (organizar y descubrir)

Fecha: 15-oct-2026 (fase 3: 16-oct-2026). Mac M1 Pro, macOS 27.0.1, Swift 6.4 con Command Line Tools (sin Xcode). Red doméstica en México,
`hl=es-419`, `gl=MX`. La fase 1 se probó sin sesión; la fase 2 con una cuenta de prueba del dueño del proyecto (una
personal con una cuenta de marca), ver [Cuentas (fase 2)](#cuentas-fase-2). La fase 3 (comentarios, chat en vivo,
DeArrow y Return YouTube Dislike) se probó sin sesión, ver [Comunidad (fase 3)](#comunidad-fase-3).

## Resumen

`YTKit` es el paquete Swift, sin interfaz, que habla con YouTube. Tiene tres partes:

- **Streams y SABR**, portados de `glasstube-spike`: perfiles de cliente, `/player`, la rotación de clientes, la firma y
  `n` en JavaScriptCore, el PoToken en WKWebView y el cliente SABR/UMP.
- **Catálogo**, nuevo: Inicio, Tendencias y Explorar, búsqueda con sugerencias, canal por pestañas, listas y `next`
  (metadatos, descripción, capítulos, mapa de calor, sugeridos), todo paginado con `continuation`.
- **Contrato**: los protocolos `ContentService`, `MediaItemService` y `SignInService`, que reflejan
  `mediaserviceinterfaces` de SmartTube con async/await.
- **Cuentas** (fase 2): inicio de sesión por código como la app de TV, sesiones en el Llavero, cuentas de marca,
  peticiones con la cuenta y todo lo que depende de ella. Ver [Cuentas (fase 2)](#cuentas-fase-2).
- **Comunidad** (fase 3): comentarios con respuestas y paginación, chat en vivo, DeArrow y Return YouTube Dislike. Ver
  [Comunidad (fase 3)](#comunidad-fase-3).
- **Control remoto y enlaces** (fase 4): la Mac como «pantalla» de Lounge para la app de YouTube del teléfono, y el
  lector de enlaces de YouTube y `glasstube://`. Ver [Control remoto y enlaces (fase 4)](#control-remoto-y-enlaces-fase-4).

Lo más importante que salió de probar contra YouTube:

1. **Sin cuenta, el Inicio viene vacío en TV y en WEB.** YouTube manda solo un aviso para iniciar sesión o activar el
   historial. YTKit arma un Inicio con las dos primeras filas de cada tema de Explorar (Música, Videojuegos,
   Noticias, Deportes y En vivo) y lo marca con `BrowsePage.isFallback`.
2. **YouTube ya no tiene Tendencias.** `FEtrending` responde HTTP 400 en TV y en WEB, con y sin los `params` de
   SmartTube; `FEexplore` también. YTKit usa en su lugar la clasificación de Hype (`FEhype_leaderboard`), que sí
   responde sin cuenta.
3. **Para escritorio conviene la vista WEB** (`SurfacePreferences.recommended`). La de TV sigue disponible en todo con
   `SurfacePreferences.tv`, que es lo que hace SmartTube. El detalle está en [TV o WEB](#tv-o-web).
4. **Las respuestas se decodifican en un hilo con pila de 16 MB.** Los árboles de renderers son profundos y, con la
   pila de 512 KB de los hilos secundarios, el proceso moría con SIGBUS. Pasaba en las pruebas y también pasaría en
   el pool de Swift Concurrency de la app (`InnertubeDecoding`).

## Estructura

| Carpeta | Contenido | Equivalente en SmartTube |
|---|---|---|
| `Sources/YTKit/Core` | `HTTP` (URLSession, caché en disco), `Protobuf`, `ClientProfile` + `clients.json`, `Innertube` (`/player`, `/tv`, `visitor_id`) | `RetrofitHelper`, `AppClient`, `QueryBuilder` |
| `Sources/YTKit/Streams` | `PlayerScript`, `ChallengeSolver` (JavaScriptCore), `PoTokenProvider` (WKWebView, web y TV), `StreamResolver`, `Formats` | `VideoInfoService`, `V8ChallengeProvider`, `PoTokenWebView4`, `TvPoTokenProvider` |
| `Sources/YTKit/Sabr` | `Sabr` (`SabrSession`, `SabrSink`, `SabrPlaybackClock`), `SabrTransport`, `UMP` | `SabrManifest`, `SabrStream`, `UMPDecoder`, `ReloadPlaybackGate` |
| `Sources/YTKit/Catalog` | modelos tolerantes, recorrido de páginas, `next`, canal, red del catálogo, protocolos e implementación | `browse/v2`, `search/v2`, `next/v2`, `common/models`, `mediaserviceinterfaces` |
| `Sources/YTKit/Account` | `OAuth` (código de dispositivo, renovación, revocación), `CredentialStore` (Llavero), `AccountManager`, `AccountService` (feeds y acciones), `WatchTime` | `auth/V2`, `googleapi/oauth2`, `YouTubeSignInService`, `YouTubeAccountManager`, `ActionsApi`, `PlaylistApi`, `FeedbackApi`, `PanelApi`, `track/TrackingService` |
| `Sources/YTKit/Catalog/Comments.swift`, `LiveChat.swift` | comentarios (`CommentsService`) y chat en vivo (`LiveChatService`), fase 3 | `comments`, `chat`, `CommentsController`, `ChatController` |
| `Sources/YTKit/Community` | `DeArrowClient` (títulos y miniaturas de la comunidad) y `DislikeClient` (Return YouTube Dislike), fase 3 | `dearrow/DeArrowService`, `WatchNextApi.getDislikes` |
| `Sources/YTKit/Lounge` | `LoungeScreen` (código, canal `bc/bind` con reconexión, comandos y reportes), `LoungeModels`, `LoungeWire` (lector del canal), fase 4 | `lounge/*`, `YouTubeRemoteControlService` |
| `Sources/YTKit/Links` | `YouTubeLink`: enlaces de YouTube y `glasstube://`, fase 4 | `IntentExtractor` (app) |
| `Sources/ytkit-cli` | CLI `ytkit` de verificación (con y sin cuenta) y los grabadores anonimizados | — |
| `Tests/YTKitTests` | 77 pruebas de Swift Testing sobre 45 respuestas grabadas en `Fixtures/`: 34 páginas (6 con cuenta), las sugerencias, 3 de cuenta en `Fixtures/cuenta/` y 7 de la fase 3 en `Fixtures/comunidad/`; las de cuenta y las de personas (comentarios, chat), anonimizadas | — |

### Qué se portó del spike y qué cambió

- Los archivos se copiaron sin cambios a sus carpetas nuevas. glasstube-spike sigue compilando igual y no se tocó.
- `clients.json` (versión 2): la rotación empieza en **TV_DOWNGRADED y sigue con VISIONOS** (`defaultStart`), como pide
  la recomendación 1 de RESULTADOS.md. `ytkit formats dQw4w9WgXcQ` resolvió en 1,7 s con TV_DOWNGRADED al primer
  intento, con firma y `n` resueltas por JavaScriptCore (27 de 27) y VP9 2160p25 más Opus.
- **No se trajeron** `SabrStreamBuffer`/`SabrStreamPair` (el búfer bloqueante para `mpv_stream_cb`) ni `CMPV`: son de
  mpv y le tocan a PlaybackKit. `SabrSink` sí está en YTKit; es el punto de enganche.
- PlaybackKit usa este paquete desde el 15-oct-2026 (sesión de la app): `YouTubeSource` depende de YTKit y su copia
  interna se borró. Para eso se agregó, con lo público mínimo: el protocolo `SabrClock` (lo que `SabrSession.stream`
  necesita del reloj del reproductor; `SabrPlaybackClock` lo cumple), `SabrError.init`, y en `YouTubeService` el
  `poTokenSource` y un `resolver` único por servicio, para que catálogo y reproductor compartan un solo
  `PoTokenWebViewProvider`. Detalle en PlaybackKit/NOTAS.md («YTKit (unificado…)»).

## Contrato

| SmartTube (`mediaserviceinterfaces`) | YTKit | Sin cuenta |
|---|---|---|
| `ContentService.getHome` | `home()` | Inicio sustituto (temas de Explorar) |
| `getTrendingObserve` | `trending()` | Hype, porque `FEtrending` da 400 |
| `getMusic`, `getGaming`, `getNews`, `getSports`, `getLive`, `getMovies` | `topic(_:)` | sí |
| `getSearch(text[, options])` | `search(_:params:)` | sí (`params` = filtro `sp` crudo) |
| `getSearchTags` | `searchSuggestions(_:)` | sí |
| `getChannel`, `getChannelAsGrid` | `channel(_:tab:)` (UC…, @handle o URL) | sí |
| `getGroup(mediaItem)` de una lista | `playlist(_:)` | sí |
| `continueGroup` | `continueGroup(_:)` | sí |
| `getGroup(reloadPageKey)` | `continuePage(_:)` | sí |
| `getSubscriptions`, `getHistory`, `getPlaylists` | `subscriptions()`, `history()`, `playlists()`, más `watchLater()` | con cuenta (TV) |
| `MediaItemService.getMetadata` | `metadata(videoId:playlistId:playlistIndex:params:)`, `metadata(for:)` | sí |
| `getFormatInfo` | `formatInfo(videoId:options:)` → `ResolveReport` | sí |
| `setLike`, `removeLike`, `setDislike`, `removeDislike` | igual | con cuenta |
| `subscribe`, `unsubscribe` | `subscribe(channelId:[params:])`, `unsubscribe(channelId:)`, más `subscriptionState(channelId:)` (cabecera del canal por TV) | con cuenta |
| `getPlaylistsInfo`, `addToPlaylist`, `removeFromPlaylist` | `playlistsInfo(videoId:)`, `addToPlaylist(playlistId:videoId:)`, `removeFromPlaylist(…)`, más `createPlaylist`, `deletePlaylist` | con cuenta |
| `updateHistoryPosition` | `updateHistoryPosition(videoId:positionSeconds:)` | con cuenta |
| `markAsNotInterested` | `markAsNotInterested(feedbackToken:)`, `markAsNotInterested(_ item:)` | con cuenta |
| `enableHistory` | `setWatchHistoryEnabled(_:)` | con cuenta (sin probar) |
| `SignInService.signInObserve` | `beginSignIn()` + `completeSignIn(_:)` | — |
| `getAccounts`, `getSelectedAccount`, `selectAccount`, `removeAccount`, `addOnAccountChange` | `load()`, `select(accountId:)`, `signOut(accountId:revoke:)`, `signOutAll()`, `updates()` | — |

Sin sesión, los métodos con cuenta lanzan `YTKitError.signInRequired`. Las variantes RxJava (`…Observe`) no hacen falta
con async/await. `YouTubeService` implementa `ContentService` y `MediaItemService` (con `session:` para la cuenta) y
`AccountManager` implementa `SignInService`; los métodos del catálogo tienen además una variante con `surface:` para
elegir TV o WEB a mano.

Modelos públicos (`Models.swift`): `MediaItem` (video, canal, lista o mix, con `isLive`, `isShort`, `isUpcoming`; con
cuenta, `feedbackToken` y `menuPanel`), `MediaGroup` (fila con su `Continuation`), `BrowsePage`, `ChannelPage` con
`ChannelTab`, `MediaItemMetadata` con `Chapter` y `HeatMarker` (con cuenta, `likeStatus`, `isSubscribed` y
`subscribeParams`), y `ParseStats`. De la cuenta: `Account`, `AccountSnapshot`, `DeviceCode`, `PlaylistInfo` y
`LikeStatus`. Todos son `Codable` y `Sendable`. Un `Continuation` guarda el token, el
endpoint y la interfaz, porque un token de TV solo vale con el cliente de TV.

## Cuentas (fase 2)

### Lo que se verificó contra YouTube (15-oct-2026)

1. **El flujo de código de dispositivo de la app de TV sigue funcionando**, como lo usa SmartTube (`auth/V2`): el
   `client_id`/`client_secret` de Android TV sigue en el `base.js` de youtube.com/tv (la primera coincidencia de
   `ClientData`); `POST https://www.youtube.com/o/oauth2/device/code` (JSON con `client_id`, `device_id`,
   `model_name: "ytlr::"` y el scope `http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content`)
   da HTTP 200 con `user_code`, `device_code`, `expires_in` 1800 e `interval` 5; el sondeo a `/o/oauth2/token` con
   `grant_type http://oauth.net/grant_type/device/1.0` responde `authorization_pending` y luego `expired_token` si nadie
   lo autoriza, o el refresh token cuando la persona escribe el código en youtube.com/activate. Google devuelve
   `verification_url = https://www.google.com/device`; las dos direcciones sirven. El dueño autorizó con su cuenta de
   prueba: la sesión trajo una cuenta personal y una de marca.
2. **La sesión de TV solo vale con el cliente TV.** Con el cliente WEB y `Authorization: Bearer …`, YouTube responde
   HTTP 400 `INVALID_ARGUMENT` a `browse` y a `next` (lo mismo en Suscripciones, Historial, Playlists, Ver más tarde,
   el Inicio y `next`). Con TVHTML5 todo funciona. Por eso:
   - las páginas de la cuenta, las acciones y `accounts_list` van siempre por TV;
   - con sesión, `home()` pide el Inicio de la cuenta por TV (recomendaciones de verdad, ya no el sustituto);
   - `metadata()` con `preferences.next == .web` hace en paralelo el `next` de WEB (anónimo, con los metadatos ricos) y
     uno de TV con la cuenta para `likeStatus`, `isSubscribed` y `subscribeParams`;
   - `playlist(_:)` lleva `WL` y `LL` a TV con la cuenta, y si una lista viene vacía por WEB anónima (privada) la
     reintenta por TV;
   - `CatalogAPI` nunca manda la sesión con WEB: en `.session` la petición WEB va anónima y `.required` con WEB es un
     error.
3. **Suscripciones de TV llegan como ~120 pestañas** (`tvSecondaryNavRenderer.sections[].tabs`): "Todos" (la elegida) y
   una por canal, cada una con su contenido. El parser ahora recorre `sections` y, si hay una pestaña elegida, solo esa.
   "Todos" trae "Más relevantes", tandas de tres videos recientes sin título (que `mergingUntitledRows` junta en
   "Más recientes") y una fila de Shorts.
4. **Lo que se probó con la cuenta**, con `ytkit` y con la app (videos públicos: Big Buck Bunny, Rick Astley, canal
   Blender): Suscripciones (45 elementos y continuación), Historial (15 con progreso y continuación), Playlists (Me
   gusta y Ver más tarde; la de marca, 4), Ver más tarde (15), el Inicio personalizado, me gusta → `LIKE` → quitar →
   `INDIFFERENT`, suscribirse → suscrito → cancelar → no suscrito (YouTube tarda unos segundos en reflejar la baja),
   agregar y quitar de Ver más tarde, `get_add_to_playlist`, la cuenta de marca con `X-Goog-Pageid` (otras
   suscripciones, otro historial) y volver a la personal. Todo se dejó como estaba, salvo el historial de la cuenta
   (quedaron los videos de prueba).
5. **Tiempo visto.** El `/player` con la cuenta necesita `signatureTimestamp` y `visitorData` como el de streams (sin
   ellos: UNPLAYABLE "Se debe volver a cargar la página" y sin `playbackTracking`); se pide con TV_DOWNGRADED. Con las
   URL mínimas de SmartTube (`ei`, `vm`, `of`) YouTube responde 204 y el video entra al Historial, pero queda como
   "empezado". Con las URL completas de `playbackTracking` (como `mark_watched` de yt-dlp) más `cpn`, `cmt`, `st`, `et`,
   `len` y `rt`, reportando en tiempo real cada minuto, YouTube lo marca como visto al pasar de cierto avance (73 % →
   100). Límite: en TV YouTube solo expone `percentDurationWatched` en dos valores (10 = empezado, 100 = visto; 23 %, 46 %
   y 66 % dieron 10) y no hay posición de reanudación en `next` ni en `/player`, así que la posición exacta guardada en
   YouTube no se puede leer; la app reanuda con la posición local, como SmartTube.
6. **"No me interesa".** En Suscripciones el primer `feedbackEndpoint` del menú de la tarjeta es "Ocultar" y en el
   Historial "Quitar del historial" (`MediaItem.feedbackToken`). En el Inicio de TV el menú llega aparte: la tarjeta
   trae `onLongPressCommand.showEngagementPanelEndpoint` (`MediaItem.menuPanel`) y `get_panel` devuelve el menú, donde
   "No me interesa" es la quinta opción con su `feedbackEndpoint` directo (el de "No recomendar el canal" va dentro de una
   confirmación y se ignora). Se verificó que el panel da el token; no se mandó el `feedback` para no cambiar las
   recomendaciones de la cuenta.
7. **Una continuación de TV repite la página**: en Playlists con cuenta, `continueGroup` devolvía las mismas dos listas.
   Ahora `continueGroup` descarta los elementos que la fila ya tiene y, si no llega nada nuevo, termina.

### Cómo funciona

- **Inicio de sesión** (`AccountManager.beginSignIn` → mostrar `DeviceCode.userCode` → `completeSignIn`): sondea cada
  `interval` segundos (más 5 con `slow_down`) hasta autorizar, vencer o rechazar; se cancela con la tarea. Luego pide
  `accounts_list` (`accountReadMask` con dueño y marcas) y elige la cuenta que se activó en youtube.com/activate.
  Volver a entrar con la misma cuenta personal reemplaza la sesión vieja y la revoca.
- **Tokens**: el refresh token y las cuentas van en **un elemento del Llavero** (`kSecClassGenericPassword`, servicio
  `mx.glasstube.cuentas`, cuenta `boveda`), nunca en UserDefaults ni en archivos. El access token vive solo en memoria y
  se renueva cinco minutos antes de su hora de vida (SmartTube: cada hora); las renovaciones simultáneas se juntan en
  una. Ningún log ni mensaje de error incluye tokens: `HTTP` registra solo host y ruta, los cuerpos de OAuth no se
  registran y los errores de estadísticas solo llevan host y ruta.
- **Cuentas de marca**: comparten la sesión de Google; la elegida manda `X-Goog-Pageid` (`pageId` de `accounts_list`).
  `select(accountId:)` cambia de cuenta; `updates()` avisa los cambios.
- **Cerrar sesión**: `signOut(accountId:)` borra del Llavero la sesión de Google de esa cuenta (con sus marcas) y revoca
  el refresh token en `https://oauth2.googleapis.com/revoke` (el token va en el cuerpo, no en la URL). Si Google ya no
  acepta el refresh token (`invalid_grant`), la sesión se quita sola y la app lo avisa.
- **401**: si una petición con la cuenta da 401, se olvida el access token y se reintenta una vez.
- **El catálogo no espera al Llavero** (16-oct-2026): mientras macOS espera el «Permitir» de esa lectura, el actor de
  cuentas queda ocupado; el Inicio (que pregunta primero si hay sesión) se quedaba en «Cargando…» hasta que alguien
  respondiera, y si el aviso quedaba detrás de otra ventana, la app parecía colgada al arrancar. Ahora
  `CatalogAPI.isSignedIn` y la autorización `.session` leen `AccountManager.knownSignedIn` (sin pasar por el actor; nil
  hasta leer el Llavero): mientras no se sabe, las páginas salen anónimas, y al aparecer la sesión `updates()` avisa y la
  app vuelve a pedirlas. Las acciones de cuenta (`.required`) sí esperan. Prueba: `KeychainWaitTests` (un Llavero que
  tarda 5 s; el catálogo responde en menos de 0,5 s). La CLI lee la sesión al arrancar con `--cuenta`.
- **Permiso del Llavero**: la app y `ytkit` van firmados ad hoc, así que macOS identifica a quien lee el elemento por el
  hash del binario. Después de cada compilación, la primera lectura pide permiso ("Permitir siempre" pide la contraseña
  de la Mac; la escribe la persona en el diálogo del sistema). Con una firma de desarrollador estable dejaría de
  pasar.
- **PoToken con sesión**: no hizo falta. El `/player` del tiempo visto, con TV_DOWNGRADED, responde OK sin PoToken.
- **El player de SABR va con la cuenta** (16-oct-2026; antes iba siempre anónimo): ver la sección siguiente.

### «Inicia sesión para confirmar que no eres un bot» (16-oct-2026)

El dueño vio a veces, con sesión iniciada, «player: LOGIN_REQUIRED Inicia sesión para confirmar que no eres un bot».
Causas: el `player` de `SabrSession` iba **siempre anónimo** (la sesión solo se usaba en el catálogo), y YouTube da ese
LOGIN_REQUIRED a peticiones sin cuenta cuando desconfía de la IP o del visitante (el README de SmartTube lo dice así:
«Your IP address range might be temporarily/permanently blocked… if you not signed in»). SmartTube manda la cuenta en el
player del cliente TV (`VideoInfoService`: `client.isAuthSupported() && mUseAuth`). Además, `/tv` (visitante y
`LIVING_ROOM_PO_TOKEN_ID`) se leía una sola vez y se guardaba mientras la app estuviera abierta, así que todos los
videos de una sesión larga iban con el mismo visitante, y si esa lectura fallaba, el error quedaba guardado.

Arreglo:
- `SabrSession.account` (la app pasa su `AccountManager` por `SabrMediaSource(account:)`): con sesión conocida
  (`knownSignedIn`, sin esperar al Llavero) y cliente de TV, el player lleva `Authorization` (y `X-Goog-Pageid`).
- Si el player responde LOGIN_REQUIRED, se pide una vez más con `/tv` y PoToken nuevos (visitante nuevo) y con la
  cuenta si la primera vez todavía no se sabía de ella; si vuelve a fallar, `SabrUnplayableError` (estado, motivo de
  YouTube en el idioma pedido, si fue con la cuenta). LOGIN_REQUIRED también es la respuesta a un video **privado**
  («Este video es privado», visto en la sonda) y a uno con restricción de edad: el segundo intento cuesta ~1–2 s y,
  con la cuenta, puede abrir esos videos si la cuenta tiene acceso.
- `PlayerScriptStore.appInfo()` vuelve a leer `/tv` cada 10 h (como `AppServiceCoreCached` de SmartTube), no guarda
  un fallo, y `renewAppInfo()` lo olvida a pedido.

Verificado: el chequeo real no salió en 60 peticiones anónimas seguidas (`ytkit sabr-player … --veces 6
--sin-recuperar`: todos OK salvo un id privado), así que la recuperación se probó con `--simular-bot N` (las primeras N
respuestas del player son un LOGIN_REQUIRED de prueba, sin pedirlas): con 1, segundo intento con
`livingRoomPoTokenId` distinto y 8 s/9 s de video y audio bajados; con 2, el error con el motivo. Con la cuenta, en la
app: «player con la cuenta» y SABR sirviendo más allá del búfer inicial (Big Buck Bunny de 2:00 a 3:02 sin errores).
Pruebas: `PlayerAccessTests` (LOGIN_REQUIRED de bot y de video privado; el player usa la cuenta solo con sesión
conocida, sin esperar al Llavero, y solo con el cliente TV).

Límite: un video abierto en el primer segundo tras arrancar, mientras el aviso del Llavero espera, va anónimo (no se
sabe todavía si hay sesión); si YouTube responde LOGIN_REQUIRED, el segundo intento ya lleva la cuenta si para entonces
se leyó.

### Pruebas sin tokens ni datos personales

- `AccountTests`: OAuth falso (`TokenService`) y bóveda en memoria (`MemoryCredentialStore`): inicio de sesión, elegir
  la activada, que la bóveda no guarde access tokens, reutilizar y renovar el access token, cuenta de marca con
  `X-Goog-Pageid` al relanzar, cerrar sesión con revocación, sesión revocada que se descarta, `updates()`, el plan de
  peticiones del tiempo visto y la lectura de `playbackTracking`, `client_id` de `base.js`.
- `SignedInPageTests`: cada pantalla con cuenta sobre respuestas reales de TV grabadas con `ytkit record-account`.
- `FixturePrivacyTests`: ninguna fixture tiene formas de token de Google (`ya29.`, `1//0`, `Bearer`, `access_token`,
  `refresh_token`), `datasyncId`/`visitorData`, ni ids de la cuenta que no sean de prueba; las de cuenta, ningún correo
  que no sea de example.com.
- `ytkit record-account <carpeta> [--crudo DIR]` anonimiza al grabar: aprende de `accounts_list` y
  `get_add_to_playlist` los nombres, correos, @identificadores, avatares, `pageId`, `obfuscatedGaiaId`,
  `clientCacheKey`, `datasyncIdToken` y las listas propias, y los reemplaza en todas las respuestas; cambia por tokens
  de prueba los `feedbackToken`, `continuation`, `params` y demás tokens opacos; quita `responseContext` y el rastreo. Si
  después queda algo sospechoso, no escribe nada. `ytkit sanitize <crudas>` repite la anonimización sin red ni Llavero.
  Las crudas de esta fase se borraron.

## Comunidad (fase 3)

### Lo que se verificó contra YouTube (16-oct-2026, sin sesión)

1. **Comentarios por la interfaz de TV, como SmartTube.** `/next` con `continuation` y el cliente TVHTML5 responde
   `continuationContents.itemSectionContinuation` con `commentThreadRenderer.comment.commentRenderer` clásicos (autor,
   foto, texto en `runs`, fecha con «(editado)», `voteCount`, `replyCount`/`repliesCount` y el token de respuestas en
   `detailViewEndpoint.showEngagementPanelEndpoint`), 20 por página y `nextContinuationData` para la siguiente. La
   interfaz WEB manda otra forma (`commentViewModel` + `commentEntityPayload` en `frameworkUpdates`); **el token del
   `next` de WEB también vale con TV**, así que la app sigue usando el `next` de WEB y pide los comentarios por TV.
   Con Big Buck Bunny: «5.2 K comentarios», 2 páginas, respuestas de los 2 primeros (10 por página, con continuación).
2. **Respuestas:** el token de un comentario da otra `itemSectionContinuation` cuyo primer elemento es el comentario
   original como `commentRenderer` suelto (el «activo» de SmartTube) y luego las respuestas como hilos. YTKit lo separa
   en `CommentPage.parent`.
3. **Órdenes:** el panel de comentarios del `next` trae «Principales» y «Más recientes» (`sortFilterSubMenuRenderer`):
   en TV con `continuation.reloadContinuationData` y en WEB con `serviceEndpoint.continuationCommand`. Los dos se leen
   (`MediaItemMetadata.commentSorts`), junto con el número («5.2 K», `contextualInfo`).
4. **Chat en vivo:** el token sale de `conversationBar.liveChatRenderer` del `next` (TV y WEB; el de WEB también vale
   con TV) y `live_chat/get_live_chat` por TV devuelve `liveChatContinuation` con los mensajes (`addChatItemAction`,
   `removeChatItemAction`) y `timedContinuationData` con ~5 s de espera. Probado con un directo público de noticias:
   62 mensajes en la primera tanda y luego 1–3 cada 5 s. Un token viejo (10 min) responde sin mensajes y con
   `reloadContinuationData`; uno ya usado puede dar HTTP 400. Los emojis van aparte del texto (`runs[].emoji`, con el
   carácter como id en los de Unicode y un id opaco más `:atajo:` en los del canal).
5. **DeArrow por prefijo de hash:** `GET sponsor.ajay.app/api/branding/<4 hex de sha256(videoId)>` responde con todos
   los videos de ese prefijo (~150, ~17 KB, 0,5 s) sin enviar el id, igual que la consulta de SponsorBlock de la app.
   Big Buck Bunny tiene título de la comunidad («Big Buck Bunny (2008) [60fps 4K]») y no miniatura; `dtp6b76pMak` tiene
   las dos; la miniatura (`dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=…&time=…`) respondió 200 en WebP.
6. **Return YouTube Dislike:** `returnyoutubedislikeapi.com/votes?videoId=aqz-KE-bpKQ` → 110 207 me gusta y 18 636 no me
   gusta (estimados). SmartTube declara esta API pero muestra likes × 0,032; YTKit da los de la API.
7. **PoToken:** en la app, BotGuard terminó una vez sin `webPoSignalOutput` («webPoSignalOutput is empty», 1 de 3
   arranques) y el video no arrancaba. `mint` y `mintTV` ahora reintentan una vez con página y desafío nuevos.

### API

- `CommentsService` (lo cumple `YouTubeService`): `comments(_ token)` (primera página, un orden o la siguiente),
  `replies(to:)`, y con cuenta `setCommentLiked(_:liked:)` (`comment/perform_comment_action` con la acción del botón,
  como `CommentsServiceInt.toggleLike`) y `reply(to:text:)` (`comment/create_comment_reply` con `createReplyParams`).
  Modelos `Comment` y `CommentPage`; el me gusta y responder solo existen si la respuesta con sesión trae
  `actionButtons` (`likeAction`, `unlikeAction`, `replyParams`).
- `LiveChatService`: `liveChat(_ token)` (una petición → `LiveChatUpdate` con mensajes, borrados, token y espera) y
  `liveChatUpdates(_ token)`, un `AsyncThrowingStream` que sondea como `openLiveChat` de SmartTube: espera lo que pide
  YouTube (1–10 s), descarta repetidos y, si el token vence o falla la red, vuelve a empezar con el inicial (6 fallos
  seguidos lo terminan). `LiveChatMessage` distingue texto, Super Chat (monto y color), Super Sticker, membresías y
  avisos, y marca dueño, moderador, miembro y verificado.
- `MediaItemMetadata`: `commentsCountText`, `commentSorts`, `liveChatContinuation`, `isLiveChatReplay`.
- `DeArrowClient` (actor con caché; los pedidos simultáneos del mismo prefijo se juntan): `branding(for:)` de uno o
  varios videos → `DeArrowBranding` (`title`, `thumbnailTime`, `thumbnailURL`). Regla: el primero de cada lista que no
  tenga votos negativos (o esté bloqueado); si es el original, nada; se quitan los `>` del formateador (como SmartTube).
- `DislikeClient.votes(videoId:)` → `VoteCounts` (likes, dislikes, rating, proporción) y `compact(_:)` («19 k»).
- `AccountManager(…, ephemeral: true)`: sin Llavero (pruebas automáticas de la app con un binario recién compilado,
  que si no haría que macOS pidiera permiso).

### Pruebas y grabación

- `CommunityTests.swift`: 13 pruebas sobre 7 respuestas reales grabadas con `ytkit record-community` en
  `Fixtures/comunidad/` (comentarios, respuestas, «Más recientes», el `next` de TV de Big Buck Bunny, una tanda de
  chat de un directo, el prefijo de DeArrow y los votos de RYD) más JSON en línea para lo que no se puede grabar sin
  cuenta o sin suerte (acciones de me gusta y `createReplyParams`, Super Chat, emojis del canal, borrados, token
  vencido) y la regla de DeArrow.
- `ytkit record-community [carpeta] [--live id]` **anonimiza a las personas**: nombres → `@personaN`, fotos → el
  avatar genérico de YouTube, canales → `UCpersonaN_DE_PRUEBA`, textos → «Texto de prueba N» (los emojis y la forma
  de los `runs` se conservan) y quita los menús de cada mensaje; del `next` quita el adelanto de comentarios de la
  descripción. Listas recortadas a 8.

## Control remoto y enlaces (fase 4)

Fecha: 18-oct-2026. Lo nuevo vive en `Sources/YTKit/Lounge` (la Mac como «pantalla» de la app de YouTube del teléfono)
y `Sources/YTKit/Links` (enlaces de YouTube y `glasstube://`). Equivale a `youtubeapi/lounge` (`BindManager`,
`InfoManager`, `CommandManager`, `BindParams`, `CommandParams`, `LoungeService`) y `service/YouTubeRemoteControlService`
de SmartTube.

### Lo que se verificó contra YouTube

1. **Las direcciones de SmartTube siguen funcionando**, sin cuenta ni cookies:
   - `GET /api/lounge/pairing/generate_screen_id` → 26 caracteres en texto plano.
   - `POST /api/lounge/pairing/get_lounge_token_batch` (`screen_ids=…`) → `screens[0]` con `screenId`, `loungeToken`
     (119 caracteres, `AGdO5p…`), `expiration` y `loungeTokenLifespanMs` = 14 días. SmartTube lo renueva cada 30 min al
     reabrir; YTKit igual.
   - `POST /api/lounge/pairing/get_pairing_code?ctx=pair` con los campos de `getPairingCodeV2` (`lounge_token`,
     `screen_id`, `screen_name`, `access_type=permanent`, `app=lb-v4`, `device_id`, `qr=1`) → JSON con `code` (12
     dígitos) y `qr.image` (PNG de 256 px en base64). Sin `qr`, el código en texto plano. **El QR codifica
     `https://youtube.com/pair/<código>?qr=1`** (decodificado con `CIDetector`): la app lo genera con CoreImage en lugar
     de usar la imagen.
   - `POST /api/lounge/bc/bind?device=LOUNGE_SCREEN&…&RID=…` con `count=0` → la sesión: `["c", SID, "", 8]`,
     `["S", gsessionid]`, `loungeStatus` (los dispositivos como JSON dentro de una cadena, con la pantalla como
     `LOUNGE_SCREEN` y `receiverIdentityMatchStatus: IS_RECEIVER`), `getNowPlaying` y uno nuevo que SmartTube no trata,
     `getDiscoveryDeviceId` (se ignora).
   - `GET …&RID=rpc&SID=…&CI=0&AID=<último id>&TYPE=xmlhttp&gsessionid=…` → el canal largo. Llega un `noop` al abrir y
     otro cada ~30 s. Los reportes (`POST` con `count`, `ofs` y `reqN__sc`) responden 200 con
     `[canal abierto, último id, bytes pendientes]` (p. ej. `[1,5,16]`).
2. **Formato del canal** (BrowserChannel): trozos `<longitud>\n<arreglo JSON>\n`. La longitud cuenta caracteres de
   JavaScript, no bytes, así que `BindChunkParser` no la usa: busca el cierre del arreglo contando corchetes fuera de las
   cadenas (en UTF-8 ningún byte de un carácter de varios bytes es `[`, `]`, `"` ni `\`). Así da igual cómo llegue
   partido el texto (la prueba lo alimenta byte por byte, cortando a la mitad de una «é»).
3. **Con el teléfono del dueño** (app de YouTube › Transmitir › Vincular con código de TV, 18-oct-2026, con la app):
   el código vinculó la pantalla y el teléfono la usó como una tele. Lo que mandó, en orden: `loungeStatus` con el
   teléfono, `remoteConnected`, `getNowPlaying`, `getSubtitlesTrack`, `getVolume`, **`getPartyGamesMode`** (nuevo; se
   ignora), `updatePlaylist` y `setPlaylist` con el video; luego `pause`, `play`, `seekTo` (a 239, 354, 731 y 425 s) y
   `setVolume` (nivel absoluto: 97, 63, 54, 55, 46, 42). Al pasar la app del teléfono a segundo plano llegan
   `remoteDisconnected` y, al volver, otra vez `remoteConnected` + `getNowPlaying`… (se le responde con lo que suena).
   El teléfono a veces manda `pause` dos veces o `pause` justo antes de `play`. El dueño confirmó que en el teléfono se
   veían bien el video, el tiempo y el volumen.

### Cómo funciona (`LoungeScreen`)

- **Identidad** (`LoungeIdentity`: `screenId` y `deviceId`) en `LoungeIdentityStore`; la app usa `UserDefaults` (clave
  `remoteIdentity`), como SmartTube en sus preferencias. No son credenciales de la cuenta de Google: el id de pantalla
  solo sirve para que un teléfono ya vinculado la encuentre. `unlinkAll()` («Desvincular todos», `resetData`) los cambia
  por unos nuevos.
- **Canal con reconexión** (`run`): token → `bind` → `listen`. Si el servidor cierra el canal, se reabre con la misma
  sesión y `AID` = último mensaje (no repite nada); 400, 404 o 410 («Unknown SID») → sesión nueva; 401 o 403 → token
  nuevo; `["stop"]` → sesión nueva; fallos de red → espera 3, 6, 12, 24, 48 y 60 s (SmartTube espera 3 s fijos).
  Más de 65 s sin datos es una conexión colgada (`URLSession` propia con ese tiempo de espera; SmartTube usa 60 s).
  `generation` descarta lo que llega de una conexión anterior después de `stop()`/`restart()`.
- **Código para vincular** (`pairingCode()`): como SmartTube, después reabre la sesión con un token nuevo («apply
  changes (restart the service)»).
- **Eventos** (`events()`, uno por suscriptor): `.state` (`stopped`, `connecting`, `connected`, `retrying`),
  `.command(LoungeCommand)` y `.remotes` (los teléfonos conectados, de `loungeStatus`, `remoteConnected` y
  `remoteDisconnected`; sin la pantalla).
- **Comandos** (`LoungeCommand`): `setPlaylist` y `updatePlaylist` (`LoungePlaylist`: `videoId`, `videoIds`,
  `currentIndex`, `listId`, `currentTime`, `ctt`), `play`, `pause`, `next`, `previous`, `seekTo`, `setVolume` (`volume`
  0–100 o `delta`), `stopVideo`, `setSubtitlesTrack`, `dpadCommand` (`UP`, `DOWN`, `LEFT`, `RIGHT`, `ENTER`, `BACK`),
  `getNowPlaying`, `getVolume`, `getSubtitlesTrack`, `remoteConnected`, `remoteDisconnected`, `loungeStatus`,
  `voiceCommand` y `.other` para lo demás. Los argumentos llegan como texto o número; se leen los dos.
- **Reportes** (`send(_:)`, en orden, uno tras otro; `ofs` seguido en cada sesión): `nowPlaying` (o «nada suena»),
  `onStateChange`, `onVolumeChanged`, `onSubtitlesTrackChanged` y `onHasPreviousNextChanged`, con los campos de
  `CommandParams` (`cpn=foo`, `loadedTime`, `seekableStartTime/EndTime`, y `listId`/`currentIndex`/`ctt` del
  `setPlaylist`). Estados: 1 reproduciendo, 2 en pausa, 3 cargando (el «IDLE» de SmartTube), 0 terminado.
- **Nada de tokens en el registro**: `Log.debug` anota solo el nombre del comando o del reporte.

### Enlaces (`YouTubeLink`)

`YouTubeLink.parse(_:)` entiende una URL sola o un texto con un enlace dentro: `youtube.com`/`m.`/`music.`/
`youtube-nocookie.com` (`watch?v=`, `shorts/`, `live/`, `embed/`, `v/`, `playlist?list=`, `channel/UC…`, `@handle`,
`c/…`, `user/…`, `results?search_query=`, `attribution_link`), `youtu.be/…`, enlaces sin esquema, `vnd.youtube:` y el
esquema propio `glasstube://` (`watch?v=…&t=…&list=…`, `video/ID`, `channel/UC…` o `/@handle`, `@handle`,
`playlist?list=…`, `search?q=…`, `open?url=<enlace>`, o un enlace de YouTube con `glasstube` en lugar de `https`). Lee
`t=`/`start=` en segundos, `1m30s` o `1:30`. `webURL` y `appURL` dan la ida y vuelta.

### Pruebas y CLI

- `LoungeTests` (6): el `bind` real (anonimizado) por trozos y byte a byte, varios trozos con `noop`, todos los
  comandos, los reportes como formulario, código y token, y **una sesión completa con una red falsa**: comando,
  cierre del canal → reabre con la misma sesión y `AID`, 400 «Unknown SID» → sesión nueva, reportes con `ofs` seguidos y
  «Desvincular todos». `LinkTests` (4): enlaces de YouTube, el esquema propio (ida y vuelta), lo que no es enlace y los
  tiempos.
- `ytkit lounge [--seconds N] [--nombre X] [--mostrar] [--sin-codigo] [--guardar]`: una pantalla sin la app (escribe
  los comandos y responde `getNowPlaying`); `ytkit link <texto>`: cómo se interpreta un enlace.

## Organizar y descubrir (fase 5a)

Carpeta `Sources/YTKit/Discover/`. Verificado contra YouTube el 23-oct-2026, sin sesión, desde México (`es-419`).

### Feeds RSS (`RSSFeed.swift`)

- `RSSFeedParser.parse(_:channelId:)` lee `https://www.youtube.com/feeds/videos.xml?channel_id=UC…` con `XMLParser`,
  como `YouTubeRssParser` de SmartTube: id, canal, título, autor, fecha exacta (`MediaItem.publishedAt`, nuevo), vistas
  (`viewCount`, nuevo), miniatura (`hqdefault` 480×360) y el principio de la descripción. **Los Shorts se reconocen por
  su enlace** (`<link rel="alternate" href="…/shorts/ID">`): SmartTube los quita pidiendo además la pestaña del canal;
  aquí no hace falta otra petición. El `<yt:channelId>` del feed llega sin el prefijo `UC` (el de cada entrada sí lo
  trae); el id del canal sale del enlace `/channel/UC…` del feed o del que se pidió.
- `RSSFeedService` (actor; `YouTubeService.rss` y `rssFeed(channelIds:refresh:)`): hasta 8 canales a la vez (ventana
  deslizante), caché en memoria y en disco (`~/Library/Caches/Glasstube/rss/<id>`) de 15 min, y si YouTube no responde,
  la copia que haya aunque sea vieja. Un reintento ante 5xx (los feeds dan 500 a ratos); 404 = canal sin videos o id
  malo. Dos páginas que piden el mismo canal comparten la petición. Junta todo sin repetidos y ordena por fecha;
  `publishedText` («hace 4 horas») y `viewCountText` («2.3 K vistas», «1.2 M de vistas», como las tarjetas de YouTube) se
  escriben al pedir, en el idioma del catálogo, así que la caché no deja textos viejos. Tope de 200 canales (SmartTube:
  100, porque en las cajas de TV «sin límite tarda muchísimo»); `Result.skipped` dice cuántos quedaron fuera.
- Medido: Blender + otro canal en 0,56 s en frío; de la caché en disco, 0,28 s (`ytkit rss`).
- El RSS **no trae duración** ni marca directos o estrenos: las tarjetas salen sin el distintivo de duración.

### Shorts (`Shorts.swift`)

`shorts()`, por WEB y anónimo, como `BrowseService2.getShortsWeb`: `reel/reel_item_watch` con
`inputType: REEL_WATCH_INPUT_TYPE_SEEDLESS` y `params: "CA8%3D"` (el primero y `sequenceContinuation`), después
`reel/reel_watch_sequence` con `sequenceParams` (diez entradas con id, `params` y `frame0.jpg`, y la continuación en
`continuationEndpoint.continuationCommand.token`). Las entradas no traen título ni canal (solo la primera trae un
`playerResponse` precargado), así que, igual que SmartTube, se pide `reel_item_watch` de cada una con su `params` y se lee
`engagementPanels[].structuredDescriptionContentRenderer.items[].videoDescriptionHeaderRenderer` (título, canal con su
UC…, vistas, fecha) y la fecha relativa del reproductor de Shorts. Unos 240 KB por Short; de 5 en 5. Primera página: 14
Shorts en 3,6 s. La paginación va por `continueGroup` con `Continuation.API.reel` (nuevo) y `MediaGroup.Kind.shorts`.
La miniatura de la tarjeta es `sddefault.jpg` (la portada que eligió el canal, 4:3 con franjas, que la tarjeta vertical
recorta al centro); `frame0.jpg` es el primer cuadro y a veces sale negro.

### Filtros de búsqueda (`SearchFilter.swift`)

`SearchFilter` arma el `params` de `/search` (el `sp=` de las URL): `{1: prioridad, 2: {1: fecha, 2: tipo, 3: duración,
N: característica = 1}}` en base64, y lo lee de vuelta (`init?(params:)`, también con `%3D`). Los valores son los del
diálogo «Filtros de búsqueda» que manda la propia respuesta WEB en `header.searchHeaderRenderer.searchFilterButton`
(23-oct-2026), y no los de las listas viejas que circulan:

- **Tipo:** videos 1, **Shorts 9** (nuevo), canales 2, playlists 3, películas 4.
- **Duración:** **menos de 3 minutos 4** y **de 3 a 20 minutos 5** (nuevos; antes «menos de 4» era 1), más de 20 es 2.
- **Fecha de carga:** hoy 2, esta semana 3, este mes 4, este año 5. **«Última hora» ya no está.**
- **Prioridad** (antes «Ordenar por»): relevancia 0 y popularidad 3 (`CAM=`). **El orden por fecha de subida ya no
  existe:** con `CAI=` YouTube devuelve lo mismo que sin filtro (comprobado con «blender»).
- **Características:** en vivo 8, 4K 14, HD 4, subtítulos 5, Creative Commons 6, HDR 25 (y 360°, VR180, 3D, ubicación y
  compras, que la app no ofrece).
- Se combinan: «esta semana + videos + de 3 a 20 minutos» = `EgYIAxABGAU=` (verificado: solo videos de la semana y de
  esa duración). Con tipo Shorts, los resultados llegan en `gridShelfViewModel`; con Shorts + Creative Commons YouTube
  responde con un `backgroundPromoRenderer` «No se encontraron resultados».

### Importar grupos (`ChannelGroupImport.swift`)

Los tres formatos de SmartTube (`ChannelGroupServiceImpl` prueba PocketTube, GrayJay y NewPipe en ese orden):

- **PocketTube:** objeto JSON; `ysc_collection` nombra los grupos y cada uno es una clave de la raíz con sus ids. Como
  `JSONSerialization` pierde el orden de las claves, los grupos van en el orden en que aparecen en el archivo.
- **GrayJay:** lista de grupos, cada uno una **cadena** con su JSON (SmartTube la «arregla» quitando comillas; aquí se
  decodifica cada cadena) o un objeto. De `urls` solo cuentan los canales `youtube.com/channel/UC…`; Rumble, LBRY y los
  `@handle` (sin red no hay id) se cuentan en `skipped`.
- **NewPipe:** `subscriptions` con `service_id` 0 (YouTube). Son suscripciones, no un grupo (`isSubscriptions`), como
  en SmartTube.
- Probado también con los archivos de prueba del propio SmartTube (`youtubeapi/src/test/resources/channelgroups`):
  PocketTube 3 grupos y 12 canales; GrayJay 6 grupos, 99 canales y 4 entradas que no son de YouTube.

### Pruebas y CLI

- `DiscoverTests.swift` (16): RSS (lectura, Shorts por enlace, id del canal, lo que no es un feed, mezcla de 12
  canales en paralelo con caché y `refresh`, copia vieja ante fallos con su reintento, textos de vistas), filtros (los
  19 `params` del diálogo de YouTube, combinaciones verificadas, ida y vuelta), Shorts (secuencia con detalles; el que
  no tiene detalles no sale) e importar (los tres formatos, objetos de GrayJay, archivos que no son de ninguno, URL de
  canal). Fixtures en `Fixtures/descubrir/`: un feed de Blender recortado, Shorts recortados y **neutralizados**
  (títulos, canales e ids de prueba) y archivos de importación propios con canales de Blender e ids de prueba.
- CLI: `ytkit rss <UC…>… [--refrescar]`, `ytkit shorts [--pages N]`, `ytkit search … --filtro
  tipo=video,fecha=semana,duracion=3-20,prioridad=popularidad,cc` y `ytkit importar <archivo>`.

## Cómo se parsean los renderers

- **Campos tolerantes.** Todos los campos de los modelos (`Renderers.swift`, `WatchNext.swift`, `Channel.swift`) van
  envueltos en `@Lenient`. Si un campo falta o tiene otra forma (un número en lugar de un texto, por ejemplo), queda
  en nil y el resto se lee igual. `YTText` acepta las cuatro formas de texto: cadena, `simpleText`, `runs` y
  `content`. `FlexibleInt` acepta números y cadenas.
- **Nodos que nunca fallan.** Cada objeto de una lista es un `Node` decodificado según el nombre de su renderer. Puede
  ser un elemento conocido, una continuación, un aviso, un renderer ignorado a propósito o un contenedor genérico. Un
  renderer desconocido se recorre como contenedor, con los campos de siempre (`content`, `contents`, `items`, `tabs`,
  `continuations`, `continuationItems`…). Si un objeto trae dos renderers (pasa en los canales de tema), se recorren
  los dos. Un elemento roto queda como `failed` y no se lleva a sus vecinos.
- **Un solo recorrido para TV y WEB** (`PageExtractor`), sin una ruta fija por pantalla:
  - Un contenedor de fila (`shelfRenderer`, `richShelfRenderer`, `reelShelfRenderer`, `gridShelfViewModel`, o un
    `itemSectionRenderer` con título) es una fila: todo lo que tiene dentro se aplana en ella.
  - Los demás contenedores son transparentes: sus elementos sueltos forman la cuadrícula de la página.
  - Un token suelto es de la cuadrícula (trae más elementos) si hay elementos sueltos, y de la página (trae más filas)
    si no los hay. Esa regla cubre igual las continuaciones de TV (`continuationContents`) y las de WEB
    (`onResponseReceivedActions`, `Commands` y `Endpoints`).
- **Diagnóstico.** `ParseStats` cuenta los renderers ignorados, los que fallaron y los elementos descartados. Así un
  cambio de YouTube se nota en el CLI (`ignorados a propósito: …`, `FALLARON al decodificar: …`) antes de que se
  note en la app.
- **Las decisiones salen de la estructura**, no del texto: se usan `style`, `contentType` y `badgeStyle`, que no
  dependen del idioma. La excepción son los textos posicionales de las tarjetas de TV (la primera línea es el autor;
  la segunda, visitas y fecha), que siguen el mismo criterio que SmartTube.

### Renderers soportados

| Tipo | Renderers |
|---|---|
| Elementos (`MediaItem`) | `tileRenderer` (TV, incluidas las tarjetas del carrusel, que traen el título en `onFocusCommand`), `lockupViewModel` (VIDEO, SHORT, MUSIC, STATION, PLAYLIST, PODCAST, ALBUM, CHANNEL), `videoRenderer`, `gridVideoRenderer`, `compactVideoRenderer`, `playlistVideoRenderer`, `playlistPanelVideoRenderer`, `reelItemRenderer`, `pivotVideoRenderer`, `endScreenVideoRenderer`, `movieRenderer` y variantes, `shortsLockupViewModel`, `channelRenderer`, `gridChannelRenderer`, `compactChannelRenderer`, `playlistRenderer`, `gridPlaylistRenderer`, `compactPlaylistRenderer`, `radioRenderer` (mix) y variantes |
| Filas | `shelfRenderer`, `richShelfRenderer`, `reelShelfRenderer`, `gridShelfViewModel`, `itemSectionRenderer` con título |
| Contenedores (transparentes) | `sectionListRenderer`, `itemSectionRenderer`, `richGridRenderer`, `richSectionRenderer`, `richItemRenderer`, `gridRenderer`, `horizontalListRenderer`, `verticalListRenderer`, `expandedShelfContentsRenderer`, `playlistVideoListRenderer`, `tabRenderer`, `expandableTabRenderer`, `twoColumnBrowseResultsRenderer`, `twoColumnSearchResultsRenderer`, `tvBrowseRenderer`, `tvSurfaceContentRenderer`, `twoColumnRenderer` (TV) y cualquier otro con la misma forma |
| Paginación | `continuationItemRenderer`, `continuationItemViewModel` (nuevo, en listas), `nextContinuationData`/`reloadContinuationData`, `sectionListContinuation`, `horizontalListContinuation`, `appendContinuationItemsAction`, `reloadContinuationItemsCommand` |
| Avisos | `feedNudgeRenderer`, `messageRenderer` → `BrowsePage.notice` |
| `next` | `videoPrimaryInfoRenderer`, `videoSecondaryInfoRenderer`, `videoMetadataRenderer` (TV), `videoOwnerRenderer`, `structuredDescriptionContentRenderer` (`videoDescriptionHeaderRenderer` con los "Me gusta" y `expandableVideoDescriptionBodyRenderer`), capítulos en `macroMarkersListEntity` (`frameworkUpdates`), `chapterRenderer` (`playerOverlays`) y `macroMarkersListItemRenderer`, mapa de calor (`MARKER_TYPE_HEATMAP`), reproducción automática (`autoplayVideo`, `autonavEndpointRenderer`) y token de comentarios |
| Canal | `pageHeaderViewModel` (WEB), `c4TabbedHeaderRenderer` (WEB antiguo), `channelHeaderRenderer` (TV), `channelMetadataRenderer`. El tipo de cada pestaña se lee del campo 2 del protobuf de su `params` ("videos", "streams"…), no de su título |
| Ignorados a propósito | anuncios, publicaciones (`postRenderer`), `channelVideoPlayerRenderer` (el video destacado del canal), `officialCardViewModel`, chips, refinamientos de búsqueda (`horizontalCardListRenderer`), avisos de inicio de sesión de TV, atajos de TV a pestañas (`TILE_STYLE_YTLR_WORMHOLE_RECTANGULAR`) |

## TV o WEB

Medido con `ytkit compare` (15-oct-2026, sin sesión). Los porcentajes son sobre los videos que no son Shorts:

| Pedido | Tiempo | Filas | Elementos | Videos / Shorts / canales / listas | Autor | Id de canal | Visitas | Fecha | Duración | Extracto | Avatar | Miniatura máx. | Continuación |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Inicio sustituto tv | 0.9 s | 10 | 88 | 78 / 4 / 0 / 6 | 100 % | 100 % | 100 % | 76 % | 80 % | 0 % | 0 % | 3000 px | 8 filas |
| Inicio sustituto web | 1.0 s | 9 | 86 | 65 / 0 / 0 / 21 | 100 % | 98 % | 100 % | 64 % | 69 % | 87 % | 100 % | 1200 px | 0 filas |
| Tema music tv | 0.4 s | 4 | 24 | 12 / 0 / 0 / 12 | 100 % | 100 % | 100 % | 75 % | 100 % | 0 % | 0 % | 1200 px | 4 filas + página |
| Tema music web | 0.3 s | 7 | 74 | 24 / 0 / 0 / 50 | 100 % | 79 % | 100 % | 100 % | 100 % | 0 % | 79 % | 1200 px | 0 filas |
| Tema news tv | 0.4 s | 4 | 20 | 20 / 0 / 0 / 0 | 100 % | 100 % | 100 % | 75 % | 75 % | 0 % | 0 % | 640 px | 4 filas + página |
| Tema news web | 1.1 s | 16 | 160 | 160 / 0 / 0 / 0 | 100 % | 100 % | 100 % | 93 % | 93 % | 96 % | 100 % | 336 px | 0 filas |
| Búsqueda «lofi hip hop» tv | 0.9 s | 4 | 139 | 44 / 93 / 0 / 2 | 100 % | 0 % | 100 % | 100 % | 75 % | 0 % | 0 % | 3000 px | 1 fila |
| Búsqueda «lofi hip hop» web | 0.9 s | 3 | 44 | 19 / 25 / 0 / 0 | 100 % | 100 % | 100 % | 100 % | 73 % | 89 % | 100 % | 720 px | 1 fila |
| Canal MrBeast, Inicio, tv | 0.7 s | 8 | 122 | 84 / 24 / 9 / 5 | 100 % | 100 % | 100 % | 100 % | 100 % | 0 % | 0 % | 854 px | 4 filas |
| Canal MrBeast, Inicio, web | 0.4 s | 3 | 30 | 24 / 0 / 6 / 0 | 50 % | 100 % | 100 % | 100 % | 100 % | 0 % | 100 % | 720 px | 0 filas |

| `next` rfscVS0vtbw | Tiempo | Título | Canal (id, avatar, suscriptores) | Visitas exactas | Me gusta | Fecha | Descripción | Capítulos | Mapa de calor | Sugeridos | Comentarios |
|---|---|---|---|---|---|---|---|---|---|---|---|
| tv | 0.7 s | sí | sí, sí, sí | 49,452,524 | 1.1 M | Publicado el 11 jul 2018 | 2181 car. | 35 | 100 | 10 filas de 3 | token |
| web | 0.7 s | sí | sí, sí, sí | 49,452,524 | 1.1 M | 11 jul 2018 | 2230 car. | 35 | 100 | 1 lista de 20, paginada | token |

Lo que se ve:

- **Inicio real:** vacío en las dos. TV dice «Personaliza tu cuenta de YouTube. Accede…»; WEB, «El Historial de
  YouTube está desactivado…». Los mismos endpoints que usa SmartTube (`default` y `FEwhat_to_watch`) ya no dan nada
  sin cuenta.
- **Temas de Explorar:** en TV, `FEtopics_*` da 4 filas con continuación por fila y por página. En WEB, `FEtopics_*`
  responde 400 y se usan los canales de tema ("Noticias" tiene 16 filas, con avatar y extracto). Películas solo existe
  en TV y YTKit la pide por TV aunque la preferencia sea WEB.
- **Búsqueda:** WEB enlaza el canal en cada resultado (con avatar y extracto de la descripción) y separa los Shorts
  en sus estantes. TV agrupa por estantes ("Resultados", "Más de 20 minutos", "Canciones", "Shorts", con 93 Shorts),
  pero **no trae el id del canal** (0 %): desde un resultado no se puede abrir el canal.
- **Canal:** WEB devuelve cada pestaña por separado y la lista de pestañas que tiene el canal. TV ignora `params` y
  devuelve siempre las mismas filas, sin pestañas.
- **`next`:** los metadatos son equivalentes, y las dos traen capítulos y mapa de calor (TV en `frameworkUpdates`).
  Los sugeridos de WEB son de tema (otros cursos de Python), en una lista paginada. Los de TV son filas de 3 mezcladas
  con contenido ajeno (caricaturas infantiles y Roblox junto a un curso de Python).
- **Miniaturas:** TV trae más resolución (640×360 `hq720`, y hasta 3000 px en música). WEB a veces trae solo 336 px;
  `MediaItem.standardThumbnails` da las URL estándar de `i.ytimg.com` (`maxresdefault` puede no existir).
- **Tiempos:** parecidos, de 0,3 a 1,1 s por página. Las respuestas WEB pesan más (hasta 1,6 MB contra 0,1 MB en TV),
  pero se decodifican en 0,01–0,05 s.

**Decisión:** WEB por omisión para escritorio (`SurfacePreferences.recommended`). Da id y avatar del canal en cada
tarjeta, extractos, pestañas de canal y sugeridos relacionados. TV queda como alternativa completa (`.tv`) y es mejor
en dos cosas: la continuación por fila (desplazamiento horizontal infinito) y las miniaturas grandes. Para reproducir
se siguen usando TV_DOWNGRADED, VISIONOS y SABR con TV, que es otro asunto (RESULTADOS.md del spike).

## Paginación

- `continueGroup(_:)` pide más elementos de una fila: las cuadrículas WEB (canal, búsqueda, sugeridos, listas) y las
  filas de TV. La búsqueda de TV responde a la continuación de una fila con otra tanda de estantes; se toma el de
  igual título.
- `continuePage(_:)` pide más filas: los temas de TV y los sugeridos de TV.
- Probado contra YouTube con `--pages 2` en búsqueda (TV y WEB), en la pestaña Videos de un canal, en una lista (TV y
  WEB, con los 102 videos completos en WEB) y en los sugeridos (TV por página, WEB por fila).

## Pruebas y fixtures

- `swift test`: 90 pruebas en 18 suites (Swift Testing), todas pasan en ~2,8 s (la de privacidad recorre todas las
  fixtures). Las 10 de la fase 4 están en `LoungeTests.swift` y `LinkTests.swift` (ver
  [Control remoto y enlaces](#pruebas-y-cli)). Las 24 de la fase 2 están en `AccountTests.swift` (ver [Cuentas](#pruebas-sin-tokens-ni-datos-personales))
  y las 13 de la fase 3 en `CommunityTests.swift` (ver [Comunidad](#pruebas-y-grabación)).
  Las de la fase 1 cubren:
  - la tolerancia de los modelos (formas de texto, números como cadena, tipos cambiados, elementos rotos, renderers
    desconocidos, objetos con dos renderers);
  - cada pantalla sobre sus respuestas grabadas: Inicio, temas, Hype, búsqueda, sugerencias, canal y pestañas, listas
    y `next`, con sus continuaciones;
  - invariantes sobre las fixtures de página (también las de cuenta): ningún renderer falla y cada elemento tiene título, el id de su tipo y
    miniaturas https;
  - lo portado que no necesita red: `clients.json`, el cuerpo de la petición, el protobuf y UMP.
- `Tests/YTKitTests/Fixtures`: respuestas reales grabadas con `ytkit record Tests/YTKitTests/Fixtures` (2,8 MB).
  Para que no pesen 7 MB, se quitan las claves que el parser no lee (rastreo, `commandMetadata`, paletas, botones) y
  las listas se recortan a 10 elementos, conservando el `continuationItemRenderer` final. El detalle está en
  `_grabacion.json`. `ytkit record <carpeta> nombre…` regraba solo algunas.
- **Command Line Tools sin Xcode:** XCTest no existe y SwiftPM no le pasa al compilador el plugin de las macros de
  Swift Testing. El `Package.swift` lo agrega con `-plugin-path` en el target de pruebas (`unsafeFlags`, válido en un
  paquete raíz). Con Xcode instalado esa ruta no existe y no estorba.

## CLI de verificación

```bash
swift build
.build/debug/ytkit comments aqz-KE-bpKQ --pages 2 --replies 2   # comentarios por TV (--sort 1: Más recientes)
.build/debug/ytkit chat <directo> --seconds 30   # chat en vivo con el sondeo de liveChatUpdates
.build/debug/ytkit dearrow aqz-KE-bpKQ dtp6b76pMak dQw4w9WgXcQ   # DeArrow por prefijo de hash
.build/debug/ytkit dislikes aqz-KE-bpKQ          # Return YouTube Dislike
.build/debug/ytkit record-community Tests/YTKitTests/Fixtures/comunidad --live <directo>   # fixtures de la fase 3
.build/debug/ytkit home                        # Inicio sustituto (WEB); --surface tv para TV
.build/debug/ytkit trending                    # Hype (FEtrending da 400)
.build/debug/ytkit topic news --surface tv
.build/debug/ytkit search lofi hip hop --pages 2
.build/debug/ytkit suggest lofi
.build/debug/ytkit channel @MrBeast --tab videos --pages 2
.build/debug/ytkit playlist PLdkGTI2esnoY --pages 2
.build/debug/ytkit next rfscVS0vtbw --surface tv --pages 2
.build/debug/ytkit compare                     # las tablas de arriba
.build/debug/ytkit formats dQw4w9WgXcQ         # streams con la rotación portada
.build/debug/ytkit sabr-player aqz-KE-bpKQ eRsGyueVLvQ --veces 3   # player de SABR como la app (--cuenta, --bajar,
                                               # --sin-recuperar, --simular-bot N)
.build/debug/ytkit raw browse web browseId=FEhype_leaderboard   # respuesta cruda
```

`--json` imprime los modelos en JSON. `--hl` y `--gl` cambian el idioma y la región. Todos los subcomandos se
corrieron sin sesión y devolvieron datos reales (MrBeast, Lofi Girl, freeCodeCamp, noticias de México).

Con cuenta (la sesión es la misma de Glasstube.app, en el Llavero; nombres y correos salen enmascarados salvo con
`--mostrar`, y nunca se imprimen tokens):

```bash
.build/debug/ytkit signin                      # código para youtube.com/activate; espera y guarda la sesión
.build/debug/ytkit accounts [--refresh]        # cuentas (* = elegida); select <n>; signout [<n>|--all]
.build/debug/ytkit subs | history | library | watchlater [--pages N]
.build/debug/ytkit home --cuenta               # Inicio de la cuenta (TV)
.build/debug/ytkit state aqz-KE-bpKQ           # me gusta y suscripción
.build/debug/ytkit like|unlike|dislike|undislike aqz-KE-bpKQ
.build/debug/ytkit subscribe|unsubscribe UCSMOQeBJ2RAnuFungnQOxLg
.build/debug/ytkit plinfo aqz-KE-bpKQ ; pladd|plremove WL aqz-KE-bpKQ
.build/debug/ytkit watched 9bZkp7q19f0 5 65 125 185   # reporta en tiempo real
.build/debug/ytkit playerauth 9bZkp7q19f0      # diagnóstico del /player con la cuenta
.build/debug/ytkit record-account Tests/YTKitTests/Fixtures   # fixtures anonimizadas
.build/debug/ytkit parse <archivo.json> [--next] # una respuesta guardada, sin red
```

## Qué falta

- **Cuentas, lo pendiente:** la posición exacta guardada en YouTube no se puede leer por TV (ver el punto 5 de
  [Cuentas](#cuentas-fase-2)); `markAsNotInterested` se verificó hasta obtener el token, sin mandarlo;
  `setWatchHistoryEnabled`, `createPlaylist` y `deletePlaylist` están sin probar (la cuenta de prueba solo tenía Ver más
  tarde y Me gusta); el `get_panel` se pide en cada "No me interesa" (SmartTube lo guarda en caché); la lista de
  canales suscritos (las pestañas por canal de Suscripciones de TV) no se expone todavía; no se probó una sesión
  revocada desde la cuenta de Google (sí con el OAuth falso).
- **Comentarios, lo pendiente:** me gusta y responder **no se probaron con cuenta**: hacen falta el permiso del
  Llavero para el binario nuevo y, para responder, publicar un comentario en un video público (no se hizo sin permiso
  explícito). Las formas de `actionButtons`/`createReplyParams` son las de los `commentRenderer` de YouTube, sin
  grabación con sesión; si la interfaz de TV no las da, la app no muestra esos botones. Tampoco: comentar en el video
  (`createCommentParams`, sin botón en la app), la forma WEB de los comentarios (`commentViewModel`), el chat de la
  repetición de un directo (`get_live_chat_replay`) y las imágenes de los emojis propios de un canal (se muestran como
  `:atajo:`).
- **Shorts con cuenta:** el feed va siempre por WEB anónimo (SmartTube, con cuenta, pide antes los Shorts de las
  suscripciones por TV). Kids, pestañas de canal sin contenido navegable (Publicaciones, Tienda), búsqueda dentro de un
  canal y el video destacado del Inicio del canal.
- **RSS sin duración ni directos:** completarlos como SmartTube costaría pedir la pestaña de cada canal (una petición
  más por canal).
- **Filtros:** el orden por fecha de subida y «Última hora» ya no los ofrece YouTube; si vuelven a cambiar el diálogo,
  los números están en `SearchFilter` y en `SearchFilterTests`.
- **Textos sin interpretar:** visitas, fechas y suscriptores quedan como los da YouTube ("1.1 M de vistas",
  "hace 2 semanas"). Pasarlos a números y fechas dependería del idioma.
- **Solo se probó en una región** (MX, `es-419`). Con `hl=es`, YouTube responde en español de España ("vídeos");
  `CatalogLocale.current` pide `es-419` en cualquier región hispana que no sea España.
- **WEB sin continuación por fila:** las filas de `richShelfRenderer` (temas WEB, Inicio sustituto WEB) no traen
  token. Si la app quiere desplazamiento horizontal infinito ahí, tendría que pedir esas filas por TV.
- **El modo de lenguaje Swift 5** sigue en el target `YTKit`, porque el código portado del spike (Sabr, PoToken,
  solver) no compila en modo Swift 6. El CLI y las pruebas sí usan Swift 6. Pasar el target completo a Swift 6 es
  trabajo aparte.
- **Fragilidad:** YouTube cambia estos renderers seguido. `lockupViewModel` ya reemplazó a `compactVideoRenderer` en
  los sugeridos y a `playlistVideoRenderer` en las listas, y `continuationItemViewModel` llegó hace poco. Para seguir
  el ritmo están los avisos de `ParseStats` en el CLI, la prueba de invariantes y `ytkit record` para regrabar.
