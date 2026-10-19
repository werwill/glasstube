import Foundation

// Comentarios: `/next` con el token de comentarios (`CommentsServiceInt` de SmartTube). Como SmartTube, siempre por la
// interfaz de TV (`PostDataHelper.createQueryTV`): responde con `itemSectionContinuation` y `commentRenderer` clásicos
// (autor, texto, fecha, me gusta, número de respuestas y el token de las respuestas). La interfaz WEB manda otra forma
// (`commentViewModel` y entidades en `frameworkUpdates`); el token que da el `next` de WEB también vale con TV
// (comprobado el 16-oct-2026), así que da igual de qué `next` salga.
//
// Respuestas: el token de `detailViewEndpoint` pide otra `itemSectionContinuation` cuyo primer elemento es el
// comentario original (`commentRenderer` suelto, el "activo" de SmartTube) seguido de las respuestas.
//
// Con sesión (solo por TV, como todo lo de la cuenta), los comentarios traen `actionButtons` con los parámetros de
// `comment/perform_comment_action` (me gusta) y, si YouTube lo permite, `createReplyParams` para responder.

/// Un comentario o una respuesta (`CommentItem` de SmartTube).
public struct Comment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var author: String
    public var authorChannelId: String?
    public var authorThumbnails: [Thumbnail] = []
    public var text: String
    /// "hace 7 años", "hace 1 año (editado)".
    public var publishedText: String?
    /// "1.5 K" (nil sin me gusta).
    public var likeCountText: String?
    public var replyCount: Int?
    /// "3 respuestas".
    public var replyCountText: String?
    /// Token de las respuestas (`CommentsService.replies`).
    public var repliesToken: String?
    /// Con sesión: si la cuenta le dio me gusta.
    public var isLiked = false
    public var isPinned = false
    public var isHearted = false
    public var authorIsChannelOwner = false
    /// Con sesión: `action` de `perform_comment_action` para dar y quitar el me gusta.
    public var likeAction: String?
    public var unlikeAction: String?
    /// Con sesión, si YouTube deja responder: `createReplyParams` de `comment/create_comment_reply`.
    public var replyParams: String?

    public init(id: String, author: String, text: String) {
        self.id = id
        self.author = author
        self.text = text
    }

    public var hasReplies: Bool { repliesToken != nil && (replyCount ?? 1) > 0 }
}

/// Orden de los comentarios ("Principales", "Más recientes") con su token.
public struct CommentSort: Codable, Sendable, Hashable, Identifiable {
    public var title: String
    public var token: String
    public var isSelected: Bool

    public var id: String { title }

    public init(title: String, token: String, isSelected: Bool) {
        self.title = title
        self.token = token
        self.isSelected = isSelected
    }
}

/// Una página de comentarios o de respuestas (`CommentGroup` de SmartTube).
public struct CommentPage: Codable, Sendable {
    public var comments: [Comment]
    /// Siguiente página (`CommentGroup.getNextCommentsKey`).
    public var continuation: String?
    /// En una página de respuestas, el comentario al que responden.
    public var parent: Comment?
    /// Con sesión: `createCommentParams` para comentar en el video, si YouTube lo da.
    public var createCommentParams: String?

    public init(comments: [Comment], continuation: String? = nil, parent: Comment? = nil) {
        self.comments = comments
        self.continuation = continuation
        self.parent = parent
    }
}

/// Comentarios de un video (`CommentsService` de SmartTube).
public protocol CommentsService: Sendable {
    /// Una página de comentarios: `MediaItemMetadata.commentsContinuation`, el token de un `CommentSort` o
    /// `CommentPage.continuation`.
    func comments(_ token: String) async throws -> CommentPage
    /// Respuestas de un comentario (o su siguiente página con `CommentPage.continuation` en `comments`).
    func replies(to comment: Comment) async throws -> CommentPage
    /// Con cuenta: me gusta a un comentario (o quitarlo).
    func setCommentLiked(_ comment: Comment, liked: Bool) async throws
    /// Con cuenta: responde a un comentario. Devuelve la respuesta publicada si YouTube la manda.
    @discardableResult
    func reply(to comment: Comment, text: String) async throws -> Comment?
}

// MARK: - Respuesta de TV

