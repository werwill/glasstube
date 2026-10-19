import Foundation

// `/youtubei/v1/next`: metadatos, descripción, capítulos, mapa de calor, sugeridos y siguiente video. Port de la parte
// sin cuenta de `next/v2` de SmartTube (`WatchNextResult.kt`, `WatchNextHelper.kt`, `MediaItemMetadataImpl.kt`).
//
// TV (`singleColumnWatchNextResults`): metadatos en `videoMetadataRenderer`, sugeridos en `pivot` (varias filas) y
// capítulos en `frameworkUpdates` (`macroMarkersListEntity`). WEB (`twoColumnWatchNextResults`): metadatos en
// `videoPrimaryInfoRenderer` + `videoSecondaryInfoRenderer`, sugeridos en `secondaryResults` (una lista paginada) y
// capítulos en `playerOverlays` y en el panel de capítulos. En los dos, la descripción completa y los "Me gusta" van en
// el panel de descripción estructurada.

struct WatchNextResponse: Decodable, Sendable {
    struct NodeList: Decodable, Sendable { @Lenient var contents: [PrimaryItem]? }
    struct ResultsWrapper: Decodable, Sendable { @Lenient var results: NodeList? }
    struct SecondaryList: Decodable, Sendable { @Lenient var results: [Node]? }
    struct SecondaryWrapper: Decodable, Sendable { @Lenient var secondaryResults: SecondaryList? }
    struct AutoplayWrapper: Decodable, Sendable {
        struct Autoplay: Decodable, Sendable { @Lenient var sets: [AutoplaySet]? }
        @Lenient var autoplay: Autoplay?
    }
    struct AutoplaySet: Decodable, Sendable {
        struct Autonav: Decodable, Sendable {
            struct Renderer: Decodable, Sendable { @Lenient var endpoint: NavigationEndpoint? }
            @Lenient var autonavEndpointRenderer: Renderer?
        }
        struct NextVideo: Decodable, Sendable {
            struct Renderer: Decodable, Sendable { @Lenient var endpoint: NavigationEndpoint? }
            @Lenient var maybeHistoryEndpointRenderer: Renderer?
        }
        @Lenient var autoplayVideo: NavigationEndpoint?
        @Lenient var autoplayVideoRenderer: Autonav?
        @Lenient var nextVideoRenderer: NextVideo?

        var videoId: String? {
            autoplayVideo?.watchEndpoint?.videoId
                ?? autoplayVideoRenderer?.autonavEndpointRenderer?.endpoint?.watchEndpoint?.videoId
                ?? nextVideoRenderer?.maybeHistoryEndpointRenderer?.endpoint?.watchEndpoint?.videoId
        }
    }
    /// `conversationBar.liveChatRenderer`: el chat de un directo (`WatchNextHelper.getLiveChatToken` de SmartTube).
    struct ConversationBar: Decodable, Sendable {
        struct LiveChat: Decodable, Sendable {
            @Lenient var continuations: [ContinuationData]?
            @Lenient var isReplay: Bool?
        }
        @Lenient var liveChatRenderer: LiveChat?
    }
    struct TwoColumn: Decodable, Sendable {
        @Lenient var results: ResultsWrapper?
        @Lenient var secondaryResults: SecondaryWrapper?
        @Lenient var autoplay: AutoplayWrapper?
        @Lenient var conversationBar: ConversationBar?
    }
    struct SingleColumn: Decodable, Sendable {
        @Lenient var results: ResultsWrapper?
        @Lenient var pivot: Node?
        @Lenient var autoplay: AutoplayWrapper?
        @Lenient var conversationBar: ConversationBar?
    }
    struct Contents: Decodable, Sendable {
        @Lenient var twoColumnWatchNextResults: TwoColumn?
        @Lenient var singleColumnWatchNextResults: SingleColumn?
    }

    @Lenient var contents: Contents?
    @Lenient var playerOverlays: PlayerOverlays?
    @Lenient var engagementPanels: [EngagementPanel]?
    @Lenient var frameworkUpdates: FrameworkUpdates?
}

