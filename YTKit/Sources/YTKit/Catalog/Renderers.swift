import Foundation

// Modelos de los "renderers" de Innertube (equivalentes a `common/models/gen/CommonItems.kt`, `browse/v2/gen`,
// `search/v2/gen` y `next/v2/gen` de SmartTube). Todos los campos son opcionales y tolerantes (`@Lenient`).
// Solo se declaran los campos que se usan; JSONDecoder ignora el resto.

// MARK: - Texto, imágenes y comandos

/// Texto de YouTube en cualquiera de sus formas: cadena, `{"simpleText"}`, `{"runs": [{"text"}]}` (renderers clásicos)
/// o `{"content"}` (view models nuevos).
struct YTText: Decodable, Sendable {
    struct Run: Decodable, Sendable {
        @Lenient var text: String?
        @Lenient var navigationEndpoint: NavigationEndpoint?
    }

    /// `commandRuns` de los view models: tramos del texto con un comando (el nombre del canal enlaza a su página).
    struct CommandRun: Decodable, Sendable {
        @Lenient var onTap: Command?
    }

    var simpleText: String?
    var runs: [Run]?
    var content: String?
    var commandRuns: [CommandRun]?
    var accessibilityLabel: String?

    private enum CodingKeys: String, CodingKey { case simpleText, runs, content, commandRuns, accessibility, accessibilityData }
    private struct Accessibility: Decodable { @Lenient var accessibilityData: AccessibilityData? }
    private struct AccessibilityData: Decodable { @Lenient var label: String? }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let string = try? single.decode(String.self) {
            content = string
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        simpleText = try? c.decodeIfPresent(String.self, forKey: .simpleText)
        runs = try? c.decodeIfPresent([Run].self, forKey: .runs)
        content = try? c.decodeIfPresent(String.self, forKey: .content)
        commandRuns = try? c.decodeIfPresent([CommandRun].self, forKey: .commandRuns)
        let accessibility = try? c.decodeIfPresent(Accessibility.self, forKey: .accessibility)
        accessibilityLabel = accessibility?.accessibilityData?.label
    }

    var string: String? {
        let value = simpleText ?? content ?? runs.map { $0.compactMap(\.text).joined() }
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Primer canal enlazado en el texto (runs con `browseEndpoint` UC… o `commandRuns`).
    var channelId: String? {
        for run in runs ?? [] {
            if let id = run.navigationEndpoint?.browseEndpoint?.browseId, id.hasPrefix("UC") { return id }
        }
        for run in commandRuns ?? [] {
            if let id = run.onTap?.innertubeCommand?.browseEndpoint?.browseId, id.hasPrefix("UC") { return id }
        }
        return nil
    }
}

struct ThumbnailItem: Decodable, Sendable {
    @Lenient var url: String?
    @Lenient var width: FlexibleInt?
    @Lenient var height: FlexibleInt?
}

/// `{"thumbnails": [...]}` (renderers clásicos) o `{"sources": [...]}` (view models).
struct ThumbnailList: Decodable, Sendable {
    @Lenient var thumbnails: [ThumbnailItem]?
    @Lenient var sources: [ThumbnailItem]?

    var all: [ThumbnailItem] { (thumbnails ?? []) + (sources ?? []) }
}

struct WatchEndpoint: Decodable, Sendable {
    @Lenient var videoId: String?
    @Lenient var playlistId: String?
    @Lenient var index: FlexibleInt?
    @Lenient var params: String?
    @Lenient var playerParams: String?
    @Lenient var startTimeSeconds: FlexibleInt?
}

struct BrowseEndpoint: Decodable, Sendable {
    @Lenient var browseId: String?
    @Lenient var params: String?
    @Lenient var canonicalBaseUrl: String?
}

struct ReelWatchEndpoint: Decodable, Sendable {
    @Lenient var videoId: String?
    @Lenient var params: String?
    @Lenient var thumbnail: ThumbnailList?
}

struct ContinuationCommand: Decodable, Sendable {
    @Lenient var token: String?
    @Lenient var request: String?
}

struct CommandExecutor: Decodable, Sendable {
    @Lenient var commands: [NavigationEndpoint]?
}

/// `navigationEndpoint`, `onSelectCommand`, `innertubeCommand`, `continuationEndpoint`…: el destino de un toque.
struct NavigationEndpoint: Decodable, Sendable {
    @Lenient var watchEndpoint: WatchEndpoint?
    @Lenient var watchPlaylistEndpoint: WatchEndpoint?
    @Lenient var browseEndpoint: BrowseEndpoint?
    @Lenient var reelWatchEndpoint: ReelWatchEndpoint?
    @Lenient var continuationCommand: ContinuationCommand?
    @Lenient var commandExecutorCommand: CommandExecutor?
    @Lenient var innertubeCommand: Box<NavigationEndpoint>?

