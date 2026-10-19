import Foundation

// Página de canal. WEB (`twoColumnBrowseResultsRenderer`) da cada pestaña por separado según `params` y la lista de
// pestañas que tiene el canal; TV (`tvSurfaceContentRenderer`) ignora `params` y devuelve siempre las mismas filas.
// Port de `BrowseService2.getChannel*` y `BrowseApiHelper` (constantes de `params`) de SmartTube.

struct ChannelResponse: Decodable, Sendable {
    struct Header: Decodable, Sendable {
        struct PageHeader: Decodable, Sendable {
            struct Content: Decodable, Sendable { @Lenient var pageHeaderViewModel: PageHeaderViewModel? }
            @Lenient var pageTitle: String?
            @Lenient var content: Content?
        }
        struct C4: Decodable, Sendable {
            @Lenient var title: String?
            @Lenient var avatar: ThumbnailList?
            @Lenient var banner: ThumbnailList?
            @Lenient var subscriberCountText: YTText?
            @Lenient var videosCountText: YTText?
            @Lenient var channelHandleText: YTText?
        }
        @Lenient var pageHeaderRenderer: PageHeader?
        @Lenient var c4TabbedHeaderRenderer: C4?
    }
    struct PageHeaderViewModel: Decodable, Sendable {
        struct Title: Decodable, Sendable {
            struct Dynamic: Decodable, Sendable { @Lenient var text: YTText? }
            @Lenient var dynamicTextViewModel: Dynamic?
        }
        struct Banner: Decodable, Sendable {
            struct ViewModel: Decodable, Sendable { @Lenient var image: ThumbnailList? }
            @Lenient var imageBannerViewModel: ViewModel?
        }
        struct Description: Decodable, Sendable {
            struct Preview: Decodable, Sendable { @Lenient var description: YTText? }
            @Lenient var descriptionPreviewViewModel: Preview?
        }
        struct Metadata: Decodable, Sendable { @Lenient var contentMetadataViewModel: ContentMetadata? }
        @Lenient var title: Title?
        @Lenient var image: DecoratedAvatar.Wrapper?
        @Lenient var banner: Banner?
        @Lenient var metadata: Metadata?
        @Lenient var description: Description?
    }
    struct Metadata: Decodable, Sendable {
        struct Renderer: Decodable, Sendable {
            @Lenient var title: String?
            @Lenient var description: String?
            @Lenient var externalId: String?
            @Lenient var avatar: ThumbnailList?
            @Lenient var vanityChannelUrl: String?
        }
        @Lenient var channelMetadataRenderer: Renderer?
    }
    /// `contents.tvBrowseRenderer.content.tvSurfaceContentRenderer.header.channelHeaderRenderer` (TV).
    struct TVContents: Decodable, Sendable {
        struct Browse: Decodable, Sendable {
            struct Content: Decodable, Sendable {
                struct Surface: Decodable, Sendable {
                    struct Header: Decodable, Sendable { @Lenient var channelHeaderRenderer: TVChannelHeader? }
                    @Lenient var header: Header?
                }
                @Lenient var tvSurfaceContentRenderer: Surface?
            }
            @Lenient var content: Content?
        }
        @Lenient var tvBrowseRenderer: Browse?
        var header: TVChannelHeader? { tvBrowseRenderer?.content?.tvSurfaceContentRenderer?.header?.channelHeaderRenderer }
    }
    struct TVChannelHeader: Decodable, Sendable {
        @Lenient var title: YTText?
        @Lenient var avatar: ThumbnailList?
        @Lenient var backgroundImage: ThumbnailList?
        @Lenient var subtitle: TileRenderer.Line?
    }

    @Lenient var header: Header?
    @Lenient var metadata: Metadata?
    @Lenient var tvContents: TVContents?

    private enum CodingKeys: String, CodingKey { case header, metadata, contents }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _header = try c.decode(Lenient<Header>.self, forKey: .header)
        _metadata = try c.decode(Lenient<Metadata>.self, forKey: .metadata)
        _tvContents = try c.decode(Lenient<TVContents>.self, forKey: .contents)
    }
}

extension ChannelTab.Kind {
    /// `params` de las pestañas según `BrowseApiHelper.kt` de SmartTube.
    public var defaultParams: String? {
        switch self {
        case .home: return "EghmZWF0dXJlZPIGBAoCMgA%3D"
        case .videos: return "EgZ2aWRlb3PyBgQKAjoA"
        case .shorts: return "EgZzaG9ydHPyBgUKA5oBAA%3D%3D"
        case .live: return "EgdzdHJlYW1z8gYECgJ6AA%3D%3D"
        case .playlists: return "EglwbGF5bGlzdHPyBgQKAkIA"
        case .releases: return "EghyZWxlYXNlc_IGBQoDsgEA"
        case .posts: return "Egljb21tdW5pdHnyBgQKAkoA"
        default: return nil
        }
    }

    /// El `params` de una pestaña es un protobuf cuyo campo 2 es el nombre interno ("videos", "streams"…).
    public init(params: String?) {
        guard let params, let data = Data(base64URL: params.removingPercentEncoding ?? params),
              let fields = try? ProtoFields(data), let name = fields.string(2) else {
            self = .unknown
            return
        }
        switch name {
        case "featured": self = .home
        case "videos": self = .videos
        case "shorts": self = .shorts
        case "streams": self = .live
        case "playlists": self = .playlists
        case "releases": self = .releases
        case "podcasts": self = .podcasts
        case "posts", "community": self = .posts
        case "store": self = .store
        case "courses": self = .courses
        case "shows": self = .shows
        case "search": self = .search
        default: self = .unknown
        }
    }
}

