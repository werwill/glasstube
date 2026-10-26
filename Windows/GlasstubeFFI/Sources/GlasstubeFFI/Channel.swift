import Foundation
import YTKit

// Canales y listas (YTKit `channel` y `playlist`, por la interfaz que elija el servicio): la cabecera del canal, sus
// pestañas Videos, Shorts, En vivo y Playlists, y los videos de una lista. Las páginas siguientes van por un `feed`
// (FeedStore), que sirve igual para cualquier página paginada (también las listas de la Biblioteca).

// MARK: - Tarjetas de lista

extension VideoCard {
    /// Una lista (o mix) como tarjeta: el id es el de la lista (`playlistId`) y la duración lleva el número de videos.
    @MainActor
    init?(playlist item: MediaItem) {
        guard let playlistId = item.playlistId else { return nil }
        let thumbnail = item.thumbnails.best(forWidth: 480)
        self.init(
            id: playlistId, title: item.title, channel: item.author, channelId: item.channelId,
            thumbnail: thumbnail.map { absolute($0.url) }, duration: item.videoCountText,
            views: nil, published: nil, subtitle: item.videoCountText ?? "", isLive: false, shelf: nil)
        self.playlistId = playlistId
        thumbnailLarge = self.thumbnail
    }
}

/// Videos y listas de una página, sin canales y sin repetir.
@MainActor
func browseCards(_ page: BrowsePage, seen: inout Set<String>) -> [VideoCard] {
    var cards: [VideoCard] = []
    for group in page.groups {
        for item in group.items {
            switch item.kind {
            case .video:
                guard item.isPlayable || item.isLive || item.isUpcoming, let id = item.videoId, seen.insert(id).inserted else { continue }
                cards.append(VideoCard(item, shelf: group.title))
            case .playlist, .mix:
                guard let card = VideoCard(playlist: item), seen.insert(card.id).inserted else { continue }
                cards.append(card)
            case .channel:
                continue
            }
        }
    }
    return cards
}

// MARK: - Páginas siguientes

/// Continuaciones de las páginas que la interfaz pagina, con un id corto (`feed`) que va y viene.
@MainActor
final class FeedStore {
    static let shared = FeedStore()

    private struct Feed {
        /// Más filas de la página, o más elementos de una fila (las pestañas de canal de WEB paginan la cuadrícula).
        var continuation: Continuation?
        var group: MediaGroup?
        var seen: Set<String>
    }

    private var feeds: [String: Feed] = [:]
    private var next = 0

    /// Guarda lo que haga falta para seguir; nil si la página no tiene más.
    func register(_ page: BrowsePage, seen: Set<String>) -> String? {
        let group = page.continuation == nil ? page.groups.last(where: { $0.continuation != nil }) : nil
        guard page.continuation != nil || group != nil else { return nil }
        next += 1
        let id = "f\(next)"
        feeds[id] = Feed(continuation: page.continuation, group: group, seen: seen)
        if feeds.count > 40, let oldest = feeds.keys.min(by: { Int($0.dropFirst()) ?? 0 < Int($1.dropFirst()) ?? 0 }) {
            feeds[oldest] = nil
        }
        return id
    }

    func more(_ id: String, service: YouTubeService) async throws -> FeedMorePayload {
        guard var feed = feeds[id] else { return FeedMorePayload(items: [], hasMore: false, feed: nil) }
        let page: BrowsePage
        if let continuation = feed.continuation {
            page = try await service.continuePage(continuation)
            feed.continuation = page.continuation
            feed.group = nil
        } else if let group = feed.group {
            let more = try await service.continueGroup(group)
            page = BrowsePage(title: nil, groups: [more], continuation: nil, surface: group.continuation?.surface ?? .web)
            feed.group = more.continuation != nil ? more : nil
        } else {
            return FeedMorePayload(items: [], hasMore: false, feed: nil)
        }
        let items = browseCards(page, seen: &feed.seen)
        let hasMore = feed.continuation != nil || feed.group != nil
        feeds[id] = hasMore ? feed : nil
        return FeedMorePayload(items: items, hasMore: hasMore, feed: hasMore ? id : nil)
    }
}

