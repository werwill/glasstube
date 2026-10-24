import Foundation
import GlasstubeCore
import YTKit

// Búsqueda (YTKit `search`, la interfaz que elija el servicio): solo videos, como el Inicio, con paginación.

@MainActor
final class SearchState {
    static let shared = SearchState()
    var continuation: Continuation?
    var seen: Set<String> = []

    func cards(_ page: BrowsePage) -> [VideoCard] {
        var cards: [VideoCard] = []
        for group in page.groups where !group.isShorts {
            for item in group.items where item.kind == .video && item.isPlayable && !item.isShort {
                guard let id = item.videoId, seen.insert(id).inserted else { continue }
                cards.append(VideoCard(item, shelf: group.title))
            }
        }
        return cards
    }
}

/// Resultados de búsqueda: {"items": [VideoCard…], "hasMore", "notice", "signedIn"}.
@_cdecl("gt_search")
public func gt_search(_ query: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let query = string(query) else { return reply.fail("búsqueda vacía") }
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            let state = SearchState.shared
            let page = try await engine.service.search(query)
            state.seen = []
            state.continuation = page.continuation
            let items = state.cards(page)
            log("Búsqueda «\(query)»: \(items.count) videos")
            reply.ok(FeedPage(items: items, hasMore: page.continuation != nil, notice: page.notice,
                              signedIn: engine.session.knownSignedIn ?? false))
        } catch {
            log("Búsqueda falló: \(error)")
            reply.fail(error)
        }
    }
}

/// Más resultados de la última búsqueda, con la misma forma.
@_cdecl("gt_search_more")
public func gt_search_more(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            let state = SearchState.shared
            guard let continuation = state.continuation else {
                return reply.ok(FeedPage(items: [], hasMore: false, signedIn: engine.session.knownSignedIn ?? false))
            }
            let page = try await engine.service.continuePage(continuation)
            state.continuation = page.continuation
            reply.ok(FeedPage(items: state.cards(page), hasMore: page.continuation != nil, notice: page.notice,
                              signedIn: engine.session.knownSignedIn ?? false))
        } catch {
            log("Búsqueda (más) falló: \(error)")
            reply.fail(error)
        }
    }
}
