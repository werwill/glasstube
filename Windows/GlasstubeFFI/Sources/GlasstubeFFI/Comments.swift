import Foundation
import YTKit

// Comentarios del panel lateral: páginas de `CommentsService` de YTKit (por la interfaz de TV, con o sin sesión). La
// primera página sale del token de `gt_watch_next` (o del de un orden); las siguientes, de `continuation`.

struct CommentPayload: Encodable {
    var id: String
    var author: String
    var authorChannelId: String?
    var avatar: String?
    var text: String
    /// "hace 2 años", "hace 3 días (editado)".
    var published: String?
    /// "1.5 K"; nil sin me gusta.
    var likes: String?
    var replyCount: Int?
    /// "3 respuestas".
    var replyCountText: String?
    /// Token de las respuestas (`gt_comments` con `replies` = 1).
    var repliesToken: String?
    var isPinned: Bool
    var isHearted: Bool
    var authorIsChannelOwner: Bool
}

struct CommentPagePayload: Encodable {
    var comments: [CommentPayload]
    /// Siguiente página (`gt_comments` con `replies` = 0, también para más respuestas).
    var continuation: String?
}

extension CommentPayload {
    init(_ comment: Comment) {
        self.init(
            id: comment.id, author: comment.author, authorChannelId: comment.authorChannelId,
            avatar: comment.authorThumbnails.best(forWidth: 48).map { absolute($0.url) }, text: comment.text,
            published: comment.publishedText, likes: comment.likeCountText, replyCount: comment.replyCount,
            replyCountText: comment.replyCountText, repliesToken: comment.hasReplies ? comment.repliesToken : nil,
            isPinned: comment.isPinned, isHearted: comment.isHearted, authorIsChannelOwner: comment.authorIsChannelOwner)
    }
}

/// Una página de comentarios: {"comments": [{"id", "author", "authorChannelId", "avatar", "text", "published",
/// "likes", "replyCount", "replyCountText", "repliesToken", "isPinned", "isHearted", "authorIsChannelOwner"}],
/// "continuation"}. `replies` = 1: `token` es el `repliesToken` de un comentario y la página son sus respuestas (sin el
/// comentario original); 0: un token de comentarios, de un orden o una `continuation`.
@_cdecl("gt_comments")
public func gt_comments(_ token: UnsafePointer<CChar>?, _ replies: Int32, _ callback: GTCallback,
                        _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let token = string(token) else { return reply.fail("falta el token") }
    Task { @MainActor in
        do {
            let service = try Engine.require().service
            let page: CommentPage
            if replies != 0 {
                var parent = Comment(id: "", author: "", text: "")
                parent.repliesToken = token
                page = try await service.replies(to: parent)
            } else {
                page = try await service.comments(token)
            }
            reply.ok(CommentPagePayload(comments: page.comments.map(CommentPayload.init), continuation: page.continuation))
        } catch {
            log("comentarios: \(error)")
            reply.fail(error)
        }
    }
}
