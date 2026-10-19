import Foundation

// Conversión de cada renderer de elemento a `MediaItem` (lo que en SmartTube hacen `VideoItem`, `TileItem`,
// `LockupItem`… con sus helpers de `CommonHelper.kt`). Las decisiones se toman por estructura y por los valores
// enumerados (`style`, `contentType`, `badgeStyle`), no por el texto, que depende del idioma.

enum Convert {
    static func thumbnails(_ list: ThumbnailList?) -> [Thumbnail] {
        (list?.all ?? []).compactMap { item in
            guard var url = item.url, !url.isEmpty else { return nil }
            if url.hasPrefix("//") { url = "https:" + url }
            return Thumbnail(url: url, width: item.width?.value, height: item.height?.value)
        }
    }

    /// "4:19" → 259; "1:02:03" → 3723. Nil si no es una duración.
    static func seconds(fromDuration text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard let value = Int(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func playlistId(fromBrowseId browseId: String?) -> String? {
        guard let browseId else { return nil }
        return browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : nil
    }

    /// Tarjetas que no son contenido: los atajos de TV a una pestaña del canal ("Videos", "Shorts"), sin miniatura.
    static func isNavigationShortcut(_ renderer: ItemRenderer) -> Bool {
        if case .tile(let tile) = renderer { return tile.style == "TILE_STYLE_YTLR_WORMHOLE_RECTANGULAR" }
        return false
    }

    static func item(_ renderer: ItemRenderer, key: String) -> MediaItem? {
        switch renderer {
        case .tile(let tile): return Self.tile(tile, key: key)
        case .lockup(let lockup): return Self.lockup(lockup, key: key)
        case .video(let video): return Self.video(video, key: key)
        case .shortsLockup(let short): return Self.short(short, key: key)
        case .channel(let channel): return Self.channel(channel, key: key)
        case .playlist(let playlist, let isMix): return Self.playlist(playlist, isMix: isMix, key: key)
        }
    }

    // MARK: - tileRenderer (TV)

    static func tile(_ t: TileRenderer, key: String) -> MediaItem? {
        let meta = t.metadata?.tileMetadataRenderer
        let header = t.header?.tileHeaderRenderer
        let overlays = header?.thumbnailOverlays ?? []
        let command = t.onSelectCommand
        let watch = command?.first { $0.watchEndpoint }
        let reel = command?.first { $0.reelWatchEndpoint }
        let browse = command?.first { $0.browseEndpoint }
        let watchPlaylist = command?.first { $0.watchPlaylistEndpoint }

        // Shorts de TV: el título va en una superposición de la miniatura. Carrusel: en el `entityMetadataRenderer` que
        // la tarjeta manda a la cabecera al recibir el foco (`updateCarouselHeaderCommand`).
        let spotlight = t.onFocusCommand?.spotlight
        let title = meta?.title?.string ?? overlays.lazy.compactMap { $0.tileMetadataRenderer?.title?.string }.first
            ?? spotlight?.title?.string
        guard let title else { return nil }

        let kind: MediaItem.Kind
        switch t.contentType {
        case "TILE_CONTENT_TYPE_CHANNEL": kind = .channel
        case "TILE_CONTENT_TYPE_PLAYLIST": kind = .playlist
        case "TILE_CONTENT_TYPE_VIDEO", "TILE_CONTENT_TYPE_SHORTS": kind = .video
        default:
            if watch != nil || reel != nil { kind = .video }
            else if let id = browse?.browseId, id.hasPrefix("UC") { kind = .channel }
            else if browse != nil || watchPlaylist != nil { kind = .playlist }
            else { kind = .video }
        }

        var item = MediaItem(kind: kind, title: title, renderer: key)
        item.thumbnails = thumbnails(header?.thumbnail)

        // Líneas: cada `lineRenderer` es una línea; sus partes de texto van seguidas y las insignias aparte.
        var lines: [[YTText]] = []
        for line in meta?.lines ?? spotlight?.bylines ?? [] {
            var texts: [YTText] = []
            for part in line.lineRenderer?.items ?? [] {
                if let badge = part.lineItemRenderer?.badge?.metadataBadgeRenderer, let label = badge.label {
                    item.badges.append(label)
                    if badge.style == "BADGE_STYLE_TYPE_LIVE_NOW" { item.isLive = true }
                }
                if let text = part.lineItemRenderer?.text, let string = text.string,
                   string.trimmingCharacters(in: .whitespaces) != "•" {
                    texts.append(text)
                }
            }
            if !texts.isEmpty { lines.append(texts) }
        }
        item.metadataLines = lines.map { $0.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " • ") }

        for overlay in overlays {
            if let status = overlay.thumbnailOverlayTimeStatusRenderer {
                apply(timeStatus: status, to: &item)
            }
            if let percent = overlay.thumbnailOverlayResumePlaybackRenderer?.percentDurationWatched?.value {
                item.percentWatched = percent
            }
        }

        switch kind {
        case .video:
            item.videoId = watch?.videoId ?? reel?.videoId ?? t.contentId
            item.playlistId = watch?.playlistId
            item.playlistIndex = watch?.index?.value
            item.startTimeSeconds = watch?.startTimeSeconds?.value
            item.params = watch?.params ?? reel?.params
            if reel != nil || t.contentType == "TILE_CONTENT_TYPE_SHORTS" || t.style == "TILE_STYLE_YTLR_SHORTS" {
                item.isShort = true
            }
            if let first = lines.first {
                item.author = first.first?.string
                item.channelId = first.lazy.compactMap(\.channelId).first
            }
            if lines.count > 1 {
                let stats = lines[1].compactMap(\.string)
                item.viewCountText = stats.first
                item.publishedText = stats.count > 1 ? stats[1] : nil
            }
            item.channelId = item.channelId ?? t.onLongPressCommand?.showMenuCommand?.menu?.channelId ?? t.menu?.channelId
            item.feedbackToken = t.onLongPressCommand?.showMenuCommand?.menu?.feedbackToken ?? t.menu?.feedbackToken
            if let panel = t.onLongPressCommand?.showEngagementPanelEndpoint, let tag = panel.identifier?.tag,
               let params = panel.globalConfiguration?.params {
                item.menuPanel = MenuPanel(panelId: tag, params: params)
            }
        case .channel:
            item.channelId = browse?.browseId ?? t.contentId
            item.params = browse?.params
            let texts = lines.flatMap { $0 }.compactMap(\.string)
            item.handle = texts.first { $0.hasPrefix("@") }
            item.subscriberCountText = texts.first { !$0.hasPrefix("@") }
        case .playlist, .mix:
            item.playlistId = playlistId(fromBrowseId: browse?.browseId) ?? watchPlaylist?.playlistId ?? watch?.playlistId ?? t.contentId
            item.videoId = watch?.videoId
            if let first = lines.first {
                item.author = first.compactMap(\.string).joined()
                item.channelId = first.lazy.compactMap(\.channelId).first
            }
            if let id = item.playlistId, id.hasPrefix("RD") { item.kind = .mix }
        }
        return item
    }

    static func apply(timeStatus status: ThumbnailOverlay.TimeStatus, to item: inout MediaItem) {
        switch status.style {
        case "LIVE": item.isLive = true
        case "UPCOMING": item.isUpcoming = true
        case "SHORTS": item.isShort = true
        default:
            if let text = status.text?.string, let seconds = seconds(fromDuration: text) {
                item.durationText = text
                item.durationSeconds = seconds
            }
        }
    }

    // MARK: - lockupViewModel (TV búsqueda, WEB canal y sugeridos)

    static func lockup(_ l: LockupViewModel, key: String) -> MediaItem? {
        let meta = l.metadata?.lockupMetadataViewModel
        guard let title = meta?.title?.string else { return nil }
        let onTap = l.rendererContext?.onTap
        let watch = onTap?.first { $0.watchEndpoint }
        let watchPlaylist = onTap?.first { $0.watchPlaylistEndpoint }
        let reel = onTap?.first { $0.reelWatchEndpoint }
        let browse = onTap?.first { $0.browseEndpoint }

        // contentType vistos: VIDEO, SHORT, MUSIC (canción), STATION (mix), PLAYLIST, PODCAST, ALBUM, CHANNEL.
        let kind: MediaItem.Kind
        switch l.contentType {
        case "LOCKUP_CONTENT_TYPE_CHANNEL": kind = .channel
        case "LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_ALBUM", "LOCKUP_CONTENT_TYPE_PODCAST": kind = .playlist
        case "LOCKUP_CONTENT_TYPE_STATION": kind = .mix
        case "LOCKUP_CONTENT_TYPE_VIDEO", "LOCKUP_CONTENT_TYPE_SHORT", "LOCKUP_CONTENT_TYPE_MUSIC": kind = .video
        default:
            if watch != nil || reel != nil { kind = .video }
            else if let id = browse?.browseId, id.hasPrefix("UC") { kind = .channel }
            else if watchPlaylist != nil || browse?.browseId?.hasPrefix("VL") == true { kind = .playlist }
            else { kind = .video }
        }

        var item = MediaItem(kind: kind, title: title, renderer: key)
        let thumbnail = l.contentImage?.thumbnail
        item.thumbnails = thumbnails(thumbnail?.image)

        let avatar = meta?.image?.decoratedAvatarViewModel
        item.authorThumbnails = thumbnails(avatar?.avatar?.avatarViewModel?.image)

        let rows = (meta?.metadata?.contentMetadataViewModel?.rows ?? []).filter { row in row.contains { $0.string != nil } }
        item.metadataLines = rows.map { $0.compactMap(\.string).joined(separator: " • ") }.filter { !$0.isEmpty }
        let channelFromRows = rows.lazy.flatMap { $0 }.compactMap(\.channelId).first
        item.channelId = channelFromRows ?? avatar?.rendererContext?.onTap?.browseEndpoint?.browseId

        var badgeTexts: [String] = []
        for overlay in thumbnail?.overlays ?? [] {
            for list in [overlay.thumbnailOverlayBadgeViewModel, overlay.thumbnailBottomOverlayViewModel] {
                for badge in (list?.thumbnailBadges ?? []) + (list?.badges ?? []) {
                    guard let vm = badge.thumbnailBadgeViewModel else { continue }
                    if vm.badgeStyle == "THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE" { item.isLive = true }
                    if let text = vm.text { badgeTexts.append(text) }
                }
                if let percent = list?.progressBar?.thumbnailOverlayProgressBarViewModel?.startPercent?.value {
                    item.percentWatched = percent
                }
            }
        }

        switch kind {
        case .video:
            item.videoId = watch?.videoId ?? reel?.videoId ?? l.contentId
            item.playlistId = watch?.playlistId
            item.playlistIndex = watch?.index?.value
            item.startTimeSeconds = watch?.startTimeSeconds?.value
            item.params = watch?.params ?? reel?.params
            item.isShort = reel != nil || l.contentType == "LOCKUP_CONTENT_TYPE_SHORT"
            for text in badgeTexts {
                if item.durationText == nil, let seconds = seconds(fromDuration: text) {
                    item.durationText = text
                    item.durationSeconds = seconds
                } else {
                    item.badges.append(text)
                }
            }
            // Con dos filas o más, la primera es el canal y la última, visualizaciones y fecha.
            if rows.count >= 2 {
                item.author = rows[0].first?.string
                let stats = rows[rows.count - 1].compactMap(\.string)
                item.viewCountText = stats.first
                item.publishedText = stats.count > 1 ? stats[1] : nil
            } else if let stats = rows.first?.compactMap(\.string) {
                item.viewCountText = stats.first
                item.publishedText = stats.count > 1 ? stats[1] : nil
            }
        case .channel:
            item.channelId = browse?.browseId ?? l.contentId
            let texts = rows.flatMap { $0 }.compactMap(\.string)
            item.handle = texts.first { $0.hasPrefix("@") }
            item.subscriberCountText = texts.first { !$0.hasPrefix("@") }
        case .playlist, .mix:
            item.playlistId = l.contentId ?? playlistId(fromBrowseId: browse?.browseId) ?? watchPlaylist?.playlistId ?? watch?.playlistId
            item.videoId = watch?.videoId
            item.videoCountText = badgeTexts.first
            // En una pestaña de canal la primera fila es el tipo ("Lista de reproducción"); el autor es la parte con enlace.
            item.author = rows.lazy.flatMap { $0 }.first { $0.channelId != nil }?.string
            if let id = item.playlistId, id.hasPrefix("RD") { item.kind = .mix }
        }
        return item
    }

    // MARK: - videoRenderer y familia (WEB)

    static func video(_ v: VideoRenderer, key: String) -> MediaItem? {
        guard let title = v.title?.string ?? v.headline?.string else { return nil }
        let watch = v.navigationEndpoint?.first { $0.watchEndpoint }
        let reel = v.navigationEndpoint?.first { $0.reelWatchEndpoint }
        guard let videoId = v.videoId ?? watch?.videoId ?? reel?.videoId else { return nil }

        var item = MediaItem(kind: .video, title: title, renderer: key)
        item.videoId = videoId
        item.thumbnails = thumbnails(v.thumbnail)
        let byline = v.longBylineText ?? v.ownerText ?? v.shortBylineText
        item.author = byline?.string
        let channelLink = v.channelThumbnailSupportedRenderers?.channelThumbnailWithLinkRenderer
        item.channelId = byline?.channelId ?? channelLink?.navigationEndpoint?.browseEndpoint?.browseId
            ?? v.avatar?.decoratedAvatarViewModel?.rendererContext?.onTap?.browseEndpoint?.browseId
            ?? v.menu?.channelId
        item.feedbackToken = v.menu?.feedbackToken
        item.authorThumbnails = thumbnails(channelLink?.thumbnail ?? v.channelThumbnail
            ?? v.avatar?.decoratedAvatarViewModel?.avatar?.avatarViewModel?.image)
        item.viewCountText = v.shortViewCountText?.string ?? v.viewCountText?.string
        item.publishedText = v.publishedTimeText?.string
        item.descriptionSnippet = v.detailedMetadataSnippets?.lazy.compactMap { $0.snippetText?.string }.first
            ?? v.descriptionSnippet?.string
        if let length = v.lengthText?.string {
            item.durationText = length
            item.durationSeconds = seconds(fromDuration: length)
        }
        if let seconds = v.lengthSeconds?.value {
            item.durationSeconds = seconds
        }
        for badge in v.badges ?? [] {
            guard let renderer = badge.metadataBadgeRenderer else { continue }
            if renderer.style == "BADGE_STYLE_TYPE_LIVE_NOW" || renderer.icon?.iconType == "LIVE" { item.isLive = true }
            if let label = renderer.label { item.badges.append(label) }
        }
        for overlay in v.thumbnailOverlays ?? [] {
            if let status = overlay.thumbnailOverlayTimeStatusRenderer {
                apply(timeStatus: status, to: &item)
            }
            if let percent = overlay.thumbnailOverlayResumePlaybackRenderer?.percentDurationWatched?.value {
                item.percentWatched = percent
            }
        }
        if let start = v.upcomingEventData?.startTime?.value {
            item.isUpcoming = true
            item.upcomingStart = Date(timeIntervalSince1970: TimeInterval(start))
        }
        if reel != nil || key == "reelItemRenderer" { item.isShort = true }
        item.playlistId = watch?.playlistId
        item.playlistIndex = watch?.index?.value ?? v.index.flatMap { $0.string.flatMap { Int($0) } }
        item.startTimeSeconds = watch?.startTimeSeconds?.value
        item.params = watch?.params ?? reel?.params
        if let info = v.videoInfo?.string, item.viewCountText == nil { item.metadataLines = [info] }
        return item
    }

    // MARK: - shortsLockupViewModel (WEB)

    static func short(_ s: ShortsLockupViewModel, key: String) -> MediaItem? {
        let reel = s.onTap?.innertubeCommand?.first { $0.reelWatchEndpoint }
        let entityVideoId = s.entityId.flatMap { id in id.hasPrefix("shorts-shelf-item-") ? String(id.dropFirst(18)) : nil }
        guard let videoId = reel?.videoId ?? entityVideoId else { return nil }
        let title = s.overlayMetadata?.primaryText?.string
            ?? s.accessibilityText?.components(separatedBy: ", ").first
        guard let title else { return nil }
        var item = MediaItem(kind: .video, title: title, renderer: key)
        item.videoId = videoId
        item.isShort = true
        item.viewCountText = s.overlayMetadata?.secondaryText?.string
        item.thumbnails = thumbnails(s.thumbnail)
        if item.thumbnails.isEmpty { item.thumbnails = thumbnails(reel?.thumbnail) }
        item.params = reel?.params
        return item
    }

    // MARK: - Canales y listas (WEB)

    static func channel(_ c: ChannelRenderer, key: String) -> MediaItem? {
        guard let title = c.title?.string ?? c.displayName?.string else { return nil }
        var item = MediaItem(kind: .channel, title: title, renderer: key)
        item.channelId = c.channelId ?? c.navigationEndpoint?.browseEndpoint?.browseId
        item.thumbnails = thumbnails(c.thumbnail)
        item.descriptionSnippet = c.descriptionSnippet?.string
        var subscribers = c.subscriberCountText?.string
        var videos = c.videoCountText?.string
        // En los resultados de búsqueda WEB, `subscriberCountText` trae el @handle y `videoCountText` los suscriptores.
        if let handle = subscribers, handle.hasPrefix("@") {
            item.handle = handle
            subscribers = videos
            videos = nil
        }
        item.subscriberCountText = subscribers
        item.videoCountText = videos
        return item
    }

    static func playlist(_ p: PlaylistRenderer, isMix: Bool, key: String) -> MediaItem? {
        guard let title = p.title?.string else { return nil }
        let watch = p.navigationEndpoint?.first { $0.watchEndpoint }
        let browse = p.navigationEndpoint?.first { $0.browseEndpoint }
        var item = MediaItem(kind: isMix ? .mix : .playlist, title: title, renderer: key)
        item.playlistId = p.playlistId ?? watch?.playlistId ?? playlistId(fromBrowseId: browse?.browseId)
        item.videoId = watch?.videoId
        item.thumbnails = thumbnails(p.thumbnail ?? p.thumbnails?.first
            ?? p.thumbnailRenderer?.playlistVideoThumbnailRenderer?.thumbnail
            ?? p.thumbnailRenderer?.playlistCustomThumbnailRenderer?.thumbnail)
        item.videoCountText = p.videoCountText?.string ?? p.videoCountShortText?.string ?? p.videoCount.map { String($0.value) }
        let byline = p.longBylineText ?? p.shortBylineText
        item.author = byline?.string
        item.channelId = byline?.channelId
        return item
    }
}
