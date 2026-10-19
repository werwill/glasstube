import Foundation

// Lo que depende de la cuenta: feeds (`BrowseApiHelper`: FEsubscriptions, FEhistory, FEplaylist_aggregation), acciones
// (`ActionsApi`: me gusta, suscribirse, historial), listas (`PlaylistApi`) y "No me interesa" (`FeedbackApi`). Todas
// las peticiones van con la cuenta elegida en `AccountManager`; sin sesión lanzan `YTKitError.signInRequired`.

/// Una lista del usuario vista desde un video (`PlaylistInfo` de SmartTube, `playlist/get_add_to_playlist`).
public struct PlaylistInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// El video ya está en la lista (`containsSelectedVideos == "ALL"`).
    public var containsVideo: Bool

    public init(id: String, title: String, containsVideo: Bool) {
        self.id = id
        self.title = title
        self.containsVideo = containsVideo
    }
}

/// Estado del "me gusta" de un video con la cuenta elegida.
public enum LikeStatus: String, Codable, Sendable {
    case like, dislike, indifferent
}

extension YouTubeService {
    /// Listas especiales de cada cuenta.
    public static let watchLaterPlaylistId = "WL"
    public static let likedVideosPlaylistId = "LL"

    // MARK: - Feeds (siempre por TV: la sesión de la app de TV no vale con el cliente WEB)

    /// Suscripciones (`FEsubscriptions`): los videos nuevos de los canales a los que la cuenta está suscrita. TV las
    /// manda como pestañas ("Todos" y una por canal); se usa "Todos": "Más relevantes" y luego tandas de tres videos
    /// recientes sin título, que aquí se juntan en una cuadrícula "Más recientes".
    func accountSubscriptions() async throws -> BrowsePage {
        try await accountPage("FEsubscriptions", kind: .subscriptions, title: "Suscripciones").mergingUntitledRows(title: "Más recientes")
    }

    /// Historial de reproducciones (`FEhistory`).
    func accountHistory() async throws -> BrowsePage {
        try await accountPage("FEhistory", kind: .history, title: "Historial")
    }

    /// Las listas de la cuenta (`FEplaylist_aggregation`): Me gusta, Ver más tarde, las propias y las guardadas.
    func accountPlaylists() async throws -> BrowsePage {
        try await accountPage("FEplaylist_aggregation", kind: .library, title: "Playlists")
    }

    /// Ver más tarde (`VLWL`).
    public func watchLater() async throws -> BrowsePage {
        try await requireSignIn("Ver más tarde")
        return try await playlist(Self.watchLaterPlaylistId, surface: .tv)
    }

    func accountPage(_ browseId: String, kind: MediaGroup.Kind, title: String) async throws -> BrowsePage {
        let data = try await api.post(.browse, surface: .tv, ["browseId": browseId], auth: .required(title))
        var page = try await Self.parsePage(data, surface: .tv, api: .browse, kind: kind, looseTitle: title)
        page.title = title
        return page
    }

    func requireSignIn(_ what: String) async throws {
        guard let session, try await session.authorizationHeaders() != nil else { throw YTKitError.signInRequired(what) }
    }

    // MARK: - Me gusta y suscripciones (ActionsApi, cuerpo de TV como `PostDataHelper.createQueryTV`)

    func action(_ path: String, _ extra: [String: Any], what: String) async throws {
        _ = try await api.post(path, surface: .tv, extra, auth: .required(what))
    }

    public func setLike(videoId: String) async throws {
        try await action("like/like", ["target": ["videoId": videoId]], what: "Me gusta")
    }

    public func removeLike(videoId: String) async throws {
        try await action("like/removelike", ["target": ["videoId": videoId]], what: "Me gusta")
    }

    public func setDislike(videoId: String) async throws {
        try await action("like/dislike", ["target": ["videoId": videoId]], what: "No me gusta")
    }

    public func removeDislike(videoId: String) async throws {
        try await action("like/removedislike", ["target": ["videoId": videoId]], what: "No me gusta")
    }

