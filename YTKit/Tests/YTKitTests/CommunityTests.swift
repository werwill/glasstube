import Foundation
import Testing
@testable import YTKit

/// Fase 3: comentarios, respuestas y chat en vivo (respuestas reales de TV grabadas y anonimizadas con
/// `ytkit record-community`), DeArrow y Return YouTube Dislike.
@Suite struct CommentsTests {
    static func page(_ name: String, replies: Bool = false) throws -> CommentPage {
        let data = try Fixture.data("comunidad/\(name).json")
        return try InnertubeDecoding.runSync { try CommentsParser.page(data, replies: replies) }
    }

    @Test func firstPage() throws {
        let page = try Self.page("comments-tv")
        #expect(page.comments.count == 8)
        #expect(page.continuation != nil)
        #expect(page.parent == nil)
        #expect(Set(page.comments.map(\.id)).count == page.comments.count)
        for comment in page.comments {
            #expect(comment.author.hasPrefix("@persona"))
            #expect(comment.text.hasPrefix("Texto de prueba"))
            #expect(comment.publishedText?.hasPrefix("hace") == true)
            #expect(!comment.authorThumbnails.isEmpty && comment.authorThumbnails.allSatisfy { $0.url.hasPrefix("https://") })
            // Sin sesión no hay acciones.
            #expect(comment.likeAction == nil && comment.replyParams == nil && !comment.isLiked)
        }
        let withReplies = try #require(page.comments.first { $0.hasReplies })
        #expect((withReplies.replyCount ?? 0) > 0)
        #expect(withReplies.replyCountText?.contains("respuesta") == true)
        #expect(page.comments.contains { $0.likeCountText != nil })
    }

    @Test func repliesStartWithTheOriginal() throws {
        let first = try Self.page("comments-tv").comments.first(where: \.hasReplies)
        let page = try Self.page("comments-replies-tv", replies: true)
        #expect(page.parent?.id == first?.id)
        #expect(!page.comments.isEmpty)
        #expect(!page.comments.contains { $0.id == page.parent?.id })
    }

    @Test func newestSort() throws {
        let page = try Self.page("comments-newest-tv")
        #expect(!page.comments.isEmpty)
        #expect(page.continuation != nil)
    }

    @Test func tokensAndSortsFromNext() throws {
        let meta = try Fixture.metadata("comunidad/next-bunny-tv.json", videoId: "aqz-KE-bpKQ")
        #expect(meta.commentsContinuation != nil)
        #expect(meta.commentsCountText?.isEmpty == false)
        #expect(meta.commentSorts.map(\.title) == ["Principales", "Más recientes"])
        #expect(meta.commentSorts.first?.isSelected == true)
        #expect(meta.commentSorts.first?.token == meta.commentsContinuation)
        #expect(meta.liveChatContinuation == nil)
    }