struct CommentsResponse: Decodable, Sendable {
    struct ContinuationContents: Decodable, Sendable {
        struct Section: Decodable, Sendable {
            @Lenient var contents: [CommentEntry]?
            @Lenient var continuations: [ContinuationData]?
            @Lenient var header: CommentsHeader?
        }
        @Lenient var itemSectionContinuation: Section?
    }
    @Lenient var continuationContents: ContinuationContents?
    /// WEB (por si un día TV responde así): `onResponseReceivedEndpoints[].*ContinuationItemsCommand`.
    @Lenient var onResponseReceivedEndpoints: [ReceivedEndpoint]?

    struct ReceivedEndpoint: Decodable, Sendable {
        struct Command: Decodable, Sendable { @Lenient var continuationItems: [CommentEntry]? }
        @Lenient var reloadContinuationItemsCommand: Command?
        @Lenient var appendContinuationItemsAction: Command?
    }
}

struct CommentsHeader: Decodable, Sendable {
    struct Renderer: Decodable, Sendable {
        @Lenient var countText: YTText?
        @Lenient var createRenderer: CreateRenderer?
    }
    struct CreateRenderer: Decodable, Sendable {
        struct Simplebox: Decodable, Sendable {
            struct Submit: Decodable, Sendable {
                struct Button: Decodable, Sendable {
                    struct Endpoint: Decodable, Sendable {
                        struct Create: Decodable, Sendable { @Lenient var createCommentParams: String? }
                        @Lenient var createCommentEndpoint: Create?
                    }
                    @Lenient var serviceEndpoint: Endpoint?
                }
                @Lenient var buttonRenderer: Button?
            }
            @Lenient var submitButton: Submit?
        }
        @Lenient var commentSimpleboxRenderer: Simplebox?
    }
    @Lenient var commentsHeaderRenderer: Renderer?

    var createCommentParams: String? {
        commentsHeaderRenderer?.createRenderer?.commentSimpleboxRenderer?.submitButton?.buttonRenderer?.serviceEndpoint?
            .createCommentEndpoint?.createCommentParams
    }
}

/// Elemento de la lista: un hilo (`commentThreadRenderer`), un comentario suelto (el original en una página de
/// respuestas) o la continuación.
struct CommentEntry: Decodable, Sendable {
    struct Thread: Decodable, Sendable {
        struct Wrapper: Decodable, Sendable { @Lenient var commentRenderer: CommentRenderer? }
        @Lenient var comment: Wrapper?
    }
    @Lenient var commentThreadRenderer: Thread?
    @Lenient var commentRenderer: CommentRenderer?
    @Lenient var continuationItemRenderer: ContinuationItemRenderer?
    @Lenient var commentsHeaderRenderer: CommentsHeader.Renderer?
}

struct CommentRenderer: Decodable, Sendable {
    struct PanelEndpoint: Decodable, Sendable {
        struct Show: Decodable, Sendable {
            struct Panel: Decodable, Sendable {
                struct Renderer: Decodable, Sendable {
                    struct Content: Decodable, Sendable {
                        struct List: Decodable, Sendable {
                            struct Item: Decodable, Sendable {
                                struct Section: Decodable, Sendable { @Lenient var continuations: [ContinuationData]? }
                                @Lenient var itemSectionRenderer: Section?
                            }
                            @Lenient var contents: [Item]?
                        }
                        @Lenient var sectionListRenderer: List?
                    }
                    @Lenient var content: Content?
                }
                @Lenient var engagementPanelSectionListRenderer: Renderer?
            }
            @Lenient var engagementPanel: Panel?
        }
        @Lenient var showEngagementPanelEndpoint: Show?
        @Lenient var continuationCommand: ContinuationCommand?
    }
    struct ActionButtons: Decodable, Sendable {
        struct Renderer: Decodable, Sendable {
            struct Toggle: Decodable, Sendable {
                struct Renderer: Decodable, Sendable {
                    struct Endpoint: Decodable, Sendable {
                        struct Action: Decodable, Sendable { @Lenient var action: String? }
                        @Lenient var performCommentActionEndpoint: Action?
                    }
                    @Lenient var isToggled: Bool?
                    @Lenient var defaultServiceEndpoint: Endpoint?
                    @Lenient var toggledServiceEndpoint: Endpoint?
                }
                @Lenient var toggleButtonRenderer: Renderer?
            }
            struct Heart: Decodable, Sendable {
                struct Renderer: Decodable, Sendable { @Lenient var isHearted: Bool? }
                @Lenient var creatorHeartRenderer: Renderer?
            }
            @Lenient var likeButton: Toggle?
            @Lenient var dislikeButton: Toggle?
            @Lenient var creatorHeart: Heart?
        }
        @Lenient var commentActionButtonsRenderer: Renderer?
    }
    struct AuthorEndpoint: Decodable, Sendable { @Lenient var browseEndpoint: BrowseEndpoint? }