    /// `subscription/subscribe`. `params` es el del botón de suscribirse, si lo hay (activa las notificaciones).
    public func subscribe(channelId: String, params: String?) async throws {
        var extra: [String: Any] = ["channelIds": [channelId]]
        if let params { extra["params"] = params }
        try await action("subscription/subscribe", extra, what: "Suscribirse")
    }

    public func subscribe(channelId: String) async throws { try await subscribe(channelId: channelId, params: nil) }

    /// Si la cuenta está suscrita a un canal (la cabecera del canal por TV con la cuenta trae su
    /// `subscribeButtonRenderer`). `params` se reenvía a `subscribe`.
    public func subscriptionState(channelId: String) async throws -> (isSubscribed: Bool, params: String?)? {
        let id = try await api.resolveChannelId(channelId)
        let data = try await api.post(.browse, surface: .tv, ["browseId": id], auth: .required("Suscribirse"))
        var probe = MediaItemMetadata(videoId: "", surface: .tv)
        probe.channelId = id
        WatchNextAccountState.apply(data, to: &probe)
        return probe.isSubscribed.map { ($0, probe.subscribeParams) }
    }

    public func unsubscribe(channelId: String) async throws {
        try await action("subscription/unsubscribe", ["channelIds": [channelId]], what: "Suscribirse")
    }

    /// "No me interesa" (`feedback` con el token del menú de la tarjeta, `MediaItem.feedbackToken`).
    public func markAsNotInterested(feedbackToken: String) async throws {
        try await action("feedback", ["feedbackTokens": [feedbackToken]], what: "No me interesa")
    }

    /// "No me interesa" de una tarjeta: con el token de su menú o, en el Inicio de TV (donde el menú llega aparte),
    /// pidiendo el panel del menú (`get_panel`, `PanelService` de SmartTube) y usando su primer token.
    public func markAsNotInterested(_ item: MediaItem) async throws {
        var token = item.feedbackToken
        if token == nil, let panel = item.menuPanel {
            let data = try await api.post("get_panel", surface: .tv, ["panelId": panel.panelId, "params": panel.params],
                                          auth: .required("No me interesa"))
            token = FeedbackTokens.all(in: data).first
        }
        guard let token else { throw YTKitError.notAvailable("YouTube no da \"No me interesa\" para esta tarjeta") }
        try await markAsNotInterested(feedbackToken: token)
    }

    // MARK: - Historial

    /// Pausa o reanuda el historial de reproducciones de la cuenta (`history/pause_watch_history`).
    public func setWatchHistoryEnabled(_ enabled: Bool) async throws {
        try await action(enabled ? "history/resume_watch_history" : "history/pause_watch_history", ["nop": "false"], what: "El historial")
    }

    /// Reporta la posición de reproducción a YouTube (aparece en Historial y en la barra roja de la miniatura):
    /// `updateHistoryPosition` → `TrackingService.updateWatchTime` de SmartTube.
    public func updateHistoryPosition(videoId: String, positionSeconds: Double) async throws {
        try await requireSignIn("El historial")
        try await watchTime.update(videoId: videoId, position: positionSeconds, service: self)
    }

    /// Diagnóstico: el `/player` con la cuenta (el mismo del tiempo visto), crudo.
    public func rawAuthenticatedPlayer(videoId: String) async throws -> Data { try await authenticatedPlayer(videoId: videoId) }