enum ChannelParser {
    static func page(channelId: String, data: Data, surface: Surface) throws -> ChannelPage {
        let browse = try JSONDecoder().decode(InnertubeResponse.self, from: data)
        let channel = try JSONDecoder().decode(ChannelResponse.self, from: data)

        // Pestañas (WEB): `tabRenderer` y `expandableTabRenderer` con título, `params` y la marca de seleccionada.
        var tabs: [ChannelTab] = []
        if let root = browse.contents?.container {
            for node in root.tabs ?? [] {
                guard let tab = node.container, let title = tab.title?.string else { continue }
                let params = tab.endpoint?.browseEndpoint?.params
                tabs.append(ChannelTab(kind: ChannelTab.Kind(params: params), title: title, params: params,
                                       isSelected: tab.selected ?? false))
            }
        }
        let selected = tabs.first(where: \.isSelected)

        let kind: MediaGroup.Kind = .channel
        var content = PageExtractor(surface: surface, api: .browse, kind: kind).page(browse.roots, looseTitle: selected?.title)
        // Los videos de la página del canal no repiten el canal en cada tarjeta.
        for g in content.groups.indices {
            for i in content.groups[g].items.indices where content.groups[g].items[i].kind == .video
                && content.groups[g].items[i].channelId == nil {
                content.groups[g].items[i].channelId = channelId
            }
        }

        var page = ChannelPage(channelId: channelId, content: content)
        page.tabs = tabs
        page.selectedTab = selected?.kind

        let meta = channel.metadata?.channelMetadataRenderer
        page.title = meta?.title
        page.description = meta?.description
        page.avatar = Convert.thumbnails(meta?.avatar)
        if let vanity = meta?.vanityChannelUrl, let at = vanity.range(of: "/@") {
            page.handle = String(vanity[vanity.index(after: at.lowerBound)...])
        }

        if let header = channel.header?.pageHeaderRenderer?.content?.pageHeaderViewModel {
            page.title = header.title?.dynamicTextViewModel?.text?.string ?? page.title
            let avatar = Convert.thumbnails(header.image?.decoratedAvatarViewModel?.avatar?.avatarViewModel?.image)
            if !avatar.isEmpty { page.avatar = avatar }
            page.banner = Convert.thumbnails(header.banner?.imageBannerViewModel?.image)
            page.description = page.description ?? header.description?.descriptionPreviewViewModel?.description?.string
            // Filas de metadatos: "@MrBeast" / "521 M de suscriptores • 1 K vídeos".
            let parts = (header.metadata?.contentMetadataViewModel?.rows ?? []).flatMap { $0 }.compactMap(\.string)
            if let handle = parts.first(where: { $0.hasPrefix("@") }) { page.handle = handle }
            let rest = parts.filter { !$0.hasPrefix("@") }
            page.subscriberCountText = rest.first
            page.videoCountText = rest.count > 1 ? rest[1] : nil
        } else if let c4 = channel.header?.c4TabbedHeaderRenderer {
            page.title = c4.title ?? page.title
            page.banner = Convert.thumbnails(c4.banner)
            page.subscriberCountText = c4.subscriberCountText?.string
            page.videoCountText = c4.videosCountText?.string
            page.handle = c4.channelHandleText?.string ?? page.handle
        } else if let tv = channel.tvContents?.header {
            page.title = tv.title?.string ?? page.title
            page.avatar = Convert.thumbnails(tv.avatar)
            page.banner = Convert.thumbnails(tv.backgroundImage)
            let parts = (tv.subtitle?.lineRenderer?.items ?? []).compactMap { $0.lineItemRenderer?.text?.string }
                .filter { $0.trimmingCharacters(in: .whitespaces) != "•" }
            page.handle = parts.first { $0.hasPrefix("@") }
            let rest = parts.filter { !$0.hasPrefix("@") }
            page.subscriberCountText = rest.first
            page.videoCountText = rest.count > 1 ? rest[1] : nil
        }
        return page
    }
}

/// Título de la página de una lista (`playlistMetadataRenderer` o `pageHeaderRenderer.pageTitle`).
struct PlaylistHeader: Decodable, Sendable {
    struct Metadata: Decodable, Sendable {
        struct Renderer: Decodable, Sendable { @Lenient var title: String? }
        @Lenient var playlistMetadataRenderer: Renderer?
    }
    /// TV: `contents.tvBrowseRenderer.content.tvSurfaceContentRenderer.content.twoColumnRenderer.leftColumn`.
    struct TVContents: Decodable, Sendable {
        struct Browse: Decodable, Sendable { @Lenient var content: Surface? }
        struct Surface: Decodable, Sendable { @Lenient var tvSurfaceContentRenderer: Inner? }
        struct Inner: Decodable, Sendable { @Lenient var content: Columns? }
        struct Columns: Decodable, Sendable { @Lenient var twoColumnRenderer: TwoColumn? }
        struct TwoColumn: Decodable, Sendable { @Lenient var leftColumn: Left? }
        struct Left: Decodable, Sendable { @Lenient var entityMetadataRenderer: TileRenderer.FocusCommand.Entity? }
        @Lenient var tvBrowseRenderer: Browse?

        var title: String? {
            tvBrowseRenderer?.content?.tvSurfaceContentRenderer?.content?.twoColumnRenderer?.leftColumn?.entityMetadataRenderer?.title?.string
        }
    }

    @Lenient var metadata: Metadata?
    @Lenient var header: ChannelResponse.Header?
    @Lenient var contents: TVContents?

    var title: String? {
        metadata?.playlistMetadataRenderer?.title ?? header?.pageHeaderRenderer?.pageTitle ?? contents?.title
    }
}