    @Lenient var commentId: String?
    @Lenient var authorText: YTText?
    @Lenient var authorThumbnail: ThumbnailList?
    @Lenient var authorEndpoint: AuthorEndpoint?
    @Lenient var authorIsChannelOwner: Bool?
    @Lenient var contentText: YTText?
    @Lenient var publishedTimeText: YTText?
    @Lenient var isLiked: Bool?
    @Lenient var voteCount: YTText?
    @Lenient var replyCount: FlexibleInt?
    @Lenient var repliesCount: YTText?
    @Lenient var detailViewEndpoint: PanelEndpoint?
    @Lenient var actionButtons: ActionButtons?
    @Lenient var pinnedCommentBadge: Ignored?

    /// Cualquier valor (solo importa que exista).
    struct Ignored: Decodable, Sendable { init(from decoder: Decoder) throws {} }

    var repliesToken: String? {
        let items = detailViewEndpoint?.showEngagementPanelEndpoint?.engagementPanel?.engagementPanelSectionListRenderer?
            .content?.sectionListRenderer?.contents ?? []
        return items.lazy.compactMap { $0.itemSectionRenderer?.continuations?.lazy.compactMap(\.token).first }.first
            ?? detailViewEndpoint?.continuationCommand?.token
    }
}

enum CommentsParser {
    /// Una página de comentarios (o de respuestas, si `replies`: el primer comentario suelto es el original).
    static func page(_ data: Data, replies: Bool) throws -> CommentPage {
        let response = try JSONDecoder().decode(CommentsResponse.self, from: data)
        let section = response.continuationContents?.itemSectionContinuation
        var entries = section?.contents ?? []
        if entries.isEmpty {
            for endpoint in response.onResponseReceivedEndpoints ?? [] {
                entries += endpoint.reloadContinuationItemsCommand?.continuationItems ?? []
                entries += endpoint.appendContinuationItemsAction?.continuationItems ?? []
            }
        }
        var page = CommentPage(comments: [])
        for entry in entries {
            if let renderer = entry.commentThreadRenderer?.comment?.commentRenderer ?? entry.commentRenderer,
               let comment = comment(from: renderer) {
                // En las respuestas, el comentario suelto que encabeza la lista es el original.
                if replies, page.parent == nil, page.comments.isEmpty, entry.commentThreadRenderer == nil {
                    page.parent = comment
                } else {
                    page.comments.append(comment)
                }
            } else if let token = entry.continuationItemRenderer?.token {
                page.continuation = token
            }
        }
        page.continuation = section?.continuations?.lazy.compactMap(\.token).first ?? page.continuation
        page.createCommentParams = section?.header?.createCommentParams
        if !page.comments.isEmpty || page.parent != nil || section != nil { return page }
        throw YTKitError.badResponse("la respuesta de comentarios no trae itemSectionContinuation")
    }

    static func comment(from r: CommentRenderer) -> Comment? {
        guard let id = r.commentId, let text = r.contentText?.string else { return nil }
        var comment = Comment(id: id, author: r.authorText?.string ?? "", text: text)
        comment.authorChannelId = r.authorEndpoint?.browseEndpoint?.browseId
        comment.authorThumbnails = Convert.thumbnails(r.authorThumbnail)
        comment.publishedText = r.publishedTimeText?.string
        comment.likeCountText = r.voteCount?.string
        comment.replyCount = r.replyCount?.value
        comment.replyCountText = r.repliesCount?.accessibilityLabel ?? r.repliesCount?.string
        comment.repliesToken = r.repliesToken
        comment.isLiked = r.isLiked ?? false
        comment.isPinned = r.pinnedCommentBadge != nil
        comment.authorIsChannelOwner = r.authorIsChannelOwner ?? false
        let buttons = r.actionButtons?.commentActionButtonsRenderer
        let like = buttons?.likeButton?.toggleButtonRenderer
        comment.likeAction = like?.defaultServiceEndpoint?.performCommentActionEndpoint?.action
        comment.unlikeAction = like?.toggledServiceEndpoint?.performCommentActionEndpoint?.action
        if let toggled = like?.isToggled { comment.isLiked = toggled }
        comment.isHearted = buttons?.creatorHeart?.creatorHeartRenderer?.isHearted ?? false
        return comment
    }
}

