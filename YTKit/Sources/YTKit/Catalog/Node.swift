import Foundation

/// Un objeto de una lista de Innertube (`{"tileRenderer": {...}}`, `{"shelfRenderer": {...}}`…), decodificado según el
/// nombre de su renderer. Nunca falla: un renderer desconocido se trata como contenedor genérico y uno conocido que no
/// se puede leer queda como `.failed`, sin arrastrar a sus vecinos de la lista.
struct Node: Decodable, Sendable {
    enum Value: Sendable {
        case item(ItemRenderer)
        case container(Container)
        case continuation(ContinuationItemRenderer)
        /// Aviso de YouTube en lugar de contenido (`feedNudgeRenderer`, `messageRenderer`).
        case notice(String)
        /// Renderer conocido que no es contenido navegable (anuncios, publicaciones, avisos de inicio de sesión…).
        case ignored
        case failed(String)
    }

    let key: String
    let value: Value

    init(key: String, value: Value) {
        self.key = key
        self.value = value
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: AnyKey.self) else {
            key = "?"
            value = .ignored
            return
        }
        let keys = container.allKeys.map(\.stringValue)
        let renderers = keys.filter(Node.looksLikeRenderer).sorted()
        // A veces un mismo objeto trae dos renderers (`content: {sectionListRenderer, richGridRenderer}` en los canales
        // de tema): se recorren los dos como hijos de un contenedor sin nombre.
        if renderers.count > 1 {
            key = renderers.joined(separator: "+")
            value = .container(Container(children: renderers.map { Node(key: $0, value: Node.value(for: $0, in: container)) }))
            return
        }
        guard let chosen = renderers.first ?? keys.first(where: { !Node.metadataKeys.contains($0) }) else {
            key = "?"
            value = .ignored
            return
        }
        key = chosen
        value = Node.value(for: chosen, in: container)
    }

    static func value(for key: String, in container: KeyedDecodingContainer<AnyKey>) -> Value {
        let nested = AnyKey(key)
        do {
            if let kind = itemKinds[key] {
                return .item(try ItemRenderer.decode(kind, from: container, key: nested))
            } else if noticeKeys.contains(key) {
                let notice = try container.decode(NoticeRenderer.self, forKey: nested)
                return notice.textValue.map(Value.notice) ?? .ignored
            } else if key == "continuationItemRenderer" || key == "continuationItemViewModel" {
                return .continuation(try container.decode(ContinuationItemRenderer.self, forKey: nested))
            } else if ignoredKeys.contains(key) {
                return .ignored
            } else {
                return .container(try container.decode(Container.self, forKey: nested))
            }
        } catch {
            return .failed(String(describing: error).prefix(300).description)
        }
    }

    var container: Container? { if case .container(let c) = value { return c } else { return nil } }

    static func looksLikeRenderer(_ key: String) -> Bool {
        key.hasSuffix("Renderer") || key.hasSuffix("ViewModel") || key.hasSuffix("Action") || key.hasSuffix("Command")
            || key.hasSuffix("Continuation")
    }

    static let metadataKeys: Set<String> = ["trackingParams", "clickTrackingParams", "loggingDirectives", "targetId"]

    /// Renderers de elemento soportados (SmartTube: `ItemWrapper` en CommonItems.kt).
    static let itemKinds: [String: ItemRenderer.Kind] = [
        "tileRenderer": .tile,
        "lockupViewModel": .lockup,
        "videoRenderer": .video, "gridVideoRenderer": .video, "compactVideoRenderer": .video,
        "playlistVideoRenderer": .video, "playlistPanelVideoRenderer": .video, "reelItemRenderer": .video,
        "pivotVideoRenderer": .video, "endScreenVideoRenderer": .video, "movieRenderer": .video,
        "gridMovieRenderer": .video, "compactMovieRenderer": .video, "childVideoRenderer": .video,
        "shortsLockupViewModel": .shortsLockup,
        "channelRenderer": .channel, "gridChannelRenderer": .channel, "compactChannelRenderer": .channel,
        "pivotChannelRenderer": .channel,
        "playlistRenderer": .playlist, "gridPlaylistRenderer": .playlist, "compactPlaylistRenderer": .playlist,
        "pivotPlaylistRenderer": .playlist, "radioRenderer": .mix, "compactRadioRenderer": .mix,
        "gridRadioRenderer": .mix, "pivotRadioRenderer": .mix,
    ]

    static let noticeKeys: Set<String> = ["feedNudgeRenderer", "messageRenderer"]

    /// Renderers que se saltan a propósito: no son videos, canales ni listas, o no sirven sin cuenta.
    static let ignoredKeys: Set<String> = [
        "adSlotRenderer", "promotedSparklesWebRenderer", "searchPyvRenderer", "inFeedAdLayoutRenderer",
        "postRenderer", "backstagePostThreadRenderer", "sharedPostRenderer",
        "searchBarRenderer", "alertWithActionsRenderer",
        "backgroundPromoRenderer", "statementBannerRenderer", "clarificationRenderer", "emergencyOneboxRenderer",
        "chipCloudRenderer", "relatedChipCloudRenderer", "feedFilterChipBarRenderer", "sortFilterSubMenuRenderer",
        "horizontalCardListRenderer", "searchRefinementCardRenderer", "officialCardViewModel",
        "channelVideoPlayerRenderer", "recognitionShelfRenderer", "merchandiseShelfRenderer", "ticketShelfRenderer",
        "buttonRenderer", "buttonViewModel", "commentsEntryPointHeaderRenderer", "commentsHeaderRenderer",
        "commentThreadRenderer", "compositeVideoPrimaryInfoRenderer", "videoPrimaryInfoRenderer",
        "videoSecondaryInfoRenderer", "videoMetadataRenderer", "brandVideoShelfRenderer", "brandVideoSingletonRenderer",
        "movingThumbnailRenderer", "playlistSidebarRenderer", "showingResultsForRenderer", "didYouMeanRenderer",
        "infoPanelContainerRenderer", "itemSectionHeaderRenderer",
    ]
}