    /// El comando en sí o, si es un `commandExecutorCommand`, el primero de sus comandos que lo tenga.
    func first<T>(_ path: (NavigationEndpoint) -> T?) -> T? {
        if let value = path(self) { return value }
        if let inner = innertubeCommand?.value, let value = inner.first(path) { return value }
        for command in commandExecutorCommand?.commands ?? [] {
            if let value = command.first(path) { return value }
        }
        return nil
    }

    var continuationToken: String? { first { $0.continuationCommand?.token } }
}

/// `{"innertubeCommand": {...}}` (view models).
struct Command: Decodable, Sendable {
    @Lenient var innertubeCommand: NavigationEndpoint?
}

/// `rendererContext.commandContext.onTap` de los view models.
struct RendererContext: Decodable, Sendable {
    struct CommandContext: Decodable, Sendable {
        @Lenient var onTap: Command?
    }
    @Lenient var commandContext: CommandContext?
    var onTap: NavigationEndpoint? { commandContext?.onTap?.innertubeCommand }
}

/// `{"nextContinuationData": {...}}` / `{"reloadContinuationData": {...}}` de los contenedores de TV.
struct ContinuationData: Decodable, Sendable {
    struct Data: Decodable, Sendable { @Lenient var continuation: String? }
    @Lenient var nextContinuationData: Data?
    @Lenient var reloadContinuationData: Data?
    var token: String? { nextContinuationData?.continuation ?? reloadContinuationData?.continuation }
}

struct MetadataBadge: Decodable, Sendable {
    struct Icon: Decodable, Sendable { @Lenient var iconType: String? }
    @Lenient var label: String?
    @Lenient var style: String?
    @Lenient var icon: Icon?
}

struct BadgeWrapper: Decodable, Sendable {
    @Lenient var metadataBadgeRenderer: MetadataBadge?
}

/// Superposiciones sobre la miniatura (duración, "EN DIRECTO", progreso visto) de `tileRenderer` y `videoRenderer`.
struct ThumbnailOverlay: Decodable, Sendable {
    struct TimeStatus: Decodable, Sendable {
        @Lenient var text: YTText?
        @Lenient var style: String?
    }
    struct Resume: Decodable, Sendable { @Lenient var percentDurationWatched: FlexibleInt? }
    @Lenient var thumbnailOverlayTimeStatusRenderer: TimeStatus?
    @Lenient var thumbnailOverlayResumePlaybackRenderer: Resume?
    @Lenient var tileMetadataRenderer: TileRenderer.Metadata?
}

struct MenuWrapper: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        struct Navigation: Decodable, Sendable {
            @Lenient var navigationEndpoint: NavigationEndpoint?
            @Lenient var serviceEndpoint: ServiceEndpoint?
        }
        @Lenient var menuNavigationItemRenderer: Navigation?
        @Lenient var menuServiceItemRenderer: Navigation?
    }
    struct ServiceEndpoint: Decodable, Sendable {
        struct Feedback: Decodable, Sendable { @Lenient var feedbackToken: String? }
        @Lenient var feedbackEndpoint: Feedback?
    }
    struct Renderer: Decodable, Sendable { @Lenient var items: [Item]? }
    @Lenient var menuRenderer: Renderer?

    /// Canal enlazado desde el menú ("Ir al canal"), como hace SmartTube con los tiles de TV.
    var channelId: String? {
        for item in menuRenderer?.items ?? [] {
            let endpoint = item.menuNavigationItemRenderer?.navigationEndpoint ?? item.menuServiceItemRenderer?.navigationEndpoint
            if let id = endpoint?.browseEndpoint?.browseId, id.hasPrefix("UC") { return id }
        }
        return nil
    }

    /// Primer token de `feedbackEndpoint` del menú ("No me interesa", "Ocultar", "Quitar del historial"), como
    /// `MenuWrapper.getFeedbackTokens()?.first` de SmartTube.
    var feedbackToken: String? {
        menuRenderer?.items?.lazy.compactMap { $0.menuServiceItemRenderer?.serviceEndpoint?.feedbackEndpoint?.feedbackToken }.first
    }
}