struct FeedMorePayload: Encodable {
    var items: [VideoCard]
    var hasMore: Bool
    var feed: String?
}

/// Más elementos de una página paginada (`feed` de gt_channel, gt_playlist…): {"items", "hasMore", "feed"}.
@_cdecl("gt_feed_more")
public func gt_feed_more(_ feed: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let feed = string(feed) else { return reply.ok(FeedMorePayload(items: [], hasMore: false, feed: nil)) }
    Task { @MainActor in
        do {
            reply.ok(try await FeedStore.shared.more(feed, service: Engine.require().service))
        } catch {
            log("más de \(feed): \(error)")
            reply.fail(error)
        }
    }
}

// MARK: - Canal

struct ChannelPayload: Encodable {
    var channelId: String
    var title: String?
    var handle: String?
    var description: String?
    var subscribers: String?
    var videoCount: String?
    var avatar: String?
    var banner: String?
    /// Pestañas que tiene el canal: "videos", "shorts", "live", "playlists"…
    var tabs: [String]
    /// La pestaña que devolvió YouTube.
    var tab: String?
    var items: [VideoCard]
    var hasMore: Bool
    var feed: String?
}

/// Un canal con una pestaña (`tab`: "videos", "shorts", "live", "playlists"; NULL = videos): {"channelId", "title",
/// "handle", "description", "subscribers", "videoCount", "avatar", "banner", "tabs", "tab", "items": [VideoCard…],
/// "hasMore", "feed"}. Las listas van como VideoCard con "playlistId".
@_cdecl("gt_channel")
public func gt_channel(_ channelId: UnsafePointer<CChar>?, _ tab: UnsafePointer<CChar>?, _ callback: GTCallback,
                       _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let channelId = string(channelId) else { return reply.fail("falta el canal") }
    let kind = string(tab).flatMap(ChannelTab.Kind.init(rawValue:)) ?? .videos
    Task { @MainActor in
        do {
            let page = try await Engine.require().service.channel(channelId, tab: kind)
            var seen: Set<String> = []
            let items = browseCards(page.content, seen: &seen)
            let feed = FeedStore.shared.register(page.content, seen: seen)
            log("canal \(page.title ?? channelId) (\(kind.rawValue) → \(page.selectedTab?.rawValue ?? "?")): \(items.count) elementos, más: \(feed != nil)")
            reply.ok(ChannelPayload(
                channelId: page.channelId, title: page.title, handle: page.handle, description: page.description,
                subscribers: page.subscriberCountText, videoCount: page.videoCountText,
                avatar: page.avatar.best(forWidth: 176).map { absolute($0.url) },
                banner: page.banner.best(forWidth: 1920).map { absolute($0.url) },
                tabs: page.tabs.map(\.kind.rawValue), tab: page.selectedTab?.rawValue, items: items,
                hasMore: feed != nil, feed: feed))
        } catch {
            log("canal \(channelId): \(error)")
            reply.fail(error)
        }
    }
}

// MARK: - Lista

struct PlaylistPayload: Encodable {
    var playlistId: String
    var title: String?
    var items: [VideoCard]
    var hasMore: Bool
    var feed: String?
}

/// Los videos de una lista ("PL…", "WL", "LL"…): {"playlistId", "title", "items", "hasMore", "feed"}. Ver más tarde y
/// Me gusta van con la cuenta.
@_cdecl("gt_playlist")
public func gt_playlist(_ playlistId: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let playlistId = string(playlistId) else { return reply.fail("falta la lista") }
    Task { @MainActor in
        do {
            let page = try await Engine.require().service.playlist(playlistId)
            var seen: Set<String> = []
            let items = browseCards(page, seen: &seen)
            let feed = FeedStore.shared.register(page, seen: seen)
            log("lista \(playlistId) «\(page.title ?? "")»: \(items.count) videos, más: \(feed != nil)")
            reply.ok(PlaylistPayload(playlistId: playlistId, title: page.title, items: items, hasMore: feed != nil, feed: feed))
        } catch {
            log("lista \(playlistId): \(error)")
            reply.fail(error)
        }
    }
}
