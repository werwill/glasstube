import Foundation
import YTKit

// Lo que el panel lateral del reproductor saca de `/next` (MediaItemMetadata de YTKit) además de la descripción: los
// sugeridos, el siguiente de la reproducción automática y el token y los órdenes de los comentarios (Comments.swift).

struct CommentSortPayload: Encodable {
    /// "Principales", "Más recientes" (los da YouTube en el idioma del catálogo).
    var title: String
    var token: String
    var isSelected: Bool
}

struct WatchNextPayload: Encodable {
    var videoId: String
    var suggestions: [VideoCard]
    /// El siguiente de la reproducción automática (casi siempre el primero de los sugeridos).
    var next: VideoCard?
    /// Primera página de comentarios (`gt_comments`); nil si están desactivados.
    var commentsToken: String?
    /// "5.2 K".
    var commentsCount: String?
    var commentSorts: [CommentSortPayload]
}

/// Sugeridos y comentarios de un video: {"videoId", "suggestions": [VideoCard…], "next": VideoCard | null,
/// "commentsToken", "commentsCount", "commentSorts": [{"title", "token", "isSelected"}]}. Solo videos (sin Shorts,
/// canales ni listas), sin repetir.
@_cdecl("gt_watch_next")
public func gt_watch_next(_ videoId: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let videoId = string(videoId) else { return reply.fail("falta el videoId") }
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            let metadata = try await MetadataCache.metadata(videoId: videoId, service: engine.service)
            var seen: Set<String> = [videoId]
            var suggestions: [VideoCard] = []
            for group in metadata.suggestions where !group.isShorts {
                for item in group.items where item.kind == .video && item.isPlayable && !item.isShort {
                    guard let id = item.videoId, seen.insert(id).inserted else { continue }
                    suggestions.append(VideoCard(item, shelf: group.title))
                }
            }
            var next = metadata.nextVideoId.flatMap { id in suggestions.first { $0.id == id } }
            if next == nil, let item = metadata.nextVideo, item.videoId != nil { next = VideoCard(item, shelf: nil) }
            if next == nil { next = suggestions.first }
            log("sugeridos de \(videoId): \(suggestions.count), siguiente \(next?.id ?? "-"), comentarios \(metadata.commentsContinuation != nil ? (metadata.commentsCountText ?? "sí") : "no"), órdenes \(metadata.commentSorts.count)")
            reply.ok(WatchNextPayload(
                videoId: videoId, suggestions: suggestions, next: next, commentsToken: metadata.commentsContinuation,
                commentsCount: metadata.commentsCountText,
                commentSorts: metadata.commentSorts.map { CommentSortPayload(title: $0.title, token: $0.token, isSelected: $0.isSelected) }))
        } catch {
            log("sugeridos de \(videoId): \(error)")
            reply.fail(error)
        }
    }
}
