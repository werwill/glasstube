import Foundation

/// Qué interfaz de YouTube se usa para cada parte del catálogo. Los valores por omisión salen de comparar TV y WEB
/// para un usuario sin sesión (ver NOTAS.md, "TV o WEB").
public struct SurfacePreferences: Sendable, Hashable {
    public var home: Surface
    public var topics: Surface
    public var search: Surface
    public var channel: Surface
    public var next: Surface

    public init(home: Surface, topics: Surface, search: Surface, channel: Surface, next: Surface) {
        self.home = home
        self.topics = topics
        self.search = search
        self.channel = channel
        self.next = next
    }

    /// Escritorio: WEB en todo (id y avatar del canal en cada tarjeta, extracto de la descripción, pestañas de canal
    /// separadas y sugeridos relacionados). Películas no existe en WEB y va por TV sola.
    public static let recommended = SurfacePreferences(home: .web, topics: .web, search: .web, channel: .web, next: .web)
    /// Lo que hace SmartTube (TV en todo).
    public static let tv = SurfacePreferences(home: .tv, topics: .tv, search: .tv, channel: .tv, next: .tv)
    public static let web = SurfacePreferences(home: .web, topics: .web, search: .web, channel: .web, next: .web)
}

/// Implementación de `ContentService` y `MediaItemService` sobre Innertube (`YouTubeContentService` +
/// `YouTubeMediaItemService` de SmartTube). Con `session`, las peticiones del catálogo van con la cuenta elegida y
/// funcionan las de la cuenta (`AccountService.swift`); sin ella, todo es anónimo.
public final class YouTubeService: ContentService, MediaItemService, @unchecked Sendable {
    public let catalog: ClientCatalog
    public let preferences: SurfacePreferences
    let api: CatalogAPI
    /// PoToken de la app. Pásale el mismo `PoTokenWebViewProvider` al reproductor (SABR) para que haya un solo
    /// WKWebView de BotGuard.
    public let poTokenSource: PoTokenSource?
    /// El resolvedor de streams de `formatInfo`, uno por servicio (comparte catálogo, PoToken y el caché del player).
    public let resolver: StreamResolver
    /// Sesiones y cuentas (nil = sin cuentas).
    public let session: AccountManager?
    let watchTime = WatchTimeTracker()

    public init(catalog: ClientCatalog? = nil, locale: CatalogLocale = .current, preferences: SurfacePreferences = .recommended,
                poTokenSource: PoTokenSource? = nil, session: AccountManager? = nil) throws {
        let catalog = try catalog ?? ClientCatalog.load()
        self.catalog = catalog
        self.preferences = preferences
        self.poTokenSource = poTokenSource
        self.session = session
        resolver = StreamResolver(catalog: catalog, poTokenSource: poTokenSource)
        api = CatalogAPI(catalog: catalog, locale: locale, session: session)
    }

    public var locale: CatalogLocale { api.locale }

    /// `@handle`, URL o id de canal → UC…
    public func resolveChannelId(_ input: String) async throws -> String { try await api.resolveChannelId(input) }

    // MARK: - Páginas

    func browsePage(_ extra: [String: Any], surface: Surface, kind: MediaGroup.Kind, title: String? = nil,
                    looseTitle: String? = nil) async throws -> BrowsePage {
        let data = try await api.post(.browse, surface: surface, extra)
        var page = try await Self.parsePage(data, surface: surface, api: .browse, kind: kind, looseTitle: looseTitle)
        page.title = title
        return page
    }

    /// Convierte una respuesta cruda de `/browse` o `/search` (primera página o continuación).
    public static func parsePage(_ data: Data, surface: Surface, api: Continuation.API, kind: MediaGroup.Kind,
                                 looseTitle: String? = nil) async throws -> BrowsePage {
        try await InnertubeDecoding.run {
            let response = try JSONDecoder().decode(InnertubeResponse.self, from: data)
            return PageExtractor(surface: surface, api: api, kind: kind).page(response.roots, looseTitle: looseTitle)
        }
    }

    /// Convierte una respuesta cruda de `/browse` de un canal.
    public static func parseChannel(_ data: Data, channelId: String, surface: Surface) async throws -> ChannelPage {
        try await InnertubeDecoding.run { try ChannelParser.page(channelId: channelId, data: data, surface: surface) }
    }

