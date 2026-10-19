import Foundation
import YTKit

/// `ytkit record <carpeta>`: graba respuestas reales de Innertube para las pruebas (Tests/YTKitTests/Fixtures).
/// Quita solo lo que no usa el parser y pesa mucho (parámetros de rastreo, metadatos de comandos, la barra superior);
/// el resto queda tal cual llegó, para que las pruebas vean la forma real de cada respuesta.
@MainActor
struct Recorder {
    let service: YouTubeService
    let directory: String?
    /// Si no está vacío, solo se escriben estas fixtures (las demás se piden igual, por los tokens de continuación).
    var only: Set<String> = []

    static let prunedKeys: Set<String> = [
        "trackingParams", "clickTrackingParams", "loggingContext", "loggingDirectives", "commandMetadata",
        "watchEndpointSupportedOnesieConfig", "watchEndpointSupportedPrefetchConfig", "topbar", "microformat",
        "serializedShareEntity", "sequenceParams", "serviceTrackingParams", "mainAppWebResponseContext",
        "webResponseContextExtensionData", "adPlacements", "playerAds", "prefetchTime", "hotkeyDialog",
        // Decoración y acciones que el parser no lee.
        "themedPalette", "darkColorPalette", "vibrantColorPalette", "sampledThumbnailColor", "styleRuns",
        "attachmentRuns", "buttonViewModel", "inlinePlaybackEndpoint", "richThumbnail", "itemPlayback",
        "unifiedSharePanelRenderer", "thumbnailOverlayToggleButtonRenderer", "thumbnailOverlayNowPlayingRenderer",
        "thumbnailOverlayLoadingPreviewRenderer", "thumbnailHoverOverlayViewModel", "playerParams", "ustreamerConfig",
        "toggleButtonViewModel", "listItemViewModel", "playlistSidebarRenderer",
    ]

    /// Listas de elementos que se recortan a `maxItems` (conservando un `continuationItemRenderer` final).
    static let trimmedLists: Set<String> = ["items", "contents", "continuationItems", "results"]
    static let maxItems = 10

    var outputURL: URL { URL(fileURLWithPath: directory ?? "Tests/YTKitTests/Fixtures", isDirectory: true) }