/// `decoratedAvatarViewModel` (avatar del canal en lockups, cabeceras y resultados nuevos).
struct DecoratedAvatar: Decodable, Sendable {
    struct Avatar: Decodable, Sendable {
        struct ViewModel: Decodable, Sendable { @Lenient var image: ThumbnailList? }
        @Lenient var avatarViewModel: ViewModel?
    }
    struct Wrapper: Decodable, Sendable { @Lenient var decoratedAvatarViewModel: DecoratedAvatar? }
    @Lenient var avatar: Avatar?
    @Lenient var rendererContext: RendererContext?
}

// MARK: - Renderers de elementos (videos, canales, listas)

/// `tileRenderer`: la tarjeta de la interfaz de TV (TVHTML5).
struct TileRenderer: Decodable, Sendable {
    struct Header: Decodable, Sendable {
        struct Renderer: Decodable, Sendable {
            @Lenient var thumbnail: ThumbnailList?
            @Lenient var thumbnailOverlays: [ThumbnailOverlay]?
        }
        @Lenient var tileHeaderRenderer: Renderer?
    }
    struct Metadata: Decodable, Sendable {
        @Lenient var title: YTText?
        @Lenient var lines: [Line]?
    }
    struct Line: Decodable, Sendable {
        struct Renderer: Decodable, Sendable { @Lenient var items: [Item]? }
        struct Item: Decodable, Sendable {
            struct LineItem: Decodable, Sendable {
                @Lenient var text: YTText?
                @Lenient var badge: BadgeWrapper?
            }
            @Lenient var lineItemRenderer: LineItem?
        }
        @Lenient var lineRenderer: Renderer?
    }
    struct MetadataWrapper: Decodable, Sendable { @Lenient var tileMetadataRenderer: Metadata? }
    struct LongPress: Decodable, Sendable {
        struct ShowMenu: Decodable, Sendable {
            @Lenient var menu: MenuWrapper?
            @Lenient var subtitle: YTText?
        }
        /// Inicio de TV con cuenta: el menú se pide aparte con `get_panel` (`identifier.tag` + `params`).
        struct ShowPanel: Decodable, Sendable {
            struct Identifier: Decodable, Sendable { @Lenient var tag: String? }
            struct Configuration: Decodable, Sendable { @Lenient var params: String? }
            @Lenient var identifier: Identifier?
            @Lenient var globalConfiguration: Configuration?
        }
        @Lenient var showMenuCommand: ShowMenu?
        @Lenient var showEngagementPanelEndpoint: ShowPanel?
    }

    @Lenient var contentId: String?
    @Lenient var contentType: String?
    @Lenient var style: String?
    @Lenient var header: Header?
    @Lenient var metadata: MetadataWrapper?
    @Lenient var onSelectCommand: NavigationEndpoint?
    @Lenient var onFocusCommand: FocusCommand?
    @Lenient var onLongPressCommand: LongPress?
    @Lenient var menu: MenuWrapper?

    /// Tiles del carrusel de TV: no traen `metadata`; el título y las líneas van en el comando de foco.
    struct FocusCommand: Decodable, Sendable {
        struct Executor: Decodable, Sendable { @Lenient var commands: [Step]? }
        struct Step: Decodable, Sendable {
            struct Update: Decodable, Sendable {
                struct Spotlight: Decodable, Sendable { @Lenient var entityMetadataRenderer: Entity? }
                @Lenient var spotlight: Spotlight?
            }
            @Lenient var updateCarouselHeaderCommand: Update?
        }
        struct Entity: Decodable, Sendable {
            @Lenient var title: YTText?
            @Lenient var bylines: [Line]?
        }
        @Lenient var commandExecutorCommand: Executor?