/// `feedNudgeRenderer` ("Dale tu toque a YouTube. Inicia sesión…") y `messageRenderer` ("No hay resultados").
struct NoticeRenderer: Decodable, Sendable {
    @Lenient var title: YTText?
    @Lenient var subtitle: YTText?
    @Lenient var text: YTText?

    var textValue: String? {
        let parts = [title?.string, subtitle?.string, self.text?.string].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }
}

/// Contenedor genérico: cualquier renderer que no es un elemento. Junta los campos estructurales que usan todos los
/// contenedores de TV y de WEB (`content`, `contents`, `items`, `tabs`, `continuations`, `continuationItems`…), así
/// un contenedor nuevo con la forma de siempre se recorre sin código nuevo.
final class Container: Decodable, @unchecked Sendable {
    @Lenient var title: YTText?
    @Lenient var headline: YTText?
    @Lenient var header: Node?
    @Lenient var headerRenderer: Node?
    @Lenient var avatarLockup: Node?
    @Lenient var content: Node?
    @Lenient var primaryContents: Node?
    /// `twoColumnRenderer` de TV (página de una lista): a la derecha, `playlistVideoListRenderer`.
    @Lenient var rightColumn: Node?
    @Lenient var contents: [Node]?
    @Lenient var items: [Node]?
    @Lenient var tabs: [Node]?
    /// `tvSecondaryNavRenderer.sections` (Suscripciones de TV: "Todos" y una pestaña por canal).
    @Lenient var sections: [Node]?
    @Lenient var results: [Node]?
    @Lenient var continuationItems: [Node]?
    @Lenient var continuations: [ContinuationData]?
    @Lenient var endpoint: NavigationEndpoint?
    @Lenient var selected: Bool?
    @Lenient var tvhtml5ShelfRendererType: String?

    init(children: [Node]) {
        contents = children
    }

    /// Hijos con contenido, en orden. Las cabeceras no se recorren (traen chips, botones y menús).
    var children: [Node] {
        var nodes: [Node] = []
        if let content { nodes.append(content) }
        if let primaryContents { nodes.append(primaryContents) }
        if let rightColumn { nodes.append(rightColumn) }
        nodes += contents ?? []
        nodes += items ?? []
        nodes += selectedTabs
        nodes += sections ?? []
        nodes += results ?? []
        nodes += continuationItems ?? []
        return nodes
    }

    /// Si alguna pestaña está elegida, solo esa: en Suscripciones de TV cada una de las ~120 pestañas (una por canal)
    /// trae su propio contenido y la elegida es "Todos". En WEB solo la elegida trae contenido, así que da lo mismo.
    var selectedTabs: [Node] {
        let all = tabs ?? []
        let selected = all.filter { $0.container?.selected == true }
        return selected.isEmpty ? all : selected
    }

    var continuationToken: String? { continuations?.lazy.compactMap(\.token).first }

    /// Título del contenedor o de su cabecera: `title` (WEB), `headline` (sectionHeaderViewModel) o
    /// `headerRenderer.shelfHeaderRenderer.avatarLockup.avatarLockupRenderer.title` (TV).
    var resolvedTitle: String? {
        if let title = (title?.string ?? headline?.string)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        for node in [header, headerRenderer, avatarLockup] {
            if let title = node?.container?.resolvedTitle { return title }
        }
        return nil
    }
}

/// Un renderer de elemento ya decodificado.
enum ItemRenderer: Sendable {
    enum Kind: Sendable { case tile, lockup, video, shortsLockup, channel, playlist, mix }

    case tile(TileRenderer)
    case lockup(LockupViewModel)
    case video(VideoRenderer)
    case shortsLockup(ShortsLockupViewModel)
    case channel(ChannelRenderer)
    case playlist(PlaylistRenderer, isMix: Bool)

    static func decode(_ kind: Kind, from container: KeyedDecodingContainer<AnyKey>, key: AnyKey) throws -> ItemRenderer {
        switch kind {
        case .tile: return .tile(try container.decode(TileRenderer.self, forKey: key))
        case .lockup: return .lockup(try container.decode(LockupViewModel.self, forKey: key))
        case .video: return .video(try container.decode(VideoRenderer.self, forKey: key))
        case .shortsLockup: return .shortsLockup(try container.decode(ShortsLockupViewModel.self, forKey: key))
        case .channel: return .channel(try container.decode(ChannelRenderer.self, forKey: key))
        case .playlist: return .playlist(try container.decode(PlaylistRenderer.self, forKey: key), isMix: false)
        case .mix: return .playlist(try container.decode(PlaylistRenderer.self, forKey: key), isMix: true)
        }
    }
}
