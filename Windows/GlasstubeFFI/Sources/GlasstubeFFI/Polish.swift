import Foundation
import GlasstubeCore
import YTKit

// Desde la 0.6 (app 0.4.0): hojas de miniaturas (vista previa en las tarjetas y al adelantar), DeArrow, enlaces pegados y
// búsqueda con filtros.

// MARK: - Storyboard

struct StoryboardPayload: Encodable {
    var videoId: String
    /// Tamaño de un cuadro (px), cuántos hay y cómo van en cada hoja.
    var width: Int
    var height: Int
    var count: Int
    var columns: Int
    var rows: Int
    /// Duración del video (segundos), para pasar de segundo a cuadro; nil si no se sabe.
    var duration: Double?
    /// Una URL por hoja, en orden: el cuadro `i` está en la hoja `i / (columns * rows)`.
    var sheets: [String]
}

/// Las hojas de miniaturas del video (`playerStoryboardSpecRenderer` del player de VISIONOS, el de los subtítulos), en
/// el nivel más detallado. Falla si el video no tiene (directos, algunos muy cortos).
@_cdecl("gt_storyboard")
public func gt_storyboard(_ videoId: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let videoId = string(videoId) else { return reply.fail("falta el videoId") }
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            let service = playerExtras ?? PlayerExtrasService(catalog: engine.service.catalog)
            playerExtras = service
            let extras = try await service.extras(videoId: videoId)
            guard let spec = extras.storyboard else { throw FFIError("el video no tiene miniaturas") }
            let level = spec.best
            let sheetCount = (level.count + level.perSheet - 1) / level.perSheet
            // `frame(at:)` arma la URL de la hoja; se le pide el primer cuadro de cada una.
            let sheets = (0..<sheetCount).compactMap { sheet -> String? in
                spec.frame(at: Double(sheet * level.perSheet), duration: Double(level.count), level: level)?.url.absoluteString
            }
            reply.ok(StoryboardPayload(videoId: videoId, width: level.width, height: level.height, count: level.count,
                                       columns: level.columns, rows: level.rows, duration: extras.duration, sheets: sheets))
        } catch {
            log("storyboard de \(videoId): \(error)")
            reply.fail(error)
        }
    }
}

// MARK: - DeArrow

struct DeArrowPayload: Encodable {
    struct Item: Encodable {
        var videoId: String
        var title: String?
        /// Miniatura que genera el servidor de DeArrow en el segundo votado.
        var thumbnail: String?
    }

    var items: [Item]
}

/// Títulos y miniaturas de la comunidad (DeArrow) de varios videos. `ids`: un arreglo JSON de videoId. YTKit los pide por
/// prefijo de hash (sin mandar los ids). Solo vienen los que tienen algo.
@_cdecl("gt_dearrow")
public func gt_dearrow(_ ids: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let json = string(ids), let list = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else {
        return reply.fail("ids no es un arreglo JSON")
    }
    Task { @MainActor in
        let found = await DeArrowClient.shared.branding(for: list)
        let items = list.compactMap { id -> DeArrowPayload.Item? in
            guard let branding = found[id], !branding.isEmpty else { return nil }
            return .init(videoId: id, title: branding.title, thumbnail: branding.thumbnailURL?.absoluteString)
        }
        reply.ok(DeArrowPayload(items: items))
    }
}

// MARK: - Enlaces

struct LinkPayload: Encodable {
    /// "video", "playlist", "channel" o "search".
    var kind: String
    /// videoId, playlistId, canal ("UC…", "@handle" o la URL) o el texto a buscar.
    var id: String
    var start: Double?
    var playlistId: String?
}

/// Lo que hay en un texto pegado (youtube.com, youtu.be, m., music., `vnd.youtube:`, también dentro de un texto). Falla
/// si no hay enlace de YouTube.
@_cdecl("gt_parse_link")
public func gt_parse_link(_ text: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    switch string(text).flatMap(YouTubeLink.parse) {
    case let .video(id, start, playlistId)?:
        reply.ok(LinkPayload(kind: "video", id: id, start: start, playlistId: playlistId))
    case let .playlist(id)?:
        reply.ok(LinkPayload(kind: "playlist", id: id))
    case let .channel(id)?:
        reply.ok(LinkPayload(kind: "channel", id: id))
    case let .search(query)?:
        reply.ok(LinkPayload(kind: "search", id: query))
    case nil:
        reply.fail("no es un enlace de YouTube")
    }
}

// MARK: - Búsqueda con filtros

/// Como gt_search, con filtros: `filter` es un SearchFilter de YTKit en JSON ({"priority", "uploadDate", "type",
/// "duration", "features": [int…]}, con los valores de sus enums) o NULL. gt_search_more sigue con la misma búsqueda.
@_cdecl("gt_search_filtered")
public func gt_search_filtered(_ query: UnsafePointer<CChar>?, _ filter: UnsafePointer<CChar>?, _ callback: GTCallback,
                               _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let query = string(query) else { return reply.fail("búsqueda vacía") }
    let searchFilter = string(filter).flatMap { try? JSONDecoder().decode(SearchFilter.self, from: Data($0.utf8)) } ?? .none
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            let state = SearchState.shared
            let page = try await engine.service.search(query, filter: searchFilter)
            state.seen = []
            state.continuation = page.continuation
            let items = state.cards(page)
            log("Búsqueda «\(query)» (\(searchFilter.activeCount) filtros): \(items.count) videos")
            reply.ok(SearchPayload(items: items, hasMore: page.continuation != nil, notice: page.notice,
                                   signedIn: engine.session.knownSignedIn ?? false, channels: state.channels(page)))
        } catch {
            log("Búsqueda falló: \(error)")
            reply.fail(error)
        }
    }
}