        var spotlight: Entity? {
            commandExecutorCommand?.commands?.lazy.compactMap { $0.updateCarouselHeaderCommand?.spotlight?.entityMetadataRenderer }.first
        }
    }
}

/// `lockupViewModel`: la tarjeta nueva de YouTube (búsqueda en TV, canal y sugeridos en WEB).
struct LockupViewModel: Decodable, Sendable {
    struct ThumbnailViewModel: Decodable, Sendable {
        @Lenient var image: ThumbnailList?
        @Lenient var overlays: [Overlay]?
    }
    struct Overlay: Decodable, Sendable {
        struct BadgeList: Decodable, Sendable {
            @Lenient var thumbnailBadges: [ThumbnailBadge]?
            @Lenient var badges: [ThumbnailBadge]?
            @Lenient var progressBar: ProgressBar?
        }
        struct ProgressBar: Decodable, Sendable {
            struct ViewModel: Decodable, Sendable { @Lenient var startPercent: FlexibleInt? }
            @Lenient var thumbnailOverlayProgressBarViewModel: ViewModel?
        }
        @Lenient var thumbnailOverlayBadgeViewModel: BadgeList?
        @Lenient var thumbnailBottomOverlayViewModel: BadgeList?
    }
    struct ThumbnailBadge: Decodable, Sendable {
        struct ViewModel: Decodable, Sendable {
            @Lenient var text: String?
            @Lenient var badgeStyle: String?
        }
        @Lenient var thumbnailBadgeViewModel: ViewModel?
    }
    struct ContentImage: Decodable, Sendable {
        struct Collection: Decodable, Sendable {
            struct Primary: Decodable, Sendable { @Lenient var thumbnailViewModel: ThumbnailViewModel? }
            @Lenient var primaryThumbnail: Primary?
        }
        @Lenient var thumbnailViewModel: ThumbnailViewModel?
        @Lenient var collectionThumbnailViewModel: Collection?
        var thumbnail: ThumbnailViewModel? { thumbnailViewModel ?? collectionThumbnailViewModel?.primaryThumbnail?.thumbnailViewModel }
    }
    struct Metadata: Decodable, Sendable {
        struct LockupMetadata: Decodable, Sendable {
            struct Nested: Decodable, Sendable { @Lenient var contentMetadataViewModel: ContentMetadata? }
            @Lenient var title: YTText?
            @Lenient var metadata: Nested?
            @Lenient var image: DecoratedAvatar.Wrapper?
        }
        @Lenient var lockupMetadataViewModel: LockupMetadata?
    }

    @Lenient var contentId: String?
    @Lenient var contentType: String?
    @Lenient var contentImage: ContentImage?
    @Lenient var metadata: Metadata?
    @Lenient var rendererContext: RendererContext?
}

/// `contentMetadataViewModel`: filas de metadatos ("Lofi Girl" / "15 M de visualizaciones • hace 1 mes").
struct ContentMetadata: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        struct Part: Decodable, Sendable { @Lenient var text: YTText? }
        @Lenient var metadataParts: [Part]?
    }
    @Lenient var metadataRows: [Row]?
    @Lenient var delimiter: String?

    var rows: [[YTText]] { (metadataRows ?? []).map { ($0.metadataParts ?? []).compactMap(\.text) } }
}

/// `videoRenderer`, `gridVideoRenderer`, `compactVideoRenderer`, `playlistVideoRenderer`, `reelItemRenderer`…:
/// los renderers de video de la interfaz WEB (comparten casi todos los campos).
struct VideoRenderer: Decodable, Sendable {
    struct Snippet: Decodable, Sendable { @Lenient var snippetText: YTText? }
    struct ChannelThumbnail: Decodable, Sendable {
        struct WithLink: Decodable, Sendable {
            @Lenient var thumbnail: ThumbnailList?
            @Lenient var navigationEndpoint: NavigationEndpoint?
        }
        @Lenient var channelThumbnailWithLinkRenderer: WithLink?
    }
    struct UpcomingEvent: Decodable, Sendable { @Lenient var startTime: FlexibleInt? }