/// Elementos de `results.results.contents`.
struct PrimaryItem: Decodable, Sendable {
    struct ItemSection: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            @Lenient var videoMetadataRenderer: VideoMetadata?
            @Lenient var continuationItemRenderer: ContinuationItemRenderer?
        }
        @Lenient var contents: [Entry]?
        @Lenient var sectionIdentifier: String?
    }
    @Lenient var videoPrimaryInfoRenderer: VideoMetadata?
    @Lenient var videoSecondaryInfoRenderer: VideoSecondaryInfo?
    @Lenient var itemSectionRenderer: ItemSection?
}

/// `videoPrimaryInfoRenderer` (WEB) y `videoMetadataRenderer` (TV) comparten estos campos.
struct VideoMetadata: Decodable, Sendable {
    struct ViewCount: Decodable, Sendable {
        struct Renderer: Decodable, Sendable {
            @Lenient var viewCount: YTText?
            @Lenient var shortViewCount: YTText?
            @Lenient var isLive: Bool?
        }
        @Lenient var videoViewCountRenderer: Renderer?
    }
    @Lenient var title: YTText?
    @Lenient var viewCount: ViewCount?
    @Lenient var dateText: YTText?
    @Lenient var relativeDateText: YTText?
    @Lenient var publishedTimeText: YTText?
    @Lenient var badges: [BadgeWrapper]?
    @Lenient var owner: VideoOwner.Wrapper?
    @Lenient var description: YTText?
}

struct VideoSecondaryInfo: Decodable, Sendable {
    @Lenient var owner: VideoOwner.Wrapper?
    @Lenient var attributedDescription: YTText?
    @Lenient var description: YTText?
}

struct VideoOwner: Decodable, Sendable {
    struct Wrapper: Decodable, Sendable { @Lenient var videoOwnerRenderer: VideoOwner? }
    @Lenient var title: YTText?
    @Lenient var thumbnail: ThumbnailList?
    @Lenient var navigationEndpoint: NavigationEndpoint?
    @Lenient var subscriberCountText: YTText?
}

struct PlayerOverlays: Decodable, Sendable {
    struct Overlay: Decodable, Sendable {
        struct Decorated: Decodable, Sendable {
            struct Inner: Decodable, Sendable {
                struct PlayerBar: Decodable, Sendable {
                    struct MultiMarkers: Decodable, Sendable {
                        struct Entry: Decodable, Sendable {
                            struct Value: Decodable, Sendable { @Lenient var chapters: [ChapterWrapper]? }
                            @Lenient var key: String?
                            @Lenient var value: Value?
                        }
                        @Lenient var markersMap: [Entry]?
                    }
                    @Lenient var multiMarkersPlayerBarRenderer: MultiMarkers?
                }
                @Lenient var playerBar: PlayerBar?
            }
            @Lenient var decoratedPlayerBarRenderer: Inner?
        }
        @Lenient var decoratedPlayerBarRenderer: Decorated?
    }
    struct ChapterWrapper: Decodable, Sendable {
        struct Renderer: Decodable, Sendable {
            @Lenient var title: YTText?
            @Lenient var timeRangeStartMillis: FlexibleInt?
            @Lenient var thumbnail: ThumbnailList?
        }
        @Lenient var chapterRenderer: Renderer?
    }
    @Lenient var playerOverlayRenderer: Overlay?

    var chapterRenderers: [ChapterWrapper.Renderer] {
        let map = playerOverlayRenderer?.decoratedPlayerBarRenderer?.decoratedPlayerBarRenderer?.playerBar?
            .multiMarkersPlayerBarRenderer?.markersMap ?? []
        return map.flatMap { $0.value?.chapters ?? [] }.compactMap(\.chapterRenderer)
    }
}

