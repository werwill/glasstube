import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import YTKit
import GlasstubeCore

/// Fase 3: cola, DeArrow, comentarios y chat en la app, sin red (servicios falsos).
@MainActor
@Suite struct PlayQueueTests {
    static func video(_ id: String, short: Bool = false) -> MediaItem {
        var item = MediaItem(kind: .video, title: "Video \(id)", renderer: "test")
        item.videoId = id
        item.isShort = short
        return item
    }

    @Test func playNextGoesFirstAndAppendGoesLast() {
        let queue = PlayQueue()
        queue.append(Self.video("a"))
        queue.append(Self.video("b"))
        queue.playNext(Self.video("c"))
        #expect(queue.items.map(\.id) == ["c", "a", "b"])
        // Lo que ya estaba se mueve al frente; agregar dos veces no lo repite.
        queue.playNext(Self.video("b"))
        queue.append(Self.video("a"))
        #expect(queue.items.map(\.id) == ["b", "c", "a"])
        #expect(queue.popNext()?.id == "b")
        queue.remove(Self.video("c"))
        #expect(queue.items.map(\.id) == ["a"])
    }

    @Test func playlistBecomesTheRestOfTheList() {
        let queue = PlayQueue()
        queue.append(Self.video("x"))
        let list = [Self.video("1"), Self.video("2"), Self.video("s", short: true), Self.video("3")]
        queue.load(playlist: list, after: list[1], title: "Blender")
        #expect(queue.items.map(\.id) == ["3"])
        #expect(queue.sourceTitle == "Blender")
        #expect(queue.popNext()?.id == "3")
        #expect(queue.isEmpty && queue.sourceTitle == nil)
        // Desde el último video de la lista no queda nada.
        queue.load(playlist: list, after: list[3], title: "Blender")
        #expect(queue.isEmpty && queue.sourceTitle == nil)
    }

    @Test func channelsAreNotQueued() {
        let queue = PlayQueue()
        var channel = MediaItem(kind: .channel, title: "Canal", renderer: "test")
        channel.channelId = "UC123"
        queue.append(channel)
        #expect(queue.isEmpty)
    }
}

@MainActor
@Suite struct DeArrowStoreTests {
    @Test func titlesAndThumbnailsFollowTheSettings() {
        let settings = AppSettings()
        let store = DeArrowStore(settings: settings)
        let item = PlayQueueTests.video("aqz-KE-bpKQ")
        store.setBrandingForTesting(DeArrowBranding(videoId: "aqz-KE-bpKQ", title: "Big Buck Bunny (2008)", thumbnailTime: 12))
        let saved = (settings.deArrowEnabled, settings.deArrowTitles, settings.deArrowThumbnails)
        defer { (settings.deArrowEnabled, settings.deArrowTitles, settings.deArrowThumbnails) = saved }

        settings.deArrowEnabled = false
        #expect(store.title(for: item) == "Video aqz-KE-bpKQ")
        #expect(store.thumbnailURL(for: item) == nil)

        settings.deArrowEnabled = true
        settings.deArrowTitles = true
        settings.deArrowThumbnails = false
        #expect(store.title(for: item) == "Big Buck Bunny (2008)")
        #expect(store.replacesTitle(of: item))
        #expect(store.thumbnailURL(for: item) == nil)

        settings.deArrowTitles = false
        settings.deArrowThumbnails = true
        #expect(store.title(for: item) == "Video aqz-KE-bpKQ")
        #expect(store.thumbnailURL(for: item)?.absoluteString.contains("time=12") == true)
    }
}

/// Servicio de comentarios falso: una página con un comentario con respuestas, y las respuestas.
final class FakeComments: CommentsService, @unchecked Sendable {
    var liked: [String: Bool] = [:]
    var failLikes = false

    static func comment(_ id: String, replies: Int? = nil) -> YTKit.Comment {
        var comment = YTKit.Comment(id: id, author: "@persona-\(id)", text: "Texto \(id)")
        comment.replyCount = replies
        comment.repliesToken = replies == nil ? nil : "R-\(id)"
        comment.likeAction = "LIKE-\(id)"
        comment.unlikeAction = "UNLIKE-\(id)"
        return comment
    }

    func comments(_ token: String) async throws -> CommentPage {
        switch token {
        case "TOP": CommentPage(comments: [Self.comment("a", replies: 2), Self.comment("b")], continuation: "PAGE2")
        case "PAGE2": CommentPage(comments: [Self.comment("c")])
        case "NEW": CommentPage(comments: [Self.comment("z")])
        case "R2-a": CommentPage(comments: [Self.comment("a2")])
        default: CommentPage(comments: [])
        }
    }

