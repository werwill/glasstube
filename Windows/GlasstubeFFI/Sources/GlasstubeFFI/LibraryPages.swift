import Foundation
import YTKit

// Las páginas Historial y Biblioteca: quitar del historial local (uno o todo) y, con sesión, las listas de la cuenta
// (`FEplaylist_aggregation`) y su Ver más tarde (`WL`) por la interfaz de TV.

/// Quita un video del historial local. Responde {}.
@_cdecl("gt_history_remove")
public func gt_history_remove(_ videoId: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let videoId = string(videoId) else { return reply.fail("falta el videoId") }
    Task { @MainActor in
        let local = Library.shared.local
        if let saved = local.history.first(where: { $0.item.videoId == videoId }) {
            local.removeFromHistory(saved.item)
            log("historial: quitado \(videoId)")
        }
        reply.ok([String: String]())
    }
}

/// Borra todo el historial local. Responde {}.
@_cdecl("gt_history_clear")
public func gt_history_clear(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        let count = Library.shared.local.history.count
        Library.shared.local.clearHistory()
        Library.shared.local.saveNow()
        log("historial: borrados \(count) videos")
        reply.ok([String: String]())
    }
}

struct AccountLibraryPayload: Encodable {
    var signedIn: Bool
    /// Las listas de la cuenta (Me gusta, las propias y las guardadas) como VideoCard con `playlistId`.
    var playlists: [VideoCard]
    /// Ver más tarde de la cuenta (primera página) y su `feed` para gt_feed_more.
    var watchLater: [VideoCard]
    var watchLaterFeed: String?
    /// Por qué falta algo (sin sesión, error de YouTube…).
    var notice: String?
}

/// La Biblioteca de la cuenta: {"signedIn", "playlists": [VideoCard…], "watchLater": [VideoCard…], "watchLaterFeed",
/// "notice"}. Sin sesión, listas vacías y `signedIn` false.
@_cdecl("gt_account_library")
public func gt_account_library(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            if engine.session.knownSignedIn == nil { _ = try? await engine.session.load() }
            guard engine.session.knownSignedIn ?? false else {
                return reply.ok(AccountLibraryPayload(signedIn: false, playlists: [], watchLater: []))
            }
            let service = engine.service
            async let playlistsPage = Result(catching: { try await service.playlists() })
            async let watchLaterPage = Result(catching: { try await service.watchLater() })
            var notices: [String] = []

            var playlists: [VideoCard] = []
            switch await playlistsPage {
            case .success(let page):
                var seen: Set<String> = []
                // Ver más tarde ya va en su propia fila.
                playlists = browseCards(page, seen: &seen).filter { $0.playlistId != nil && $0.playlistId != "WL" }
            case .failure(let error):
                notices.append("listas: \(error)")
            }

            var watchLater: [VideoCard] = []
            var feed: String?
            switch await watchLaterPage {
            case .success(let page):
                var seen: Set<String> = []
                watchLater = browseCards(page, seen: &seen).filter { $0.playlistId == nil }
                feed = FeedStore.shared.register(page, seen: seen)
            case .failure(let error):
                notices.append("Ver más tarde: \(error)")
            }
            log("biblioteca de la cuenta: \(playlists.count) listas, \(watchLater.count) en Ver más tarde\(notices.isEmpty ? "" : " (\(notices.joined(separator: "; ")))")")
            reply.ok(AccountLibraryPayload(signedIn: true, playlists: playlists, watchLater: watchLater, watchLaterFeed: feed,
                                           notice: notices.isEmpty ? nil : notices.joined(separator: "\n")))
        } catch {
            log("biblioteca de la cuenta: \(error)")
            reply.fail(error)
        }
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
