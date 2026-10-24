import Foundation
import Observation
import YTKit

/// Pestañas del panel lateral del reproductor (los `CommentsController`, `ChatController` y `SuggestionsController` de
/// SmartTube, más la descripción y los capítulos que antes iban en un popover).
public enum SidePanelTab: String, CaseIterable, Identifiable {
    case description, chapters, comments, chat, suggestions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .description: "Descripción"
        case .chapters: "Capítulos"
        case .comments: "Comentarios"
        case .chat: "Chat"
        case .suggestions: "Sugeridos"
        }
    }

    public var symbol: String {
        switch self {
        case .description: "text.alignleft"
        case .chapters: "list.bullet.rectangle"
        case .comments: "text.bubble"
        case .chat: "bubble.left.and.text.bubble.right"
        case .suggestions: "rectangle.stack"
        }
    }
}

/// Dónde está el foco del teclado dentro del panel: la fila de pestañas o una fila del contenido.
public enum PanelFocus: Hashable {
    case tabs
    case row(String)
}

/// Comentarios de un video (`CommentsController` de SmartTube): páginas, órdenes, respuestas en línea, me gusta y
/// responder con cuenta.
@Observable
public final class CommentsModel {
    /// Respuestas abiertas de un comentario.
    public struct Thread {
        public var replies: [Comment] = []
        public var continuation: String?
        public var isLoading = false
        public var failure: String?
    }

    /// Fila de la lista (comentario, respuesta o "cargar más"), con un id estable para el foco y el desplazamiento.
    public enum Row: Identifiable, Hashable {
        case comment(Comment)
        case reply(Comment, parent: String)
        case moreReplies(parent: String)
        case loadMore

        public var id: String {
            switch self {
            case .comment(let comment): "c:\(comment.id)"
            case .reply(let comment, let parent): "r:\(parent):\(comment.id)"
            case .moreReplies(let parent): "m:\(parent)"
            case .loadMore: "more"
            }
        }
    }

    public let videoId: String
    public private(set) var sorts: [CommentSort]
    public private(set) var selectedSort: Int
    public private(set) var comments: [Comment] = []
    public private(set) var continuation: String?
    public private(set) var isLoading = false
    public private(set) var failure: String?
    public private(set) var threads: [String: Thread] = [:]
    /// Comentario al que se está respondiendo (el campo de texto aparece bajo él).
    public var replyingTo: String?
    public var replyText = ""
    public private(set) var sendingReply = false

    @ObservationIgnored private let service: any CommentsService
    @ObservationIgnored private var firstToken: String?
    @ObservationIgnored private var started = false

    public init(videoId: String, token: String?, sorts: [CommentSort], service: any CommentsService) {
        self.videoId = videoId
        self.service = service
        self.sorts = sorts
        firstToken = token
        selectedSort = max(0, sorts.firstIndex(where: \.isSelected) ?? 0)
    }

    public var isAvailable: Bool { firstToken != nil }

    /// La lista plana que se dibuja y que recorre el teclado.
    public var rows: [Row] {
        var rows: [Row] = []
        for comment in comments {
            rows.append(.comment(comment))
            if let thread = threads[comment.id] {
                rows += thread.replies.map { .reply($0, parent: comment.id) }
                if thread.continuation != nil { rows.append(.moreReplies(parent: comment.id)) }
            }
        }
        if continuation != nil { rows.append(.loadMore) }
        return rows
    }

    public func loadIfNeeded() {
        guard !started, let token = firstToken else { return }
        started = true
        Task { await load(token, replacing: true) }
    }

    public func loadMore() {
        guard !isLoading, let continuation else { return }
        Task { await load(continuation, replacing: false) }
    }

    public func select(sort index: Int) {
        guard sorts.indices.contains(index), index != selectedSort else { return }
        selectedSort = index
        threads = [:]
        replyingTo = nil
        Task { await load(sorts[index].token, replacing: true) }
    }

