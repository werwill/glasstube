import Foundation

// Modelos públicos del catálogo, independientes de la interfaz (TV o WEB) que los produjo. Equivalen a los de
// `mediaserviceinterfaces/data` de SmartTube (MediaItem, MediaGroup, MediaItemMetadata, ChapterItem).

/// Interfaz de YouTube con la que se habla: la de TV (TVHTML5, la que usa SmartTube) o la de escritorio (WEB).
public enum Surface: String, Codable, Sendable, CaseIterable {
    case tv, web
}

public struct Thumbnail: Codable, Sendable, Hashable {
    public var url: String
    public var width: Int?
    public var height: Int?

    public init(url: String, width: Int? = nil, height: Int? = nil) {
        self.url = url
        self.width = width
        self.height = height
    }
}

extension Array where Element == Thumbnail {
    /// La más pequeña que llegue a `width` puntos de ancho, o la más grande si ninguna llega.
    public func best(forWidth width: Int = 640) -> Thumbnail? {
        let sorted = self.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        return sorted.first { ($0.width ?? 0) >= width } ?? sorted.last
    }
}

/// Un video, Short, canal, lista o mix tal como aparece en una fila o cuadrícula (`MediaItem` de SmartTube).
public struct MediaItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case video, channel, playlist, mix
    }

    public var kind: Kind
    public var title: String
    public var videoId: String?
    public var channelId: String?
    public var playlistId: String?
    public var author: String?
    public var viewCountText: String?
    public var publishedText: String?
    public var durationText: String?
    public var durationSeconds: Int?
    public var descriptionSnippet: String?
    /// Canales: "521 M de suscriptores". Listas: número de videos.
    public var subscriberCountText: String?
    public var videoCountText: String?
    public var handle: String?
    public var badges: [String] = []
    public var isLive = false
    public var isUpcoming = false
    public var isShort = false
    public var upcomingStart: Date?
    public var percentWatched: Int?
    public var startTimeSeconds: Int?
    public var playlistIndex: Int?
    /// `params` del `watchEndpoint` o del `browseEndpoint` (se reenvían a `next` o al canal).
    public var params: String?
    public var thumbnails: [Thumbnail] = []
    public var authorThumbnails: [Thumbnail] = []
    /// Líneas de metadatos tal como las muestra YouTube ("Lofi Girl", "15 M de visualizaciones • hace 1 mes").
    public var metadataLines: [String] = []
    /// Con cuenta: token de "No me interesa" del menú de la tarjeta (`MediaItemService.markAsNotInterested`). En el
    /// historial es "Quitar del historial" y en Suscripciones "Ocultar" (el primero del menú, como SmartTube).
    public var feedbackToken: String?
    /// Inicio de TV con cuenta: el menú de la tarjeta llega aparte (`get_panel`); esto es lo que hay que pedir.
    public var menuPanel: MenuPanel?
    /// Renderer de origen (`tileRenderer`, `lockupViewModel`, `videoRenderer`…), para diagnóstico.
    public var renderer: String

    public var id: String {
        switch kind {
        case .video: return videoId ?? title
        case .playlist, .mix: return playlistId ?? videoId ?? title
        case .channel: return channelId ?? title
        }
    }

    /// Miniaturas estándar de `i.ytimg.com` para un video (WEB a veces trae solo 336 px). `maxresdefault` no existe en
    /// videos antiguos o de baja resolución: hay que caer a `sddefault`/`hqdefault` si responde 404.
    public var standardThumbnails: [Thumbnail] {
        guard kind == .video, let videoId else { return [] }
        return [("mqdefault", 320, 180), ("hqdefault", 480, 360), ("sddefault", 640, 480), ("maxresdefault", 1280, 720)].map {
            Thumbnail(url: "https://i.ytimg.com/vi/\(videoId)/\($0.0).jpg", width: $0.1, height: $0.2)
        }
    }

    /// Segunda línea para una tarjeta (el `getSecondTitle` de SmartTube).
    public var secondTitle: String {
        if !metadataLines.isEmpty { return metadataLines.joined(separator: " • ") }
        return [author, viewCountText, publishedText].compactMap { $0 }.joined(separator: " • ")
    }

    public init(kind: Kind, title: String, renderer: String) {
        self.kind = kind
        self.title = title
        self.renderer = renderer
    }
}

/// Panel del menú de una tarjeta de TV (`onLongPressCommand.showEngagementPanelEndpoint`).
public struct MenuPanel: Codable, Sendable, Hashable {
    public var panelId: String
    public var params: String
}

/// Token de paginación con lo necesario para pedir la página siguiente: el endpoint y la interfaz que lo emitieron
/// (un token de TV solo vale con el cliente de TV).
public struct Continuation: Codable, Sendable, Hashable {
    public enum API: String, Codable, Sendable { case browse, search, next }