/// `createReplyParams` de cada comentario: va en lo profundo del botón "Responder" (`replyButton` →
/// `createCommentReplyDialogEndpoint` → … → `createCommentReplyEndpoint`). Su forma cambia según la interfaz, así que se
/// busca la clave en el JSON de `actionButtons` en vez de modelar cada camino.
enum ReplyParams {
    /// Busca la primera cadena con esa clave en un árbol JSON.
    static func first(_ key: String, in value: Any, depth: Int = 0) -> String? {
        guard depth < 40 else { return nil }
        if let object = value as? [String: Any] {
            if let found = object[key] as? String { return found }
            for child in object.values {
                if let found = first(key, in: child, depth: depth + 1) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = first(key, in: child, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    /// `createReplyParams` por comentario, del JSON crudo de la página (id del comentario → params).
    static func all(in data: Data) -> [String: String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var result: [String: String] = [:]
        func walk(_ value: Any, depth: Int) {
            guard depth < 60 else { return }
            if let object = value as? [String: Any] {
                if let renderer = object["commentRenderer"] as? [String: Any], let id = renderer["commentId"] as? String,
                   let buttons = renderer["actionButtons"], let params = first("createReplyParams", in: buttons) {
                    result[id] = params
                }
                for child in object.values { walk(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { walk(child, depth: depth + 1) }
            }
        }
        walk(json, depth: 0)
        return result
    }
}

extension YouTubeService: CommentsService {
    /// `/next` por TV con el token. Con sesión va con la cuenta (trae el me gusta de la cuenta y los parámetros de las
    /// acciones); sin ella, anónima.
    public func comments(_ token: String) async throws -> CommentPage {
        try await commentPage(token, replies: false)
    }

    public func replies(to comment: Comment) async throws -> CommentPage {
        guard let token = comment.repliesToken else { throw YTKitError.notAvailable("el comentario no tiene respuestas") }
        return try await commentPage(token, replies: true)
    }

    func commentPage(_ token: String, replies: Bool) async throws -> CommentPage {
        let data = try await api.post(.next, surface: .tv, ["continuation": token])
        return try await Self.parseComments(data, replies: replies)
    }

    /// Convierte una respuesta cruda de comentarios (pruebas y diagnóstico).
    public static func parseComments(_ data: Data, replies: Bool) async throws -> CommentPage {
        try await InnertubeDecoding.run {
            var page = try CommentsParser.page(data, replies: replies)
            let params = ReplyParams.all(in: data)
            if !params.isEmpty {
                for index in page.comments.indices { page.comments[index].replyParams = params[page.comments[index].id] }
                if let id = page.parent?.id { page.parent?.replyParams = params[id] }
            }
            return page
        }
    }

    /// `comment/perform_comment_action` con la acción del botón (`CommentsServiceInt.toggleLike` de SmartTube).
    public func setCommentLiked(_ comment: Comment, liked: Bool) async throws {
        guard let action = liked ? comment.likeAction : comment.unlikeAction else {
            throw YTKitError.notAvailable("YouTube no da el me gusta de este comentario (¿sin sesión?)")
        }
        try await self.action("comment/perform_comment_action", ["actions": [action]], what: "Me gusta del comentario")
    }

    /// `comment/create_comment_reply` con `createReplyParams` y el texto.
    @discardableResult
    public func reply(to comment: Comment, text: String) async throws -> Comment? {
        guard let params = comment.replyParams else {
            throw YTKitError.notAvailable("YouTube no deja responder a este comentario desde la interfaz de TV")
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw YTKitError.notAvailable("la respuesta está vacía") }
        let data = try await api.post("comment/create_comment_reply", surface: .tv, ["createReplyParams": params, "commentText": body],
                                      auth: .required("Responder"))
        return try? await InnertubeDecoding.run { () -> Comment? in
            let json = try JSONSerialization.jsonObject(with: data)
            guard let renderer = Self.firstObject("commentRenderer", in: json),
                  let rendererData = try? JSONSerialization.data(withJSONObject: renderer) else { return nil }
            return CommentsParser.comment(from: try JSONDecoder().decode(CommentRenderer.self, from: rendererData))
        }
    }

    static func firstObject(_ key: String, in value: Any, depth: Int = 0) -> [String: Any]? {
        guard depth < 40 else { return nil }
        if let object = value as? [String: Any] {
            if let found = object[key] as? [String: Any] { return found }
            for child in object.values { if let found = firstObject(key, in: child, depth: depth + 1) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = firstObject(key, in: child, depth: depth + 1) { return found } }
        }
        return nil
    }
}