    private func load(_ token: String, replacing: Bool) async {
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            let page = try await service.comments(token)
            if replacing { comments = [] }
            let known = Set(comments.map(\.id))
            comments += page.comments.filter { !known.contains($0.id) }
            continuation = page.comments.isEmpty ? nil : page.continuation
        } catch {
            failure = "No se pudieron cargar los comentarios: \(AccountModel.describe(error))"
        }
    }

    /// Abre o cierra las respuestas de un comentario.
    public func toggleReplies(_ comment: Comment) {
        if threads[comment.id] != nil {
            threads[comment.id] = nil
            return
        }
        guard comment.hasReplies else { return }
        threads[comment.id] = Thread(isLoading: true)
        Task { await loadReplies(of: comment, token: nil) }
    }

    public func loadMoreReplies(parent id: String) {
        guard let thread = threads[id], !thread.isLoading, let token = thread.continuation,
              let comment = comments.first(where: { $0.id == id }) else { return }
        threads[id]?.isLoading = true
        Task { await loadReplies(of: comment, token: token) }
    }

    private func loadReplies(of comment: Comment, token: String?) async {
        do {
            let page: CommentPage
            if let token {
                page = try await service.comments(token)
            } else {
                page = try await service.replies(to: comment)
            }
            guard threads[comment.id] != nil else { return }
            let known = Set(threads[comment.id]?.replies.map(\.id) ?? [])
            threads[comment.id]?.replies += page.comments.filter { !known.contains($0.id) && $0.id != comment.id }
            threads[comment.id]?.continuation = page.comments.isEmpty ? nil : page.continuation
            threads[comment.id]?.isLoading = false
        } catch {
            threads[comment.id]?.isLoading = false
            threads[comment.id]?.failure = AccountModel.describe(error)
        }
    }

    /// Me gusta (con cuenta). Optimista: cambia al instante y vuelve si YouTube no lo acepta.
    public func toggleLike(_ comment: Comment, onError: @escaping (String) -> Void) {
        let liked = !comment.isLiked
        update(comment.id) { $0.isLiked = liked }
        Task {
            do {
                try await service.setCommentLiked(comment, liked: liked)
            } catch {
                update(comment.id) { $0.isLiked = !liked }
                onError("YouTube no aceptó el me gusta: \(AccountModel.describe(error))")
            }
        }
    }

    public func beginReply(to comment: Comment) {
        replyingTo = comment.id
        replyText = ""
    }

    /// Publica la respuesta (con cuenta). La respuesta aparece al principio de las del comentario.
    public func sendReply(to comment: Comment, onDone: @escaping (String) -> Void) {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sendingReply else { return }
        sendingReply = true
        Task {
            defer { sendingReply = false }
            do {
                let posted = try await service.reply(to: comment, text: text)
                replyingTo = nil
                replyText = ""
                if let posted {
                    if threads[comment.id] == nil { threads[comment.id] = Thread() }
                    threads[comment.id]?.replies.insert(posted, at: 0)
                }
                onDone("Se publicó tu respuesta")
            } catch {
                onDone("YouTube no aceptó la respuesta: \(AccountModel.describe(error))")
            }
        }
    }

    private func update(_ id: String, _ change: (inout Comment) -> Void) {
        if let index = comments.firstIndex(where: { $0.id == id }) { change(&comments[index]) }
        for key in threads.keys {
            if let index = threads[key]?.replies.firstIndex(where: { $0.id == id }) { change(&threads[key]!.replies[index]) }
        }
    }
}

/// Chat en vivo (`ChatController` de SmartTube): sondea mientras la pestaña está a la vista y guarda los últimos 300
/// mensajes.
@Observable
public final class LiveChatModel {
    public enum State: Equatable {
        case idle, connecting, live, ended
        case failed(String)
    }

    public let token: String
    public let isReplay: Bool
    public private(set) var messages: [LiveChatMessage] = []
    public private(set) var state: State = .idle
    @ObservationIgnored private let service: any LiveChatService
    @ObservationIgnored private var task: Task<Void, Never>?
    public static let limit = 300

    public init(token: String, isReplay: Bool, service: any LiveChatService) {
        self.token = token
        self.isReplay = isReplay
        self.service = service
    }

    public func start() {
        guard task == nil, !isReplay else { return }
        state = .connecting
        let updates = service.liveChatUpdates(token)
        task = Task { [weak self] in
            do {
                for try await update in updates {
                    guard let self else { return }
                    self.apply(update)
                }
                self?.state = .ended
            } catch is CancellationError {
            } catch {
                self?.state = .failed(AccountModel.describe(error))
            }
            self?.task = nil
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        if state == .connecting || state == .live { state = .idle }
    }

    public func apply(_ update: LiveChatUpdate) {
        state = .live
        var list = messages
        if !update.removedIds.isEmpty {
            let removed = Set(update.removedIds)
            list.removeAll { removed.contains($0.id) }
        }
        list += update.messages
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
        messages = list
    }
}