    public var token: String
    public var api: API
    public var surface: Surface

    public init(token: String, api: API, surface: Surface) {
        self.token = token
        self.api = api
        self.surface = surface
    }
}

/// Destino de "ver todo" de una fila (`shelfRenderer.endpoint` en TV).
public struct BrowseTarget: Codable, Sendable, Hashable {
    public var browseId: String
    public var params: String?
}

/// Una fila o cuadrícula (`MediaGroup` de SmartTube).
public struct MediaGroup: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case home, trending, topic, search, channel, suggestions, subscriptions, history, library, unknown
    }

    public var kind: Kind
    public var title: String?
    public var items: [MediaItem]
    /// Más elementos de esta misma fila (`ContentService.continueGroup`).
    public var continuation: Continuation?
    public var moreEndpoint: BrowseTarget?
    /// Contenedor de origen (`shelfRenderer`, `richShelfRenderer`, `richGridRenderer`…).
    public var renderer: String

    public var id: String { "\(renderer):\(title ?? ""):\(items.first?.id ?? "")" }
    public var isShorts: Bool { !items.isEmpty && items.allSatisfy(\.isShort) }

    public init(kind: Kind, title: String?, items: [MediaItem], continuation: Continuation? = nil,
                moreEndpoint: BrowseTarget? = nil, renderer: String) {
        self.kind = kind
        self.title = title
        self.items = items
        self.continuation = continuation
        self.moreEndpoint = moreEndpoint
        self.renderer = renderer
    }
}

/// Renderers que el parser encontró y no convirtió: los ignorados a propósito y los que fallaron. Sirve para
/// detectar pronto un cambio de YouTube.
public struct ParseStats: Codable, Sendable, Hashable {
    public var ignored: [String: Int] = [:]
    public var failed: [String: Int] = [:]
    /// Elementos conocidos que no dieron un `MediaItem` (sin título ni id).
    public var dropped: [String: Int] = [:]

    public init() {}

    mutating func merge(_ other: ParseStats) {
        ignored.merge(other.ignored, uniquingKeysWith: +)
        failed.merge(other.failed, uniquingKeysWith: +)
        dropped.merge(other.dropped, uniquingKeysWith: +)
    }
}

/// Una página de filas (Inicio, un tema de Explorar, resultados de búsqueda, una pestaña de canal).
public struct BrowsePage: Codable, Sendable {
    public var title: String?
    public var groups: [MediaGroup]
    /// Más filas (`continuationContents.sectionListContinuation` en TV).
    public var continuation: Continuation?
    public var surface: Surface
    /// Aviso de YouTube en lugar de contenido (por ejemplo, el "Inicia sesión…" del Inicio anónimo).
    public var notice: String?
    /// La página pedida no trajo contenido y esta es un sustituto (Inicio armado con temas, Hype en lugar de
    /// Tendencias).
    public var isFallback = false
    public var stats = ParseStats()

    public var isEmpty: Bool { groups.allSatisfy { $0.items.isEmpty } }

    /// Junta las filas sin título que van seguidas en una sola, con `title` (Suscripciones de TV las manda de tres en
    /// tres). La continuación que queda es la de la última.
    public func mergingUntitledRows(title: String) -> BrowsePage {
        var copy = self
        var merged: [MediaGroup] = []
        for group in groups {
            if group.title == nil, let last = merged.last, last.title == title || last.title == nil, last.renderer == "merged" {
                merged[merged.count - 1].items += group.items
                merged[merged.count - 1].continuation = group.continuation ?? merged[merged.count - 1].continuation
            } else if group.title == nil {
                var first = group
                first.title = title
                first.renderer = "merged"
                merged.append(first)
            } else {
                merged.append(group)
            }
        }
        copy.groups = merged
        return copy
    }
    public var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    public init(title: String? = nil, groups: [MediaGroup], continuation: Continuation? = nil, surface: Surface,
                notice: String? = nil) {
        self.title = title
        self.groups = groups
        self.continuation = continuation
        self.surface = surface
        self.notice = notice
    }
}

/// Capítulo de un video (`ChapterItem` de SmartTube).
public struct Chapter: Codable, Sendable, Hashable {
    public var title: String
    public var startMs: Int
    public var durationMs: Int?
    public var thumbnails: [Thumbnail]
}

/// Tramo del mapa de calor ("lo más visto") de un video.
public struct HeatMarker: Codable, Sendable, Hashable {
    public var startMs: Int
    public var durationMs: Int
    public var intensity: Double
}