    /// `/player` con la cuenta, solo para los datos de `playbackTracking` (los streams siguen saliendo de
    /// `formatInfo`, sin cuenta). Como la petición de streams: cliente TV con `signatureTimestamp` y `visitorData`; sin
    /// ellos YouTube responde UNPLAYABLE ("Se debe volver a cargar la página") y no hay `playbackTracking`.
    func authenticatedPlayer(videoId: String) async throws -> Data {
        guard let headers = try await session?.authorizationHeaders() else { throw YTKitError.signInRequired("El historial") }
        let scripts = PlayerScriptStore.shared
        var lastData = Data()
        for id in ["TV_DOWNGRADED", "TV"] {
            guard let client = catalog.profile(id) else { continue }
            var request = Innertube.PlayerRequest(videoId: videoId, client: client)
            if let (url, _) = try? await scripts.playerURL(for: client) {
                request.signatureTimestamp = try? await scripts.signatureTimestamp(for: url)
            }
            request.visitorData = try? await scripts.appInfo().visitorData
            request.extraHeaders = headers
            let reply = try await Innertube().player(request)
            lastData = reply.data
            if reply.status == 200, WatchTimeTracker.hasTracking(reply.data) { return reply.data }
        }
        return lastData
    }

    // MARK: - Listas (PlaylistApi)

    /// Las listas de la cuenta con la marca de si el video ya está en cada una (`get_add_to_playlist`).
    public func playlistsInfo(videoId: String) async throws -> [PlaylistInfo] {
        let data = try await api.post("playlist/get_add_to_playlist", surface: .tv, ["videoIds": [videoId]],
                                      auth: .required("Tus listas"))
        return try PlaylistInfoParser.playlists(from: data)
    }

    /// `browse/edit_playlist` con `ACTION_ADD_VIDEO` (sirve también con `WL`, Ver más tarde).
    public func addToPlaylist(playlistId: String, videoId: String) async throws {
        try await action("browse/edit_playlist", [
            "playlistId": playlistId,
            "actions": [["addedVideoId": videoId, "action": "ACTION_ADD_VIDEO"]],
        ], what: "Tus listas")
    }

    /// `browse/edit_playlist` con `ACTION_REMOVE_VIDEO_BY_VIDEO_ID`.
    public func removeFromPlaylist(playlistId: String, videoId: String) async throws {
        try await action("browse/edit_playlist", [
            "playlistId": playlistId,
            "actions": [["removedVideoId": videoId, "action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID"]],
        ], what: "Tus listas")
    }

    /// `playlist/create` (cuerpo WEB, como SmartTube). Devuelve el id de la lista nueva.
    @discardableResult
    public func createPlaylist(title: String, videoId: String? = nil) async throws -> String? {
        var extra: [String: Any] = ["title": title]
        if let videoId { extra["videoIds"] = [videoId] }
        let data = try await api.post("playlist/create", surface: .web, extra, auth: .required("Tus listas"))
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["playlistId"] as? String
    }

    /// `playlist/delete` (solo listas propias).
    public func deletePlaylist(playlistId: String) async throws {
        _ = try await api.post("playlist/delete", surface: .web, ["playlistId": playlistId], auth: .required("Tus listas"))
    }
}

/// `PlaylistsResult` de SmartTube: `contents[0].addToPlaylistRenderer.playlists[*].playlistAddToOptionRenderer`. Aquí se
/// recorre la respuesta entera (WEB y TV las anidan distinto).
enum PlaylistInfoParser {
    static func playlists(from data: Data) throws -> [PlaylistInfo] {
        let root = try JSONSerialization.jsonObject(with: data)
        var found: [[String: Any]] = []
        collect(root, into: &found)
        return found.compactMap { option in
            guard let id = option["playlistId"] as? String else { return nil }
            let title = text(option["title"]) ?? id
            return PlaylistInfo(id: id, title: title, containsVideo: option["containsSelectedVideos"] as? String == "ALL")
        }
    }

    static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let dict = value as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] { return runs.compactMap { $0["text"] as? String }.joined() }
        return dict["content"] as? String
    }

    private static func collect(_ node: Any, into result: inout [[String: Any]]) {
        if let dict = node as? [String: Any] {
            if let option = dict["playlistAddToOptionRenderer"] as? [String: Any] { result.append(option) }
            for key in dict.keys.sorted() where key != "playlistAddToOptionRenderer" { collect(dict[key]!, into: &result) }
        } else if let array = node as? [Any] {
            for value in array { collect(value, into: &result) }
        }
    }
}