struct EngagementPanel: Decodable, Sendable {
    struct Renderer: Decodable, Sendable {
        struct Header: Decodable, Sendable {
            struct Title: Decodable, Sendable {
                struct Menu: Decodable, Sendable {
                    struct SortFilter: Decodable, Sendable {
                        /// TV: `continuation.reloadContinuationData`; WEB: `serviceEndpoint.continuationCommand`.
                        struct Item: Decodable, Sendable {
                            @Lenient var title: String?
                            @Lenient var selected: Bool?
                            @Lenient var continuation: ContinuationData?
                            @Lenient var serviceEndpoint: NavigationEndpoint?
                            var token: String? { continuation?.token ?? serviceEndpoint?.continuationToken }
                        }
                        @Lenient var subMenuItems: [Item]?
                    }
                    @Lenient var sortFilterSubMenuRenderer: SortFilter?
                }
                @Lenient var menu: Menu?
                /// "5.2 K" (número de comentarios).
                @Lenient var contextualInfo: YTText?
            }
            @Lenient var engagementPanelTitleHeaderRenderer: Title?
        }
        struct Content: Decodable, Sendable {
            struct Structured: Decodable, Sendable { @Lenient var items: [DescriptionItem]? }
            struct MacroMarkers: Decodable, Sendable { @Lenient var contents: [MacroMarkerItem]? }
            @Lenient var structuredDescriptionContentRenderer: Structured?
            @Lenient var macroMarkersListRenderer: MacroMarkers?
            @Lenient var sectionListRenderer: Container?
        }
        @Lenient var panelIdentifier: String?
        @Lenient var header: Header?
        @Lenient var content: Content?
    }
    @Lenient var engagementPanelSectionListRenderer: Renderer?
}

struct DescriptionItem: Decodable, Sendable {
    struct Header: Decodable, Sendable {
        struct Factoid: Decodable, Sendable {
            struct Renderer: Decodable, Sendable {
                @Lenient var value: YTText?
                @Lenient var label: YTText?
            }
            @Lenient var factoidRenderer: Renderer?
        }
        @Lenient var title: YTText?
        @Lenient var channel: YTText?
        @Lenient var views: YTText?
        @Lenient var publishDate: YTText?
        @Lenient var factoid: [Factoid]?
    }
    struct Body: Decodable, Sendable {
        @Lenient var attributedDescriptionBodyText: YTText?
        @Lenient var descriptionBodyText: YTText?
    }
    @Lenient var videoDescriptionHeaderRenderer: Header?
    @Lenient var expandableVideoDescriptionBodyRenderer: Body?
}

struct MacroMarkerItem: Decodable, Sendable {
    struct Renderer: Decodable, Sendable {
        @Lenient var title: YTText?
        @Lenient var timeDescription: YTText?
        @Lenient var thumbnail: ThumbnailList?
        @Lenient var onTap: NavigationEndpoint?
    }
    @Lenient var macroMarkersListItemRenderer: Renderer?
}

struct FrameworkUpdates: Decodable, Sendable {
    struct Batch: Decodable, Sendable { @Lenient var mutations: [Mutation]? }
    struct Mutation: Decodable, Sendable {
        struct Payload: Decodable, Sendable { @Lenient var macroMarkersListEntity: MarkersEntity? }
        @Lenient var payload: Payload?
    }
    struct MarkersEntity: Decodable, Sendable {
        struct List: Decodable, Sendable {
            @Lenient var markerType: String?
            @Lenient var markers: [Marker]?
        }
        @Lenient var markersList: List?
    }
    struct Marker: Decodable, Sendable {
        @Lenient var title: YTText?
        @Lenient var startMillis: FlexibleInt?
        @Lenient var durationMillis: FlexibleInt?
        @Lenient var thumbnailDetails: ThumbnailList?
        @Lenient var intensityScoreNormalized: Double?
    }
    @Lenient var entityBatchUpdate: Batch?

    func markers(_ type: String) -> [Marker] {
        (entityBatchUpdate?.mutations ?? []).compactMap(\.payload?.macroMarkersListEntity?.markersList)
            .filter { $0.markerType == type }.flatMap { $0.markers ?? [] }
    }
}