/// Metadatos de la página de reproducción (`/next`): `MediaItemMetadata` de SmartTube.
public struct MediaItemMetadata: Codable, Sendable {
    public var videoId: String
    public var title: String?
    public var description: String?
    public var author: String?
    public var channelId: String?
    public var authorThumbnails: [Thumbnail] = []
    public var subscriberCountText: String?
    /// "49.452.414 visualizaciones" (o el texto corto si no hay otro).
    public var viewCountText: String?
    public var shortViewCountText: String?
    public var likeCountText: String?
    /// Fecha de publicación ("11 jul 2018") y relativa ("hace 8 años").
    public var publishedDate: String?
    public var relativeDate: String?
    public var isLive = false
    public var badges: [String] = []
    public var chapters: [Chapter] = []
    public var heatMap: [HeatMarker] = []
    /// Sugeridos: una lista paginada en WEB; varias filas en TV.
    public var suggestions: [MediaGroup] = []
    /// Más filas de sugeridos (TV); en WEB la continuación va en la fila.
    public var suggestionsContinuation: Continuation?
    /// Siguiente video de la reproducción automática (y su tarjeta, si está entre los sugeridos).
    public var nextVideoId: String?
    public var nextVideo: MediaItem?
    /// Token para pedir los comentarios (`CommentsService.comments`; `/next` con continuation). Nil si están desactivados.
    public var commentsContinuation: String?
    /// "5.2 K" comentarios.
    public var commentsCountText: String?
    /// Órdenes de los comentarios ("Principales", "Más recientes") con su token.
    public var commentSorts: [CommentSort] = []
    /// Directos: token del chat en vivo (`LiveChatService`). En la repetición de un directo terminado, `isLiveChatReplay`.
    public var liveChatContinuation: String?
    public var isLiveChatReplay = false
    /// Con cuenta: el "me gusta" de la cuenta elegida y si está suscrita al canal (nil sin cuenta o si no vino).
    public var likeStatus: LikeStatus?
    public var isSubscribed: Bool?
    /// `params` del botón de suscribirse (se reenvía a `subscribe`).
    public var subscribeParams: String?
    public var surface: Surface
    public var stats = ParseStats()

    public init(videoId: String, surface: Surface) {
        self.videoId = videoId
        self.surface = surface
    }
}

/// Pestaña de un canal. `kind` sale del `params` de la pestaña (protobuf con el nombre interno: `videos`, `shorts`…),
/// no de su título, que depende del idioma.
public struct ChannelTab: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case home, videos, shorts, live, playlists, releases, podcasts, posts, store, courses, shows, search, unknown
    }

    public var kind: Kind
    public var title: String
    public var params: String?
    public var isSelected: Bool
}

/// Página de canal: cabecera, pestañas disponibles y el contenido de la pestaña elegida.
public struct ChannelPage: Codable, Sendable {
    public var channelId: String
    public var title: String?
    public var handle: String?
    public var description: String?
    public var subscriberCountText: String?
    public var videoCountText: String?
    public var avatar: [Thumbnail] = []
    public var banner: [Thumbnail] = []
    public var tabs: [ChannelTab] = []
    /// Pestaña que devolvió YouTube (si se pidió una que el canal no tiene, devuelve Inicio).
    public var selectedTab: ChannelTab.Kind?
    public var content: BrowsePage

    public init(channelId: String, content: BrowsePage) {
        self.channelId = channelId
        self.content = content
    }
}

/// Destinos de Explorar que funcionan sin cuenta.
public enum Topic: String, Codable, Sendable, CaseIterable {
    case music, gaming, news, sports, live, movies

    /// `FEtopics_*` de la interfaz de TV (SmartTube: `BrowseApiHelper`).
    var tvBrowseId: String { "FEtopics_\(rawValue)" }

    /// Canal de tema de la interfaz WEB ("Música", "Videojuegos"…). Películas no tiene canal equivalente.
    var webChannelId: String? {
        switch self {
        case .music: return "UC-9-kyTW8ZkZNDHQJ6FgpwQ"
        case .gaming: return "UCOpNcN46UbXVtpKMrmU4Abg"
        case .news: return "UCYfdidRxbB8Qhf0Nx7ioOYw"
        case .sports: return "UCEgdi0XIXXZ-qJOFPf4JSKw"
        case .live: return "UC4R8DWoMoI7CAwX8_LjQHig"
        case .movies: return nil
        }
    }
}

public enum YTKitError: Error, CustomStringConvertible, Sendable {
    case signInRequired(String)
    case notAvailable(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .signInRequired(let what): return "\(what) requiere iniciar sesión"
        case .notAvailable(let what): return "no disponible: \(what)"
        case .badResponse(let what): return "respuesta inesperada: \(what)"
        }
    }
}