    func run() async throws {
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let mrbeast = "UCX6OQ3DkcsbYNE6H8uQQuVA", lofiGirl = "UCSJ4gkVC6NrvII8umztf0Ow", python = "rfscVS0vtbw"

        try await save("home-tv", "browse", .tv, ["browseId": "default"])
        try await save("home-web", "browse", .web, ["browseId": "FEwhat_to_watch"])
        try await save("topic-music-tv", "browse", .tv, ["browseId": "FEtopics_music"])
        let news = try await save("topic-news-tv", "browse", .tv, ["browseId": "FEtopics_news"])
        try await saveRowContinuation("topic-news-tv-rowcont", from: news, .tv, api: .browse)
        try await save("topic-news-web", "browse", .web, ["browseId": "UCYfdidRxbB8Qhf0Nx7ioOYw"])
        try await save("trending-hype-web", "browse", .web, ["browseId": "FEhype_leaderboard"])

        let searchTV = try await save("search-tv", "search", .tv, ["query": "lofi hip hop"])
        try await saveRowContinuation("search-tv-cont", from: searchTV, .tv, api: .search)
        let searchWeb = try await save("search-web", "search", .web, ["query": "lofi hip hop"])
        try await saveRowContinuation("search-web-cont", from: searchWeb, .web, api: .search)
        try await save("search-web-mixed", "search", .web, ["query": "mrbeast"])
        try await save("search-tv-mixed", "search", .tv, ["query": "mrbeast"])

        try await save("channel-tv", "browse", .tv, ["browseId": mrbeast])
        try await save("channel-web-home", "browse", .web, ["browseId": mrbeast, "params": ChannelTab.Kind.home.defaultParams])
        let videos = try await save("channel-web-videos", "browse", .web, ["browseId": mrbeast, "params": ChannelTab.Kind.videos.defaultParams])
        try await saveRowContinuation("channel-web-videos-cont", from: videos, .web, api: .browse)
        try await save("channel-web-shorts", "browse", .web, ["browseId": mrbeast, "params": ChannelTab.Kind.shorts.defaultParams])
        try await save("channel-web-live", "browse", .web, ["browseId": lofiGirl, "params": ChannelTab.Kind.live.defaultParams])
        try await save("channel-web-playlists", "browse", .web, ["browseId": lofiGirl, "params": ChannelTab.Kind.playlists.defaultParams])
        try await save("channel-web-missing-tab", "browse", .web, ["browseId": mrbeast, "params": ChannelTab.Kind.playlists.defaultParams])

        let playlist = try await save("playlist-web", "browse", .web, ["browseId": "VLPLdkGTI2esnoY"])
        try await saveRowContinuation("playlist-web-cont", from: playlist, .web, api: .browse)
        try await save("playlist-tv", "browse", .tv, ["browseId": "VLPLdkGTI2esnoY"])

        let nextWeb = try await save("next-web", "next", .web, ["videoId": python])
        if let meta = try? await YouTubeService.parseMetadata(nextWeb, videoId: python, surface: .web),
           let token = meta.suggestions.lazy.compactMap(\.continuation).first?.token {
            try await save("next-web-cont", "next", .web, ["continuation": token])
        }
        let nextTV = try await save("next-tv", "next", .tv, ["videoId": python])
        if let meta = try? await YouTubeService.parseMetadata(nextTV, videoId: python, surface: .tv),
           let token = meta.suggestionsContinuation?.token {
            try await save("next-tv-cont", "next", .tv, ["continuation": token])
        }

        guard only.isEmpty else { return }
        let suggestions = try await service.rawSuggestions("lofi")
        try suggestions.write(to: outputURL.appendingPathComponent("suggestions-lofi.txt"))
        print("suggestions-lofi.txt: \(suggestions.count) B")

        let info: [String: Any] = [
            "fecha": ISO8601DateFormatter().string(from: Date()),
            "hl": service.locale.language, "gl": service.locale.region,
            "nota": "Grabado con `ytkit record`, sin sesión. Listas \(Self.trimmedLists.sorted()) recortadas a \(Self.maxItems) "
                + "elementos (más el continuationItemRenderer final). Claves quitadas: " + Self.prunedKeys.sorted().joined(separator: ", "),
        ]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputURL.appendingPathComponent("_grabacion.json"))
    }

    /// Graba la respuesta podada y devuelve la cruda (para sacar de ella los tokens de continuación).
    @discardableResult
    func save(_ name: String, _ endpoint: String, _ surface: Surface, _ fields: [String: String?]) async throws -> Data {
        let raw = try await service.rawRequest(endpoint, surface: surface, fields: fields.compactMapValues { $0 })
        guard only.isEmpty || only.contains(name) else { return raw }
        let pruned = try Self.prune(raw, keepFrameworkUpdates: endpoint == "next")
        try pruned.write(to: outputURL.appendingPathComponent(name + ".json"))
        print("\(name).json: \(raw.count) B → \(pruned.count) B")
        return raw
    }

    /// Continuación de la primera fila que la tenga o, si no hay, de la página.
    func saveRowContinuation(_ name: String, from data: Data, _ surface: Surface, api: Continuation.API) async throws {
        let page = try await YouTubeService.parsePage(data, surface: surface, api: api, kind: .unknown)
        guard let token = page.groups.lazy.compactMap(\.continuation).first?.token ?? page.continuation?.token else {
            print("\(name): sin token de continuación; no se graba")
            return
        }
        try await save(name, api.rawValue, surface, ["continuation": token])
    }

    static func prune(_ data: Data, keepFrameworkUpdates: Bool) throws -> Data {
        func walk(_ value: Any, key: String?) -> Any {
            if let dict = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, child) in dict where !prunedKeys.contains(key) {
                    if key == "frameworkUpdates", !keepFrameworkUpdates { continue }
                    out[key] = walk(child, key: key)
                }
                return out
            }
            if var array = value as? [Any] {
                if let key, trimmedLists.contains(key), array.count > maxItems {
                    let last = array.last as? [String: Any]
                    array = Array(array.prefix(maxItems))
                    if let last, last["continuationItemRenderer"] != nil { array.append(last) }
                }
                return array.map { walk($0, key: nil) }
            }
            return value
        }
        let json = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: walk(json, key: nil), options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