    @Test func webSortItemsUseServiceEndpoints() throws {
        let json = #"""
        {"engagementPanels": [{"engagementPanelSectionListRenderer": {"panelIdentifier": "engagement-panel-comments-section",
          "header": {"engagementPanelTitleHeaderRenderer": {"contextualInfo": {"runs": [{"text": "5.2 K"}]},
            "menu": {"sortFilterSubMenuRenderer": {"subMenuItems": [
              {"title": "Principales", "selected": true, "serviceEndpoint": {"continuationCommand": {"token": "TOP"}}},
              {"title": "Más recientes", "selected": false, "serviceEndpoint": {"continuationCommand": {"token": "NEW"}}}]}}}}}}],
         "contents": {"twoColumnWatchNextResults": {"conversationBar": {"liveChatRenderer": {"continuations": [
           {"reloadContinuationData": {"continuation": "CHAT"}}]}}}}}
        """#
        let response = try Fixture.decode(WatchNextResponse.self, json)
        let meta = WatchNextParser.metadata(videoId: "x", response: response, surface: .web)
        #expect(meta.commentSorts.map(\.token) == ["TOP", "NEW"])
        #expect(meta.commentsCountText == "5.2 K")
        #expect(meta.commentsContinuation == "TOP")
        #expect(meta.liveChatContinuation == "CHAT")
    }

    /// Con sesión, `actionButtons` trae las acciones de me gusta y, si se puede, `createReplyParams` (forma de los
    /// `commentRenderer` de YouTube; no hay grabación con cuenta de esta parte).
    @Test func signedInActions() async throws {
        let json = #"""
        {"continuationContents": {"itemSectionContinuation": {"contents": [{"commentThreadRenderer": {"comment": {"commentRenderer": {
          "commentId": "C1", "authorText": {"simpleText": "@persona1"}, "contentText": {"runs": [{"text": "Hola"}]},
          "authorIsChannelOwner": true, "pinnedCommentBadge": {"pinnedCommentBadgeRenderer": {}},
          "actionButtons": {"commentActionButtonsRenderer": {
            "likeButton": {"toggleButtonRenderer": {"isToggled": true,
              "defaultServiceEndpoint": {"performCommentActionEndpoint": {"action": "LIKE_ACTION"}},
              "toggledServiceEndpoint": {"performCommentActionEndpoint": {"action": "UNLIKE_ACTION"}}}},
            "creatorHeart": {"creatorHeartRenderer": {"isHearted": true}},
            "replyButton": {"buttonRenderer": {"navigationEndpoint": {"createCommentReplyDialogEndpoint": {"dialog": {
              "commentReplyDialogRenderer": {"replyButton": {"buttonRenderer": {"serviceEndpoint": {
                "createCommentReplyEndpoint": {"createReplyParams": "REPLY_PARAMS"}}}}}}}}}}}}}}}}],
          "continuations": [{"nextContinuationData": {"continuation": "NEXT"}}]}}}
        """#
        let page = try await YouTubeService.parseComments(Data(json.utf8), replies: false)
        let comment = try #require(page.comments.first)
        #expect(comment.isLiked && comment.isPinned && comment.isHearted && comment.authorIsChannelOwner)
        #expect(comment.likeAction == "LIKE_ACTION")
        #expect(comment.unlikeAction == "UNLIKE_ACTION")
        #expect(comment.replyParams == "REPLY_PARAMS")
        #expect(page.continuation == "NEXT")
    }
}

@Suite struct LiveChatTests {
    @Test func recordedPage() throws {
        let data = try Fixture.data("comunidad/chat-tv.json")
        let update = try InnertubeDecoding.runSync { try LiveChatParser.update(data) }
        #expect(!update.messages.isEmpty)
        #expect(update.continuation != nil)
        #expect((update.timeoutMs ?? 0) > 0)
        #expect(!update.isReload)
        #expect(Set(update.messages.map(\.id)).count == update.messages.count)
        for message in update.messages {
            #expect(message.author.hasPrefix("@persona"))
            #expect(message.timestamp != nil)
            #expect(!message.text.isEmpty)
        }
    }

    @Test func superChatEmojisAndRemovals() throws {
        let json = #"""
        {"continuationContents": {"liveChatContinuation": {"actions": [
          {"addChatItemAction": {"item": {"liveChatTextMessageRenderer": {"id": "A", "authorName": {"simpleText": "@uno"},
            "message": {"runs": [{"text": "Hola "}, {"emoji": {"emojiId": "🚢", "shortcuts": [":ship:"]}},
              {"emoji": {"emojiId": "UCabc/xyz", "shortcuts": [":saludo:"], "isCustomEmoji": true}}]},
            "authorBadges": [{"liveChatAuthorBadgeRenderer": {"icon": {"iconType": "MODERATOR"}}}],
            "timestampUsec": "1792165489166283"}}}},
          {"addChatItemAction": {"item": {"liveChatPaidMessageRenderer": {"id": "B", "authorName": {"simpleText": "@dos"},
            "purchaseAmountText": {"simpleText": "MX$50.00"}, "bodyBackgroundColor": 4280191205,
            "message": {"runs": [{"text": "Gracias"}]}}}}},
          {"addChatItemAction": {"item": {"liveChatMembershipItemRenderer": {"id": "C", "authorName": {"simpleText": "@tres"},
            "headerSubtext": {"runs": [{"text": "¡Bienvenido!"}]}}}}},
          {"removeChatItemAction": {"targetItemId": "Z"}},
          {"addChatItemAction": {"item": {"liveChatPlaceholderItemRenderer": {"id": "P"}}}}],
         "continuations": [{"invalidationContinuationData": {"continuation": "NEXT", "timeoutMs": 10000}}]}}}
        """#
        let update = try InnertubeDecoding.runSync { try LiveChatParser.update(Data(json.utf8)) }
        #expect(update.messages.map(\.id) == ["A", "B", "C"])
        #expect(update.messages[0].text == "Hola 🚢:saludo:")
        #expect(update.messages[0].isModerator)
        #expect(update.messages[1].kind == .superChat && update.messages[1].amountText == "MX$50.00")
        #expect(update.messages[1].colorARGB == 4280191205)
        #expect(update.messages[2].kind == .membership && update.messages[2].text == "¡Bienvenido!")
        #expect(update.removedIds == ["Z"])
        #expect(update.continuation == "NEXT" && update.timeoutMs == 10000)
    }

    @Test func expiredTokenAsksForReload() throws {
        let json = #"{"continuationContents": {"liveChatContinuation": {"continuations": [{"reloadContinuationData": {"continuation": "R"}}]}}}"#
        let update = try InnertubeDecoding.runSync { try LiveChatParser.update(Data(json.utf8)) }
        #expect(update.isReload && update.continuation == "R" && update.messages.isEmpty)
    }
}

@Suite struct CommunityAPITests {
    @Test func deArrowPrefix() {
        // sha256("aqz-KE-bpKQ") empieza por 671e (como la consulta de SponsorBlock).
        #expect(DeArrowClient.prefix(for: "aqz-KE-bpKQ") == "671e")
    }

    @Test func deArrowRecorded() throws {
        let all = try DeArrowClient.parse(Fixture.data("comunidad/dearrow-671e.json"))
        let bunny = try #require(all["aqz-KE-bpKQ"])
        #expect(bunny.title == "Big Buck Bunny (2008) [60fps 4K]")
        #expect(bunny.thumbnailTime == nil && bunny.thumbnailURL == nil)
        #expect(all.count > 1)
    }

    @Test func deArrowSelection() throws {
        func branding(_ json: String) throws -> DeArrowBranding {
            try DeArrowClient.parseSingle(Data(json.utf8), videoId: "dtp6b76pMak")
        }
        // El mejor es un título de la comunidad: se quitan los ">" del formateador.
        let replaced = try branding(#"{"titles":[{"title":"Using the >Apple >Vision >Pro","original":false,"votes":1,"locked":true}],"thumbnails":[{"timestamp":1536.414019,"original":false,"votes":3,"locked":false}]}"#)
        #expect(replaced.title == "Using the Apple Vision Pro")
        #expect(replaced.thumbnailURL?.absoluteString == "https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=dtp6b76pMak&time=1536.414019")
        // El mejor es el original: no se cambia nada.
        let original = try branding(#"{"titles":[{"title":"Original","original":true,"votes":5},{"title":"Otro","original":false,"votes":2}],"thumbnails":[{"timestamp":10,"original":true,"votes":4}]}"#)
        #expect(original.isEmpty)
        // Votos negativos sin bloquear: se saltan.
        let negative = try branding(#"{"titles":[{"title":"Malo","original":false,"votes":-1,"locked":false},{"title":"Bueno","original":false,"votes":0}],"thumbnails":[]}"#)
        #expect(negative.title == "Bueno")
        #expect(try branding(#"{"titles":[],"thumbnails":[]}"#).isEmpty)
    }

    @Test func dislikesRecorded() throws {
        let votes = try DislikeClient.parse(Fixture.data("comunidad/dislikes-aqz-KE-bpKQ.json"), videoId: "aqz-KE-bpKQ")
        #expect(votes.likes > 0 && votes.dislikes > 0)
        #expect((0...1).contains(votes.likeRatio ?? -1))
        #expect(DislikeClient.compact(18_636, locale: Locale(identifier: "en_US")) == "19K")
    }
}