    /// Convierte una respuesta cruda de `/next`.
    public static func parseMetadata(_ data: Data, videoId: String, surface: Surface) async throws -> MediaItemMetadata {
        try await InnertubeDecoding.run {
            let response = try JSONDecoder().decode(WatchNextResponse.self, from: data)
            var metadata = WatchNextParser.metadata(videoId: videoId, response: response, surface: surface)
            WatchNextAccountState.apply(data, to: &metadata)
            return metadata
        }
    }

    /// Diagnóstico y grabación de fixtures: la respuesta cruda de `/youtubei/v1/<endpoint>` con el cuerpo de la
    /// interfaz indicada más `fields` (todos los valores del catálogo son cadenas: browseId, params, query, videoId,
    /// continuation).
    public func rawRequest(_ endpoint: String, surface: Surface, fields: [String: String], authenticated: Bool = false,
                           extra: [String: any Sendable] = [:]) async throws -> Data {
        var body: [String: Any] = fields
        for (key, value) in extra { body[key] = value }
        return try await api.post(endpoint, surface: surface, body, auth: authenticated ? .required(endpoint) : .anonymous)
    }

    /// Cuerpo crudo de las sugerencias de búsqueda (diagnóstico).
    public func rawSuggestions(_ query: String) async throws -> Data {
        let (data, _) = try await HTTP.shared.request(SearchSuggestions.url(query: query, locale: api.locale),
                                                      headers: ["User-Agent": Innertube.tvUserAgent])
        return data
    }

    public static func parseSuggestions(_ data: Data) throws -> [String] { try SearchSuggestions.parse(data) }

    // MARK: - ContentService

    /// Con sesión, el Inicio de la cuenta (recomendaciones) por TV, que es la interfaz que acepta la sesión; sin
    /// sesión, `preferences.home`.
    public func home() async throws -> BrowsePage {
        try await home(surface: await api.isSignedIn ? .tv : preferences.home)
    }

