import Foundation
import GlasstubeCore
import YTKit

// Suscripciones de la cuenta (FEsubscriptions por TV): los videos nuevos, del más reciente al más viejo, y la lista de
// canales suscritos. TV manda una pestaña por canal (`tvSecondaryNavRenderer.sections[].tabs`) con su nombre, foto y
// `presentationStyle` NEW_CONTENT si tiene videos nuevos; YTKit todavía no las expone, así que se leen aquí de la
// misma respuesta.

struct SubscribedChannel: Encodable {
    var id: String
    var name: String
    var avatar: String?
    /// YouTube marca el canal con contenido nuevo.
    var hasNew: Bool
}

struct ChannelGroupPayload: Encodable {
    var id: String
    var title: String
    var channels: [String]
}

struct SubscriptionsPayload: Encodable {
    var items: [VideoCard]
    var hasMore: Bool
    var channels: [SubscribedChannel]
    var groups: [ChannelGroupPayload]
    var notice: String?
    var signedIn: Bool
}

@MainActor
final class SubscriptionsState {
    static let shared = SubscriptionsState()
    var continuation: Continuation?
    var seen: Set<String> = []
    /// Foto de cada canal (de las pestañas), para las tarjetas.
    var avatars: [String: String] = [:]

    /// Otra cuenta: la continuación y los vistos eran de la anterior.
    func reset() {
        continuation = nil
        seen = []
    }

    /// Videos de una página, sin Shorts ni repetidos, del más reciente al más viejo.
    func cards(_ page: BrowsePage) -> [VideoCard] {
        var cards: [VideoCard] = []
        for group in page.groups where !group.isShorts {
            for item in group.items where item.kind == .video && item.isPlayable && !item.isShort {
                guard let id = item.videoId, seen.insert(id).inserted else { continue }
                cards.append(VideoCard(item, shelf: group.title, avatar: item.channelId.flatMap { avatars[$0] }))
            }
        }
        // Orden estable: sin fecha, al final y en el orden de YouTube.
        return cards.enumerated().sorted { a, b in
            switch (a.element.publishedAt, b.element.publishedAt) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// Canales de las pestañas de FEsubscriptions. El id va dentro del `params` de la pestaña (protobuf en base64 con el
/// "UC…" en claro); la primera pestaña ("Todos") no tiene.
func subscribedChannels(_ data: Data) -> [SubscribedChannel] {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
    var navs: [[String: Any]] = []
    func walk(_ node: Any) {
        if let dict = node as? [String: Any] {
            if let nav = dict["tvSecondaryNavRenderer"] as? [String: Any] { navs.append(nav); return }
            dict.values.forEach(walk)
        } else if let list = node as? [Any] {
            list.forEach(walk)
        }
    }
    walk(root)
    var channels: [SubscribedChannel] = []
    var seen = Set<String>()
    for nav in navs {
        for section in nav["sections"] as? [[String: Any]] ?? [] {
            let tabs = (section["tvSecondaryNavSectionRenderer"] as? [String: Any])?["tabs"] as? [[String: Any]] ?? []
            for tab in tabs {
                guard let renderer = tab["tabRenderer"] as? [String: Any],
                      let endpoint = (renderer["endpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
                      let params = endpoint["params"] as? String, let id = channelId(params: params),
                      seen.insert(id).inserted else { continue }
                let thumbnails = ((renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? [])
                    .compactMap { entry -> Thumbnail? in
                        guard let url = entry["url"] as? String else { return nil }
                        return Thumbnail(url: url, width: entry["width"] as? Int, height: entry["height"] as? Int)
                    }
                let style = (renderer["presentationStyle"] as? [String: Any])?["style"] as? String
                channels.append(SubscribedChannel(
                    id: id, name: renderer["title"] as? String ?? id,
                    avatar: thumbnails.best(forWidth: 88).map { absolute($0.url) }, hasNew: style == "NEW_CONTENT"))
            }
        }
    }
    return channels
}

/// "igMaChhVQ2…%3D" → "UC…".
func channelId(params: String) -> String? {
    var base64 = (params.removingPercentEncoding ?? params).replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    guard let data = Data(base64Encoded: base64) else { return nil }
    let text = String(decoding: data.map { (0x20..<0x7f).contains($0) ? $0 : 0x20 }, as: UTF8.self)
    guard let range = text.range(of: "UC[A-Za-z0-9_-]{22}", options: .regularExpression) else { return nil }
    return String(text[range])
}

/// Suscripciones: {"items": [VideoCard…], "hasMore", "channels": [{"id", "name", "avatar", "hasNew"}],
/// "groups": [{"id", "title", "channels": [id…]}], "notice", "signedIn"}. Sin sesión falla con el aviso de YTKit.
@_cdecl("gt_subscriptions")
public func gt_subscriptions(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            _ = try? await engine.session.load()
            let data = try await engine.service.rawRequest("browse", surface: .tv, fields: ["browseId": "FEsubscriptions"],
                                                           authenticated: true)
            let page = try await YouTubeService.parsePage(data, surface: .tv, api: .browse, kind: .subscriptions,
                                                          looseTitle: "Suscripciones")
            let channels = subscribedChannels(data)
            let state = SubscriptionsState.shared
            state.seen = []
            state.continuation = page.continuation
            for channel in channels { if let avatar = channel.avatar { state.avatars[channel.id] = avatar } }
            let items = state.cards(page)
            let groups = Library.shared.groups.groups.map {
                ChannelGroupPayload(id: $0.id, title: $0.title, channels: $0.channels.map(\.id))
            }
            log("Suscripciones: \(items.count) videos, \(channels.count) canales, más: \(page.continuation != nil)")
            reply.ok(SubscriptionsPayload(items: items, hasMore: page.continuation != nil, channels: channels, groups: groups,
                                          notice: page.notice, signedIn: engine.session.knownSignedIn ?? true))
        } catch {
            log("Suscripciones falló: \(error)")
            reply.fail(error)
        }
    }
}

/// Más videos de Suscripciones: {"items", "hasMore", "notice", "signedIn"} (como gt_home_more).
@_cdecl("gt_subscriptions_more")
public func gt_subscriptions_more(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            let state = SubscriptionsState.shared
            guard let continuation = state.continuation else {
                return reply.ok(FeedPage(items: [], hasMore: false, signedIn: true))
            }
            let page = try await engine.service.continuePage(continuation)
            state.continuation = page.continuation
            reply.ok(FeedPage(items: state.cards(page), hasMore: page.continuation != nil, notice: page.notice, signedIn: true))
        } catch {
            log("Suscripciones (más) falló: \(error)")
            reply.fail(error)
        }
    }
}