    func replies(to comment: YTKit.Comment) async throws -> CommentPage {
        CommentPage(comments: [Self.comment("\(comment.id)1")], continuation: "R2-\(comment.id)", parent: comment)
    }

    func setCommentLiked(_ comment: YTKit.Comment, liked: Bool) async throws {
        if failLikes { throw YTKitError.notAvailable("prueba") }
        self.liked[comment.id] = liked
    }

    func reply(to comment: YTKit.Comment, text: String) async throws -> YTKit.Comment? {
        var posted = Self.comment("\(comment.id)-mia")
        posted.text = text
        return posted
    }
}

@MainActor
@Suite struct CommentsModelTests {
    static func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func pagesRepliesAndSorts() async {
        let service = FakeComments()
        let model = CommentsModel(videoId: "v", token: "TOP",
                                  sorts: [CommentSort(title: "Principales", token: "TOP", isSelected: true),
                                          CommentSort(title: "Más recientes", token: "NEW", isSelected: false)], service: service)
        model.loadIfNeeded()
        await Self.waitUntil { !model.comments.isEmpty }
        #expect(model.rows.map(\.id) == ["c:a", "c:b", "more"])

        model.toggleReplies(model.comments[0])
        await Self.waitUntil { model.threads["a"]?.isLoading == false }
        #expect(model.rows.map(\.id) == ["c:a", "r:a:a1", "m:a", "c:b", "more"])
        model.loadMoreReplies(parent: "a")
        await Self.waitUntil { model.threads["a"]?.replies.count == 2 }
        #expect(model.rows.map(\.id) == ["c:a", "r:a:a1", "r:a:a2", "c:b", "more"])

        model.loadMore()
        await Self.waitUntil { model.comments.count == 3 }
        #expect(model.rows.last?.id == "c:c")

        model.select(sort: 1)
        await Self.waitUntil { model.comments.first?.id == "z" }
        #expect(model.rows.map(\.id) == ["c:z"])
        #expect(model.threads.isEmpty)
    }

    @Test func likesAreOptimisticAndRollBack() async {
        let service = FakeComments()
        let model = CommentsModel(videoId: "v", token: "TOP", sorts: [], service: service)
        model.loadIfNeeded()
        await Self.waitUntil { !model.comments.isEmpty }
        model.toggleLike(model.comments[1]) { _ in }
        #expect(model.comments[1].isLiked)
        await Self.waitUntil { service.liked["b"] == true }

        service.failLikes = true
        var message: String?
        model.toggleLike(model.comments[0]) { message = $0 }
        #expect(model.comments[0].isLiked)
        await Self.waitUntil { message != nil }
        #expect(!model.comments[0].isLiked)
    }

    @Test func replyIsInsertedIntoTheThread() async {
        let model = CommentsModel(videoId: "v", token: "TOP", sorts: [], service: FakeComments())
        model.loadIfNeeded()
        await Self.waitUntil { !model.comments.isEmpty }
        model.beginReply(to: model.comments[1])
        model.replyText = "  Hola  "
        var done: String?
        model.sendReply(to: model.comments[1]) { done = $0 }
        await Self.waitUntil { done != nil }
        #expect(done == "Se publicó tu respuesta")
        #expect(model.threads["b"]?.replies.first?.text == "Hola")
        #expect(model.replyingTo == nil)
    }
}

final class NoChat: LiveChatService, @unchecked Sendable {
    func liveChat(_ continuation: String) async throws -> LiveChatUpdate { LiveChatUpdate() }
    func liveChatUpdates(_ continuation: String) -> AsyncThrowingStream<LiveChatUpdate, Error> { AsyncThrowingStream { $0.finish() } }
}

@MainActor
@Suite struct LiveChatModelTests {
    @Test func keepsTheLastMessagesAndRemovesDeletedOnes() {
        let model = LiveChatModel(token: "T", isReplay: false, service: NoChat())
        let first = (0..<LiveChatModel.limit).map { LiveChatMessage(id: "m\($0)", kind: .text, author: "@a", text: "\($0)") }
        model.apply(LiveChatUpdate(messages: first))
        model.apply(LiveChatUpdate(messages: [LiveChatMessage(id: "nuevo", kind: .superChat, author: "@b", text: "hola")], removedIds: ["m5"]))
        #expect(model.messages.count == LiveChatModel.limit)
        #expect(model.messages.last?.id == "nuevo")
        #expect(!model.messages.contains { $0.id == "m5" })
        #expect(model.messages.first?.id == "m0")
        #expect(model.state == .live)
    }
}