/// Estado de la cuenta en una respuesta de `/next`: el "me gusta" y la suscripción al canal del video.
/// - WEB: `segmentedLikeDislikeButtonViewModel…likeStatusEntity.likeStatus` y `videoSecondaryInfoRenderer.subscribeButton
///   .subscribeButtonRenderer` (`subscribed`, `channelId`, `onSubscribeEndpoints[].subscribeEndpoint.params`).
/// - TV: `transportControls…likeButtonRenderer.likeStatus` y los `subscribeButtonRenderer` del dueño del video.
/// - Las dos: `frameworkUpdates.entityBatchUpdate.mutations[].payload.likeStatusEntity` / `subscriptionStateEntity`.
/// Sin sesión YouTube responde `INDIFFERENT` y `false`.
enum WatchNextAccountState {
    static func apply(_ data: Data, to metadata: inout MediaItemMetadata) {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return }
        var likeStatus: String?
        var buttons: [[String: Any]] = []
        var subscriptionEntity: Bool?
        walk(root) { key, value in
            switch key {
            case "likeStatusEntity", "likeButtonRenderer":
                if likeStatus == nil { likeStatus = (value as? [String: Any])?["likeStatus"] as? String }
            case "subscribeButtonRenderer":
                if let button = value as? [String: Any] { buttons.append(button) }
            case "subscriptionStateEntity":
                if subscriptionEntity == nil { subscriptionEntity = (value as? [String: Any])?["subscribed"] as? Bool }
            default: break
            }
        }
        switch likeStatus {
        case "LIKE": metadata.likeStatus = .like
        case "DISLIKE": metadata.likeStatus = .dislike
        case "INDIFFERENT": metadata.likeStatus = .indifferent
        default: break
        }
        let channelId = metadata.channelId
        let button = buttons.first { channelId != nil && $0["channelId"] as? String == channelId } ?? buttons.first
        metadata.isSubscribed = (button?["subscribed"] as? Bool) ?? subscriptionEntity
        if let endpoints = button?["onSubscribeEndpoints"] as? [[String: Any]],
           let params = endpoints.lazy.compactMap({ ($0["subscribeEndpoint"] as? [String: Any])?["params"] as? String }).first {
            metadata.subscribeParams = params.removingPercentEncoding ?? params
        }
        if metadata.channelId == nil { metadata.channelId = button?["channelId"] as? String }
    }

    /// Recorrido en orden fijo (claves ordenadas) de todo el árbol.
    static func walk(_ node: Any, _ visit: (String, Any) -> Void) {
        if let dict = node as? [String: Any] {
            for key in dict.keys.sorted() {
                visit(key, dict[key]!)
                walk(dict[key]!, visit)
            }
        } else if let array = node as? [Any] {
            for value in array { walk(value, visit) }
        }
    }
}

/// Tokens de `feedbackEndpoint` de una respuesta (el panel del menú de `get_panel`), en orden. Los que van dentro de
/// una confirmación (`openPopupAction`, p. ej. "No recomendar el canal") no cuentan: el primero que queda es
/// "No me interesa" (comprobado el 15-oct-2026: quinta opción del menú, después de Reproducir, Ver más tarde, Guardar
/// en una playlist e Ir al canal).
enum FeedbackTokens {
    static func all(in data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var tokens: [String] = []
        collect(root, into: &tokens)
        return tokens
    }

    private static func collect(_ node: Any, into tokens: inout [String]) {
        if let dict = node as? [String: Any] {
            for key in dict.keys.sorted() where key != "openPopupAction" {
                if key == "feedbackEndpoint", let token = (dict[key] as? [String: Any])?["feedbackToken"] as? String {
                    tokens.append(token)
                } else {
                    collect(dict[key]!, into: &tokens)
                }
            }
        } else if let array = node as? [Any] {
            for value in array { collect(value, into: &tokens) }
        }
    }
}
