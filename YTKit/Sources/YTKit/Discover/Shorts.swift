import Foundation

// Feed de Shorts (`BrowseService2.getShortsWeb` de SmartTube), por la interfaz WEB y sin cuenta:
//
// 1. `reel/reel_item_watch` con `inputType: REEL_WATCH_INPUT_TYPE_SEEDLESS` y `params: "CA8%3D"` (como
//    `BrowseApiHelper.REEL`) da el primer Short y `sequenceContinuation`.
// 2. `reel/reel_watch_sequence` con `sequenceParams` da los diez siguientes (`entries[].command.reelWatchEndpoint`:
//    id, `params` y la miniatura vertical) y la continuación (`continuationEndpoint.continuationCommand.token`).
// 3. Las entradas no traen título ni canal (solo la primera trae un `playerResponse` precargado): como SmartTube, se pide
//    `reel_item_watch` de cada una con su `params` y se lee la cabecera de la descripción
//    (`videoDescriptionHeaderRenderer`: título, canal, vistas, fecha). Unos 245 KB por Short; van de 5 en 5.

struct ReelItemResponse: Decodable, Sendable {
    struct Replacement: Decodable, Sendable { @Lenient var reelWatchEndpoint: ReelWatchEndpoint? }
    struct Overlay: Decodable, Sendable {
        struct Renderer: Decodable, Sendable {
            struct Supported: Decodable, Sendable { @Lenient var reelPlayerHeaderRenderer: Header? }
            @Lenient var reelPlayerHeaderSupportedRenderers: Supported?
        }
        struct Header: Decodable, Sendable {
            @Lenient var timestampText: YTText?
            @Lenient var channelTitleText: YTText?
            @Lenient var channelNavigationEndpoint: NavigationEndpoint?
        }
        @Lenient var reelPlayerOverlayRenderer: Renderer?
    }
    struct Panel: Decodable, Sendable {
        struct Section: Decodable, Sendable {
            struct Content: Decodable, Sendable {
                struct Structured: Decodable, Sendable {
                    struct Item: Decodable, Sendable { @Lenient var videoDescriptionHeaderRenderer: DescriptionHeader? }
                    @Lenient var items: [Item]?
                }
                @Lenient var structuredDescriptionContentRenderer: Structured?
            }
            @Lenient var content: Content?
        }
        @Lenient var engagementPanelSectionListRenderer: Section?
    }
    struct DescriptionHeader: Decodable, Sendable {
        @Lenient var title: YTText?
        @Lenient var channel: YTText?
        @Lenient var views: YTText?
        @Lenient var publishDate: YTText?
        @Lenient var channelNavigationEndpoint: NavigationEndpoint?
        @Lenient var channelThumbnail: ThumbnailList?
    }

    @Lenient var replacementEndpoint: Replacement?
    @Lenient var sequenceContinuation: String?
    @Lenient var overlay: Overlay?
    @Lenient var engagementPanels: [Panel]?

    var descriptionHeader: DescriptionHeader? {
        (engagementPanels ?? []).lazy.compactMap {
            $0.engagementPanelSectionListRenderer?.content?.structuredDescriptionContentRenderer?.items?
                .lazy.compactMap(\.videoDescriptionHeaderRenderer).first
        }.first
    }

    /// El Short de la respuesta como tarjeta. `endpoint`: el de la secuencia (id y miniatura) si se pidió por él.
    func item(endpoint: ReelWatchEndpoint?) -> MediaItem? {
        let watch = endpoint ?? replacementEndpoint?.reelWatchEndpoint
        guard let videoId = watch?.videoId, let header = descriptionHeader, let title = header.title?.string else { return nil }
        let overlayHeader = overlay?.reelPlayerOverlayRenderer?.reelPlayerHeaderSupportedRenderers?.reelPlayerHeaderRenderer
        var item = MediaItem(kind: .video, title: title, renderer: "reelItemWatch")
        item.videoId = videoId
        item.isShort = true
        item.author = header.channel?.string ?? overlayHeader?.channelTitleText?.string
        item.channelId = (header.channelNavigationEndpoint ?? overlayHeader?.channelNavigationEndpoint)?.browseEndpoint?.browseId
        item.viewCountText = header.views?.string
        // «hace 17 horas» del reproductor de Shorts; si no, la fecha de la descripción.
        item.publishedText = overlayHeader?.timestampText?.string ?? header.publishDate?.string
        // `frame0` (el primer cuadro, que a veces es negro) queda de respaldo: primero la miniatura que eligió el canal, en
        // 4:3 con franjas a los lados (la tarjeta vertical recorta el centro).
        item.thumbnails = Self.coverThumbnails(videoId) + Convert.thumbnails(watch?.thumbnail)
        item.authorThumbnails = Convert.thumbnails(header.channelThumbnail)
        return item
    }
}

extension ReelItemResponse {
    /// `sddefault` (640×480) y `hqdefault` (480×360) de i.ytimg.com: la portada del Short con franjas negras a los lados.
    static func coverThumbnails(_ videoId: String) -> [Thumbnail] {
        [Thumbnail(url: "https://i.ytimg.com/vi/\(videoId)/sddefault.jpg", width: 640, height: 480),
         Thumbnail(url: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg", width: 480, height: 360)]
    }
}

struct ReelSequenceResponse: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        struct Command: Decodable, Sendable { @Lenient var reelWatchEndpoint: ReelWatchEndpoint? }
        @Lenient var command: Command?
    }
    @Lenient var entries: [Entry]?
    @Lenient var continuationEndpoint: NavigationEndpoint?
    @Lenient var continuation: String?