enum WatchNextParser {
    static func metadata(videoId: String, response r: WatchNextResponse, surface: Surface) -> MediaItemMetadata {
        var meta = MediaItemMetadata(videoId: videoId, surface: surface)
        let two = r.contents?.twoColumnWatchNextResults
        let single = r.contents?.singleColumnWatchNextResults
        let primaryItems = (two?.results ?? single?.results)?.results?.contents ?? []

        // Metadatos: videoPrimaryInfoRenderer (WEB) o videoMetadataRenderer dentro de un itemSectionRenderer (TV).
        let primary = primaryItems.lazy.compactMap(\.videoPrimaryInfoRenderer).first
            ?? primaryItems.lazy.compactMap { $0.itemSectionRenderer?.contents?.lazy.compactMap(\.videoMetadataRenderer).first }.first
        let secondary = primaryItems.lazy.compactMap(\.videoSecondaryInfoRenderer).first
        let owner = secondary?.owner?.videoOwnerRenderer ?? primary?.owner?.videoOwnerRenderer

        meta.title = primary?.title?.string
        let views = primary?.viewCount?.videoViewCountRenderer
        meta.viewCountText = views?.viewCount?.string ?? views?.shortViewCount?.string
        meta.shortViewCountText = views?.shortViewCount?.string
        meta.isLive = views?.isLive ?? false
        meta.publishedDate = primary?.dateText?.string ?? primary?.publishedTimeText?.string
        meta.relativeDate = primary?.relativeDateText?.string ?? primary?.dateText?.accessibilityLabel
        meta.badges = (primary?.badges ?? []).compactMap { $0.metadataBadgeRenderer?.label }
        meta.description = secondary?.attributedDescription?.string ?? secondary?.description?.string ?? primary?.description?.string
        meta.author = owner?.title?.string
        meta.channelId = owner?.navigationEndpoint?.browseEndpoint?.browseId
        meta.authorThumbnails = Convert.thumbnails(owner?.thumbnail)
        meta.subscriberCountText = owner?.subscriberCountText?.string

        // Panel de descripción estructurada: descripción completa, fecha exacta y "Me gusta".
        for panel in r.engagementPanels ?? [] {
            for item in panel.engagementPanelSectionListRenderer?.content?.structuredDescriptionContentRenderer?.items ?? [] {
                if let header = item.videoDescriptionHeaderRenderer {
                    meta.title = meta.title ?? header.title?.string
                    meta.author = meta.author ?? header.channel?.string
                    if let views = header.views?.string { meta.viewCountText = views }
                    // Fecha exacta ("11 jul 2018"); en TV `dateText` viene abreviada ("hace 8 a").
                    if let date = header.publishDate?.string { meta.publishedDate = date }
                    // El primer dato ("1,1 M" / "Me gusta") son los "Me gusta" (SmartTube: `getLikeCount`).
                    meta.likeCountText = header.factoid?.first?.factoidRenderer?.value?.string
                }
                if let body = item.expandableVideoDescriptionBodyRenderer,
                   let text = body.attributedDescriptionBodyText?.string ?? body.descriptionBodyText?.string {
                    meta.description = text
                }
            }
        }

        meta.chapters = chapters(r)
        meta.heatMap = (r.frameworkUpdates?.markers("MARKER_TYPE_HEATMAP") ?? []).compactMap { marker in
            guard let start = marker.startMillis?.value, let duration = marker.durationMillis?.value else { return nil }
            return HeatMarker(startMs: start, durationMs: duration, intensity: marker.intensityScoreNormalized ?? 0)
        }

        // Sugeridos: secondaryResults (WEB, una lista con continuación) o pivot (TV, varias filas).
        let extractor = PageExtractor(surface: surface, api: .next, kind: .suggestions)
        let roots = (two?.secondaryResults?.secondaryResults?.results ?? []) + [single?.pivot].compactMap { $0 }
        let page = extractor.page(roots)
        meta.suggestions = page.groups
        meta.suggestionsContinuation = page.continuation
        meta.stats = page.stats

        let nextId = (two?.autoplay ?? single?.autoplay)?.autoplay?.sets?.lazy.compactMap(\.videoId).first
        meta.nextVideoId = nextId
        if let nextId { meta.nextVideo = page.groups.lazy.flatMap(\.items).first { $0.videoId == nextId } }

        meta.commentsContinuation = commentsToken(r, primaryItems: primaryItems)
        if let panel = commentsPanel(r) {
            meta.commentsCountText = panel.header?.engagementPanelTitleHeaderRenderer?.contextualInfo?.string
            meta.commentSorts = (panel.header?.engagementPanelTitleHeaderRenderer?.menu?.sortFilterSubMenuRenderer?.subMenuItems ?? [])
                .compactMap { item in
                    guard let title = item.title, let token = item.token else { return nil }
                    return CommentSort(title: title, token: token, isSelected: item.selected ?? false)
                }
        }
        let chat = (two?.conversationBar ?? single?.conversationBar)?.liveChatRenderer
        meta.liveChatContinuation = chat?.continuations?.lazy.compactMap(\.token).first
        meta.isLiveChatReplay = chat?.isReplay ?? false
        return meta
    }