    /// Inicio de verdad (`default` en TV, `FEwhat_to_watch` en WEB). Sin cuenta YouTube responde solo con un aviso de
    /// inicio de sesión, así que se arma un Inicio con las primeras filas de cada tema de Explorar.
    public func home(surface: Surface) async throws -> BrowsePage {
        let browseId = surface == .tv ? "default" : "FEwhat_to_watch"
        let page = try await browsePage(["browseId": browseId], surface: surface, kind: .home, title: "Inicio")
        guard page.isEmpty else { return page }

        let topics: [Topic] = [.music, .gaming, .news, .sports, .live]
        let pages = await withTaskGroup(of: (Int, BrowsePage?).self) { group in
            for (index, topic) in topics.enumerated() {
                group.addTask { (index, try? await self.topic(topic, surface: surface)) }
            }
            var results: [(Int, BrowsePage?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
        var fallback = BrowsePage(title: "Inicio", groups: [], surface: surface, notice: page.notice)
        fallback.isFallback = true
        for topicPage in pages {
            for var group in topicPage.groups.filter({ !$0.items.isEmpty }).prefix(2) {
                group.kind = .home
                fallback.groups.append(group)
            }
            fallback.stats.merge(topicPage.stats)
        }
        return fallback
    }

    /// `FEtrending` (WEB, con los `params` de SmartTube). YouTube retiró la página de Tendencias en 2025 y responde
    /// 400; entonces se devuelve la clasificación de Hype (`FEhype_leaderboard`), lo más parecido sin cuenta.
    public func trending() async throws -> BrowsePage {
        do {
            let page = try await browsePage(["browseId": "FEtrending", "params": "6gQJRkVleHBsb3Jl"], surface: .web,
                                            kind: .trending, title: "Tendencias")
            if !page.isEmpty { return page }
        } catch let error as HTTPError where error.status == 400 {
            Log.debug("FEtrending: HTTP 400; se usa FEhype_leaderboard")
        }
        var page = try await browsePage(["browseId": "FEhype_leaderboard"], surface: .web, kind: .trending, title: "Hype")
        page.isFallback = true
        return page
    }

    public func topic(_ topic: Topic) async throws -> BrowsePage { try await self.topic(topic, surface: preferences.topics) }

    /// Tema de Explorar: `FEtopics_*` en TV; en WEB, el canal del tema (Películas solo existe en TV).
    public func topic(_ topic: Topic, surface: Surface) async throws -> BrowsePage {
        if surface == .web, let channelId = topic.webChannelId {
            return try await browsePage(["browseId": channelId], surface: .web, kind: .topic, title: topic.rawValue)
        }
        return try await browsePage(["browseId": topic.tvBrowseId], surface: .tv, kind: .topic, title: topic.rawValue)
    }

    public func search(_ query: String, params: String?) async throws -> BrowsePage {
        try await search(query, params: params, surface: preferences.search)
    }

    public func search(_ query: String, params: String? = nil, surface: Surface) async throws -> BrowsePage {
        var extra: [String: Any] = ["query": query]
        if let params { extra["params"] = params }
        let data = try await api.post(.search, surface: surface, extra)
        var page = try await Self.parsePage(data, surface: surface, api: .search, kind: .search, looseTitle: "Resultados")
        page.title = query
        return page
    }

    public func searchSuggestions(_ query: String) async throws -> [String] {
        let url = SearchSuggestions.url(query: query, locale: api.locale)
        // Como SmartTube (`SearchApi2`): User-Agent de TV y el visitorData anónimo.
        var headers = ["User-Agent": Innertube.tvUserAgent]
        if let visitorData = await api.visitor.visitorData() { headers["X-Goog-Visitor-Id"] = visitorData }
        let (data, response) = try await HTTP.shared.request(url, headers: headers)
        guard response.statusCode == 200 else {
            throw HTTPError(status: response.statusCode, url: url.absoluteString, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try SearchSuggestions.parse(data)
    }

    public func channel(_ channelId: String, tab: ChannelTab.Kind) async throws -> ChannelPage {
        try await channel(channelId, tab: tab, surface: preferences.channel)
    }

    /// WEB pide la pestaña con su `params` (las constantes de SmartTube o, si el canal usa otro, el de su lista de
    /// pestañas). TV no distingue pestañas: devuelve siempre las filas del canal.
    public func channel(_ channelId: String, tab: ChannelTab.Kind, surface: Surface) async throws -> ChannelPage {
        let id = try await api.resolveChannelId(channelId)
        var params = tab.defaultParams
        var page: ChannelPage
        if surface == .tv {
            page = try await fetchChannel(id, params: nil, surface: .tv)
        } else if params == nil, tab != .home {
            page = try await fetchChannel(id, params: ChannelTab.Kind.home.defaultParams, surface: .web)
            guard let found = page.tabs.first(where: { $0.kind == tab })?.params else { return page }
            params = found
            page = try await fetchChannel(id, params: params, surface: .web)
        } else {
            page = try await fetchChannel(id, params: params, surface: .web)
            if page.selectedTab != tab, let other = page.tabs.first(where: { $0.kind == tab })?.params, other != params {
                page = try await fetchChannel(id, params: other, surface: .web)
            }
        }
        return page
    }

    func fetchChannel(_ id: String, params: String?, surface: Surface) async throws -> ChannelPage {
        var extra: [String: Any] = ["browseId": id]
        if let params { extra["params"] = params }
        let data = try await api.post(.browse, surface: surface, extra)
        return try await Self.parseChannel(data, channelId: id, surface: surface)
    }

    /// Con sesión, Ver más tarde (`WL`), Me gusta (`LL`) y las listas privadas van por TV con la cuenta; las públicas,
    /// por `preferences.channel` (WEB, anónima).
    public func playlist(_ playlistId: String) async throws -> BrowsePage {
        let id = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let signedIn = await api.isSignedIn
        if signedIn, [Self.watchLaterPlaylistId, Self.likedVideosPlaylistId].contains(id) {
            return try await playlist(id, surface: .tv)
        }
        let page = try? await playlist(id, surface: preferences.channel)
        if let page, !page.isEmpty || !signedIn || preferences.channel == .tv { return page }
        // Vacía o con error sin cuenta: puede ser privada de la cuenta.
        if signedIn { return try await playlist(id, surface: .tv) }
        return try await playlist(id, surface: preferences.channel)
    }

    /// `browse` de `VL<id>`: WEB da `lockupViewModel` con `continuationItemViewModel`; TV, tiles en filas.
    public func playlist(_ playlistId: String, surface: Surface) async throws -> BrowsePage {
        let id = playlistId.hasPrefix("VL") ? playlistId : "VL" + playlistId
        let data = try await api.post(.browse, surface: surface, ["browseId": id])
        var page = try await Self.parsePage(data, surface: surface, api: .browse, kind: .unknown)
        page.title = try await InnertubeDecoding.run { try JSONDecoder().decode(PlaylistHeader.self, from: data).title }
        return page
    }

    public func continueGroup(_ group: MediaGroup) async throws -> MediaGroup {
        guard let continuation = group.continuation else { throw YTKitError.notAvailable("la fila no tiene continuación") }
        let data = try await api.post(continuation.api, surface: continuation.surface, ["continuation": continuation.token])
        let kind = group.kind
        let result = try await InnertubeDecoding.run {
            let response = try JSONDecoder().decode(InnertubeResponse.self, from: data)
            return PageExtractor(surface: continuation.surface, api: continuation.api, kind: kind).extract(response.roots)
        }
        // Lo suelto es la continuación de la fila. Si solo llegaron filas (la búsqueda de TV responde con otra
        // `sectionListContinuation`), se toma la del mismo título o, si no, la primera.
        var items = result.loose
        var token = result.looseToken
        if items.isEmpty, let match = result.groups.first(where: { $0.title == group.title }) ?? result.groups.first {
            items = match.items
            token = match.continuation?.token
        }
        // Algunas continuaciones de TV (`reloadContinuationData`, p. ej. en Playlists con cuenta) vuelven a dar lo mismo:
        // se quitan los repetidos y, si no llegó nada nuevo, la fila termina.
        let known = Set(group.items.map(\.id))
        let fresh = items.filter { !known.contains($0.id) }
        if fresh.isEmpty { token = nil }
        return MediaGroup(kind: group.kind, title: group.title, items: fresh,
                          continuation: token.map { Continuation(token: $0, api: continuation.api, surface: continuation.surface) },
                          moreEndpoint: group.moreEndpoint, renderer: group.renderer)
    }

    public func continuePage(_ continuation: Continuation) async throws -> BrowsePage {
        let data = try await api.post(continuation.api, surface: continuation.surface, ["continuation": continuation.token])
        let kind: MediaGroup.Kind = continuation.api == .search ? .search : (continuation.api == .next ? .suggestions : .unknown)
        return try await Self.parsePage(data, surface: continuation.surface, api: continuation.api, kind: kind)
    }

    public func subscriptions() async throws -> BrowsePage { try await accountSubscriptions() }
    public func history() async throws -> BrowsePage { try await accountHistory() }
    public func playlists() async throws -> BrowsePage { try await accountPlaylists() }

    // MARK: - MediaItemService

    /// Con sesión y `preferences.next` en WEB, los metadatos salen de WEB (anónima) y el estado de la cuenta (me gusta,
    /// suscripción) de un `next` de TV con la cuenta, en paralelo.
    public func metadata(videoId: String, playlistId: String?, playlistIndex: Int?, params: String?) async throws -> MediaItemMetadata {
        let surface = preferences.next
        guard surface == .web, await api.isSignedIn else {
            return try await metadata(videoId: videoId, playlistId: playlistId, playlistIndex: playlistIndex, params: params, surface: surface)
        }
        async let web = metadata(videoId: videoId, playlistId: playlistId, playlistIndex: playlistIndex, params: params, surface: .web)
        async let tv = try? metadata(videoId: videoId, surface: .tv)
        var metadata = try await web
        if let state = await tv {
            metadata.likeStatus = state.likeStatus
            metadata.isSubscribed = state.isSubscribed
            metadata.subscribeParams = state.subscribeParams ?? metadata.subscribeParams
        } else {
            // Sin el estado de la cuenta: mejor nil que el "indiferente" anónimo de WEB.
            metadata.likeStatus = nil
            metadata.isSubscribed = nil
        }
        return metadata
    }

    public func metadata(videoId: String, playlistId: String? = nil, playlistIndex: Int? = nil, params: String? = nil,
                         surface: Surface) async throws -> MediaItemMetadata {
        var extra: [String: Any] = ["videoId": videoId]
        if let playlistId { extra["playlistId"] = playlistId }
        if let playlistIndex { extra["playlistIndex"] = playlistIndex }
        if let params { extra["params"] = params }
        let data = try await api.post(.next, surface: surface, extra)
        return try await Self.parseMetadata(data, videoId: videoId, surface: surface)
    }

    public func formatInfo(videoId: String, options: ResolveOptions) async -> ResolveReport {
        await resolver.resolve(videoId: videoId, options: options)
    }

}