    var endpoints: [ReelWatchEndpoint] { (entries ?? []).compactMap { $0.command?.reelWatchEndpoint }.filter { $0.videoId != nil } }
    var nextToken: String? { continuationEndpoint?.continuationCommand?.token ?? continuation }
}

extension YouTubeService {
    /// `params` del primer pedido (`BrowseApiHelper.REEL`), tal cual lo manda SmartTube.
    static let seedlessReelParams = "CA8%3D"
    /// Cuántos detalles de Shorts se piden a la vez.
    static let reelDetailConcurrency = 5

    /// Feed de Shorts (WEB, anónimo): una fila con los primeros once y la continuación de la secuencia.
    public func shorts() async throws -> BrowsePage {
        let data = try await api.post("reel/reel_item_watch", surface: .web,
                                      ["disablePlayerResponse": true, "inputType": "REEL_WATCH_INPUT_TYPE_SEEDLESS",
                                       "params": Self.seedlessReelParams], auth: .anonymous)
        let first = try await InnertubeDecoding.run { try JSONDecoder().decode(ReelItemResponse.self, from: data) }
        var items = [first.item(endpoint: nil)].compactMap { $0 }
        var next: String?
        if let token = first.sequenceContinuation {
            let more = try await shortsSequence(token)
            items += more.items.filter { new in !items.contains { $0.videoId == new.videoId } }
            next = more.next
        }
        guard !items.isEmpty else { throw YTKitError.badResponse("el feed de Shorts llegó vacío") }
        let group = MediaGroup(kind: .shorts, title: "Shorts", items: items,
                               continuation: next.map { Continuation(token: $0, api: .reel, surface: .web) },
                               renderer: "reelWatchSequence")
        return BrowsePage(title: "Shorts", groups: [group], surface: .web)
    }

    /// Una página de la secuencia de Shorts con los detalles de cada uno.
    func shortsSequence(_ token: String) async throws -> (items: [MediaItem], next: String?) {
        let data = try await api.post("reel/reel_watch_sequence", surface: .web, ["sequenceParams": token], auth: .anonymous)
        let sequence = try await InnertubeDecoding.run { try JSONDecoder().decode(ReelSequenceResponse.self, from: data) }
        let endpoints = sequence.endpoints
        let details = await withTaskGroup(of: (Int, MediaItem?).self) { group -> [Int: MediaItem] in
            var found: [Int: MediaItem] = [:]
            var next = 0
            func launch() {
                guard next < endpoints.count else { return }
                let index = next
                next += 1
                group.addTask { (index, try? await self.reelDetails(endpoints[index])) }
            }
            for _ in 0..<min(Self.reelDetailConcurrency, endpoints.count) { launch() }
            while let (index, item) = await group.next() {
                if let item { found[index] = item }
                launch()
            }
            return found
        }
        let items = endpoints.indices.compactMap { details[$0] }
        Log.debug("Shorts: \(endpoints.count) en la secuencia, \(items.count) con detalles")
        return (items, sequence.nextToken)
    }

    /// `reel_item_watch` de un Short de la secuencia (`getReelDetailsQuery`).
    func reelDetails(_ endpoint: ReelWatchEndpoint) async throws -> MediaItem? {
        guard let videoId = endpoint.videoId else { return nil }
        var body: [String: Any] = ["disablePlayerResponse": true, "playerRequest": ["videoId": videoId]]
        if let params = endpoint.params { body["params"] = params }
        let data = try await api.post("reel/reel_item_watch", surface: .web, body, auth: .anonymous)
        let response = try await InnertubeDecoding.run { try JSONDecoder().decode(ReelItemResponse.self, from: data) }
        return response.item(endpoint: endpoint)
    }

    /// Más Shorts (`continueGroup` de una fila de `shorts()`).
    func continueShorts(_ group: MediaGroup, token: String) async throws -> MediaGroup {
        let more = try await shortsSequence(token)
        let known = Set(group.items.map(\.id))
        let fresh = more.items.filter { !known.contains($0.id) }
        return MediaGroup(kind: .shorts, title: group.title, items: fresh,
                          continuation: more.next.map { Continuation(token: $0, api: .reel, surface: .web) },
                          renderer: group.renderer)
    }

    /// Convierte respuestas crudas de `reel_item_watch` y `reel_watch_sequence` (pruebas con fixtures).
    public static func parseShorts(first: Data, sequence: Data, details: [String: Data]) async throws -> (items: [MediaItem], next: String?) {
        try await InnertubeDecoding.run {
            let decoder = JSONDecoder()
            let firstResponse = try decoder.decode(ReelItemResponse.self, from: first)
            let sequenceResponse = try decoder.decode(ReelSequenceResponse.self, from: sequence)
            var items = [firstResponse.item(endpoint: nil)].compactMap { $0 }
            for endpoint in sequenceResponse.endpoints {
                guard let id = endpoint.videoId, let data = details[id],
                      let item = try decoder.decode(ReelItemResponse.self, from: data).item(endpoint: endpoint) else { continue }
                items.append(item)
            }
            return (items, sequenceResponse.nextToken)
        }
    }
}