    /// Panel de comentarios: `comment-item-section` en TV, `engagement-panel-comments-section` en WEB.
    static func commentsPanel(_ r: WatchNextResponse) -> EngagementPanel.Renderer? {
        (r.engagementPanels ?? []).lazy.compactMap(\.engagementPanelSectionListRenderer)
            .first { $0.panelIdentifier?.contains("comment") == true }
    }

    static func chapters(_ r: WatchNextResponse) -> [Chapter] {
        // TV y WEB nuevos: entidad `macroMarkersListEntity` con duración de cada capítulo.
        let markers = r.frameworkUpdates?.markers("MARKER_TYPE_CHAPTERS") ?? []
        if !markers.isEmpty {
            return markers.compactMap { marker in
                guard let title = marker.title?.string, let start = marker.startMillis?.value else { return nil }
                return Chapter(title: title, startMs: start, durationMs: marker.durationMillis?.value,
                               thumbnails: Convert.thumbnails(marker.thumbnailDetails))
            }
        }
        // WEB: barra del reproductor (`chapterRenderer`).
        let bar = r.playerOverlays?.chapterRenderers ?? []
        if !bar.isEmpty {
            var result = bar.compactMap { renderer -> Chapter? in
                guard let title = renderer.title?.string, let start = renderer.timeRangeStartMillis?.value else { return nil }
                return Chapter(title: title, startMs: start, durationMs: nil, thumbnails: Convert.thumbnails(renderer.thumbnail))
            }
            for index in result.indices.dropLast() {
                result[index].durationMs = result[index + 1].startMs - result[index].startMs
            }
            return result
        }
        // WEB: panel de capítulos (`macroMarkersListItemRenderer`).
        let items = (r.engagementPanels ?? []).flatMap { $0.engagementPanelSectionListRenderer?.content?.macroMarkersListRenderer?.contents ?? [] }
        return items.compactMap(\.macroMarkersListItemRenderer).compactMap { item in
            guard let title = item.title?.string else { return nil }
            let start = item.onTap?.watchEndpoint?.startTimeSeconds?.value ?? Convert.seconds(fromDuration: item.timeDescription?.string)
            guard let start else { return nil }
            return Chapter(title: title, startMs: start * 1000, durationMs: nil, thumbnails: Convert.thumbnails(item.thumbnail))
        }
    }

    static func commentsToken(_ r: WatchNextResponse, primaryItems: [PrimaryItem]) -> String? {
        for item in primaryItems where item.itemSectionRenderer?.sectionIdentifier == "comment-item-section" {
            if let token = item.itemSectionRenderer?.contents?.lazy.compactMap({ $0.continuationItemRenderer?.token }).first {
                return token
            }
        }
        for panel in r.engagementPanels ?? [] {
            guard let renderer = panel.engagementPanelSectionListRenderer,
                  renderer.panelIdentifier?.contains("comment") == true else { continue }
            if let token = renderer.header?.engagementPanelTitleHeaderRenderer?.menu?.sortFilterSubMenuRenderer?
                .subMenuItems?.first?.token {
                return token
            }
            if let section = renderer.content?.sectionListRenderer {
                let result = PageExtractor(surface: .web, api: .next, kind: .unknown).extract(section.children)
                if let token = result.looseToken { return token }
            }
        }
        return nil
    }
}