    @Lenient var videoId: String?
    @Lenient var title: YTText?
    @Lenient var headline: YTText?
    @Lenient var thumbnail: ThumbnailList?
    @Lenient var longBylineText: YTText?
    @Lenient var shortBylineText: YTText?
    @Lenient var ownerText: YTText?
    @Lenient var viewCountText: YTText?
    @Lenient var shortViewCountText: YTText?
    @Lenient var publishedTimeText: YTText?
    @Lenient var lengthText: YTText?
    @Lenient var lengthSeconds: FlexibleInt?
    @Lenient var videoInfo: YTText?
    @Lenient var index: YTText?
    @Lenient var badges: [BadgeWrapper]?
    @Lenient var thumbnailOverlays: [ThumbnailOverlay]?
    @Lenient var upcomingEventData: UpcomingEvent?
    @Lenient var detailedMetadataSnippets: [Snippet]?
    @Lenient var descriptionSnippet: YTText?
    @Lenient var channelThumbnailSupportedRenderers: ChannelThumbnail?
    @Lenient var channelThumbnail: ThumbnailList?
    @Lenient var avatar: DecoratedAvatar.Wrapper?
    @Lenient var navigationEndpoint: NavigationEndpoint?
    @Lenient var menu: MenuWrapper?
}

/// `shortsLockupViewModel`: Shorts en la interfaz WEB (pestaña Shorts, estantes de búsqueda).
struct ShortsLockupViewModel: Decodable, Sendable {
    struct OverlayMetadata: Decodable, Sendable {
        @Lenient var primaryText: YTText?
        @Lenient var secondaryText: YTText?
    }
    @Lenient var entityId: String?
    @Lenient var accessibilityText: String?
    @Lenient var thumbnail: ThumbnailList?
    @Lenient var onTap: Command?
    @Lenient var overlayMetadata: OverlayMetadata?
}

/// `channelRenderer`, `gridChannelRenderer`, `compactChannelRenderer`.
struct ChannelRenderer: Decodable, Sendable {
    @Lenient var channelId: String?
    @Lenient var title: YTText?
    @Lenient var displayName: YTText?
    @Lenient var thumbnail: ThumbnailList?
    @Lenient var subscriberCountText: YTText?
    @Lenient var videoCountText: YTText?
    @Lenient var descriptionSnippet: YTText?
    @Lenient var navigationEndpoint: NavigationEndpoint?
}

/// `playlistRenderer`, `gridPlaylistRenderer`, `compactPlaylistRenderer`, `radioRenderer` (mix)…
struct PlaylistRenderer: Decodable, Sendable {
    struct ThumbnailRenderer: Decodable, Sendable {
        struct Inner: Decodable, Sendable { @Lenient var thumbnail: ThumbnailList? }
        @Lenient var playlistVideoThumbnailRenderer: Inner?
        @Lenient var playlistCustomThumbnailRenderer: Inner?
    }
    @Lenient var playlistId: String?
    @Lenient var title: YTText?
    @Lenient var thumbnail: ThumbnailList?
    @Lenient var thumbnails: [ThumbnailList]?
    @Lenient var thumbnailRenderer: ThumbnailRenderer?
    @Lenient var videoCount: FlexibleInt?
    @Lenient var videoCountText: YTText?
    @Lenient var videoCountShortText: YTText?
    @Lenient var longBylineText: YTText?
    @Lenient var shortBylineText: YTText?
    @Lenient var navigationEndpoint: NavigationEndpoint?
}

/// `continuationItemRenderer` (y su sucesor `continuationItemViewModel`, que ya usa la página de una lista):
/// marca del final de una lista paginada en WEB.
struct ContinuationItemRenderer: Decodable, Sendable {
    struct Button: Decodable, Sendable {
        struct Renderer: Decodable, Sendable { @Lenient var command: NavigationEndpoint? }
        @Lenient var buttonRenderer: Renderer?
    }
    @Lenient var continuationEndpoint: NavigationEndpoint?
    @Lenient var continuationCommand: Command?
    @Lenient var button: Button?

    var token: String? {
        continuationEndpoint?.continuationToken ?? continuationCommand?.innertubeCommand?.continuationToken
            ?? button?.buttonRenderer?.command?.continuationToken
    }
}
