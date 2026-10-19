import Foundation

// Chat en vivo: `live_chat/get_live_chat` con `continuation` (`LiveChatServiceInt` de SmartTube), por la interfaz de TV
// (`createQueryTV`). El primer token sale del `next` (`conversationBar.liveChatRenderer`, en TV y en WEB; el de WEB
// también vale con TV). Cada respuesta trae los mensajes nuevos (`actions`) y el token siguiente con su espera
// (`timedContinuationData` o `invalidationContinuationData`, ~5 s); si el token vence, YouTube manda
// `reloadContinuationData` sin mensajes, o HTTP 400 si se usa uno viejo. Comprobado el 16-oct-2026 con un directo
// público de noticias.

/// Un mensaje del chat (`ChatItem` de SmartTube, más Super Chat, membresías y avisos del sistema).
public struct LiveChatMessage: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case text, superChat, superSticker, membership, system
    }

    public var id: String
    public var kind: Kind
    public var author: String
    public var authorChannelId: String?
    public var authorPhotos: [Thumbnail] = []
    /// Texto con los emojis de Unicode y los propios del canal como `:atajo:`.
    public var text: String
    public var timestamp: Date?
    /// Super Chat: "MX$50.00".
    public var amountText: String?
    /// Color del Super Chat (ARGB de YouTube).
    public var colorARGB: UInt32?
    public var isOwner = false
    public var isModerator = false
    public var isMember = false
    public var isVerified = false

    public init(id: String, kind: Kind, author: String, text: String) {
        self.id = id
        self.kind = kind
        self.author = author
        self.text = text
    }
}

/// Lo que trae una petición del chat: mensajes nuevos, los borrados y cómo seguir.
public struct LiveChatUpdate: Sendable {
    public var messages: [LiveChatMessage]
    /// Mensajes que el canal o YouTube quitaron (`removeChatItemAction`, `markChatItemAsDeletedAction`).
    public var removedIds: [String]
    public var continuation: String?
    /// Espera antes de pedir el siguiente (YouTube sugiere ~5 s).
    public var timeoutMs: Int?
    /// El token venció y hay que volver a pedir con este (sin mensajes).
    public var isReload: Bool

    public init(messages: [LiveChatMessage] = [], removedIds: [String] = [], continuation: String? = nil, timeoutMs: Int? = nil,
                isReload: Bool = false) {
        self.messages = messages
        self.removedIds = removedIds
        self.continuation = continuation
        self.timeoutMs = timeoutMs
        self.isReload = isReload
    }
}

/// Chat en vivo de un directo (`LiveChatService` de SmartTube).
public protocol LiveChatService: Sendable {
    /// Una petición: `MediaItemMetadata.liveChatContinuation` o `LiveChatUpdate.continuation`.
    func liveChat(_ continuation: String) async throws -> LiveChatUpdate
    /// Sondeo continuo desde el token del `next`, como `openLiveChat` de SmartTube: espera lo que pide YouTube entre
    /// peticiones y, si el token vence o falla la red, vuelve a empezar con el token inicial. Se detiene al cancelar la
    /// tarea que lo recorre.
    func liveChatUpdates(_ continuation: String) -> AsyncThrowingStream<LiveChatUpdate, Error>
}

// MARK: - Respuesta

struct LiveChatResponse: Decodable, Sendable {
    struct ContinuationContents: Decodable, Sendable {
        struct Chat: Decodable, Sendable {
            @Lenient var continuations: [ChatContinuation]?
            @Lenient var actions: [ChatAction]?
        }
        @Lenient var liveChatContinuation: Chat?
    }
    @Lenient var continuationContents: ContinuationContents?
}

struct ChatContinuation: Decodable, Sendable {
    struct Data: Decodable, Sendable {
        @Lenient var continuation: String?
        @Lenient var timeoutMs: FlexibleInt?
    }
    @Lenient var timedContinuationData: Data?
    @Lenient var invalidationContinuationData: Data?
    @Lenient var reloadContinuationData: Data?
    @Lenient var liveChatReplayContinuationData: Data?
}

struct ChatAction: Decodable, Sendable {
    struct Add: Decodable, Sendable { @Lenient var item: ChatItem? }
    struct Target: Decodable, Sendable { @Lenient var targetItemId: String? }
    struct Replace: Decodable, Sendable {
        @Lenient var targetItemId: String?
        @Lenient var replacementItem: ChatItem?
    }
    struct Banner: Decodable, Sendable {
        struct Renderer: Decodable, Sendable {
            struct Inner: Decodable, Sendable {
                @Lenient var contents: ChatItem?
            }
            @Lenient var liveChatBannerRenderer: Inner?
        }
        @Lenient var bannerRenderer: Renderer?
    }
    @Lenient var addChatItemAction: Add?
    @Lenient var removeChatItemAction: Target?
    @Lenient var markChatItemAsDeletedAction: Target?
    @Lenient var replaceChatItemAction: Replace?
    @Lenient var addBannerToLiveChatCommand: Banner?
}

struct ChatItem: Decodable, Sendable {
    @Lenient var liveChatTextMessageRenderer: ChatMessageRenderer?
    @Lenient var liveChatPaidMessageRenderer: ChatMessageRenderer?
    @Lenient var liveChatPaidStickerRenderer: ChatMessageRenderer?
    @Lenient var liveChatMembershipItemRenderer: ChatMessageRenderer?
    @Lenient var liveChatViewerEngagementMessageRenderer: ChatMessageRenderer?
}

struct ChatMessageRenderer: Decodable, Sendable {
    struct Badge: Decodable, Sendable {
        struct Renderer: Decodable, Sendable {
            struct Icon: Decodable, Sendable { @Lenient var iconType: String? }
            @Lenient var icon: Icon?
            @Lenient var customThumbnail: ThumbnailList?
            @Lenient var tooltip: String?
        }
        @Lenient var liveChatAuthorBadgeRenderer: Renderer?
    }
    @Lenient var id: String?
    @Lenient var message: ChatText?
    @Lenient var headerSubtext: ChatText?
    @Lenient var authorName: YTText?
    @Lenient var authorPhoto: ThumbnailList?
    @Lenient var authorExternalChannelId: String?
    @Lenient var authorBadges: [Badge]?
    @Lenient var timestampUsec: String?
    @Lenient var purchaseAmountText: YTText?
    @Lenient var bodyBackgroundColor: FlexibleUInt32?
    @Lenient var backgroundColor: FlexibleUInt32?
}

/// Texto del chat: como `YTText`, pero con los emojis (`runs[].emoji`), que en los mensajes van aparte del texto.
struct ChatText: Decodable, Sendable {
    struct Run: Decodable, Sendable {
        struct Emoji: Decodable, Sendable {
            @Lenient var emojiId: String?
            @Lenient var shortcuts: [String]?
            @Lenient var isCustomEmoji: Bool?
        }
        @Lenient var text: String?
        @Lenient var emoji: Emoji?
    }
    @Lenient var runs: [Run]?
    @Lenient var simpleText: String?

    var string: String {
        if let simpleText { return simpleText }
        return (runs ?? []).map { run in
            if let text = run.text { return text }
            guard let emoji = run.emoji else { return "" }
            // Los de Unicode traen el carácter como id; los del canal, un id opaco y su atajo (":hola:").
            if emoji.isCustomEmoji != true, let id = emoji.emojiId, !id.contains("/") { return id }
            return emoji.shortcuts?.first ?? emoji.emojiId ?? ""
        }.joined()
    }
}

/// Entero sin signo de 32 bits que llega como número o como cadena (los colores ARGB de YouTube).
struct FlexibleUInt32: Decodable, Sendable {
    let value: UInt32

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(UInt32.self) {
            value = int
        } else if let int64 = try? container.decode(Int64.self) {
            value = UInt32(truncatingIfNeeded: int64)
        } else if let string = try? container.decode(String.self), let int = UInt32(string) {
            value = int
        } else {
            throw DecodingError.typeMismatch(UInt32.self, .init(codingPath: decoder.codingPath, debugDescription: "no es un color"))
        }
    }
}

enum LiveChatParser {
    static func update(_ data: Data) throws -> LiveChatUpdate {
        let response = try JSONDecoder().decode(LiveChatResponse.self, from: data)
        guard let chat = response.continuationContents?.liveChatContinuation else {
            throw YTKitError.badResponse("la respuesta del chat no trae liveChatContinuation")
        }
        var update = LiveChatUpdate()
        for action in chat.actions ?? [] {
            if let item = action.addChatItemAction?.item ?? action.addBannerToLiveChatCommand?.bannerRenderer?.liveChatBannerRenderer?.contents,
               let message = message(from: item) {
                update.messages.append(message)
            } else if let id = action.removeChatItemAction?.targetItemId ?? action.markChatItemAsDeletedAction?.targetItemId {
                update.removedIds.append(id)
            } else if let replace = action.replaceChatItemAction, let item = replace.replacementItem, let message = message(from: item) {
                if let id = replace.targetItemId, id != message.id { update.removedIds.append(id) }
                update.messages.append(message)
            }
        }
        if let first = chat.continuations?.first {
            if let reload = first.reloadContinuationData {
                update.continuation = reload.continuation
                update.isReload = true
            } else {
                let data = first.timedContinuationData ?? first.invalidationContinuationData ?? first.liveChatReplayContinuationData
                update.continuation = data?.continuation
                update.timeoutMs = data?.timeoutMs?.value
            }
        }
        return update
    }

    static func message(from item: ChatItem) -> LiveChatMessage? {
        let pairs: [(ChatMessageRenderer?, LiveChatMessage.Kind)] = [
            (item.liveChatTextMessageRenderer, .text), (item.liveChatPaidMessageRenderer, .superChat),
            (item.liveChatPaidStickerRenderer, .superSticker), (item.liveChatMembershipItemRenderer, .membership),
            (item.liveChatViewerEngagementMessageRenderer, .system),
        ]
        guard let (renderer, kind) = pairs.first(where: { $0.0 != nil }), let r = renderer, let id = r.id else { return nil }
        let text = r.message?.string ?? r.headerSubtext?.string ?? ""
        guard !text.isEmpty || kind != .text else { return nil }
        var message = LiveChatMessage(id: id, kind: kind, author: r.authorName?.string ?? "", text: text)
        message.authorChannelId = r.authorExternalChannelId
        message.authorPhotos = Convert.thumbnails(r.authorPhoto)
        if let usec = r.timestampUsec.flatMap(Double.init) { message.timestamp = Date(timeIntervalSince1970: usec / 1_000_000) }
        message.amountText = r.purchaseAmountText?.string
        message.colorARGB = (r.bodyBackgroundColor ?? r.backgroundColor)?.value
        for badge in r.authorBadges ?? [] {
            guard let renderer = badge.liveChatAuthorBadgeRenderer else { continue }
            switch renderer.icon?.iconType {
            case "OWNER": message.isOwner = true
            case "MODERATOR": message.isModerator = true
            case "VERIFIED": message.isVerified = true
            default: if renderer.customThumbnail != nil { message.isMember = true }
            }
        }
        return message
    }
}

extension YouTubeService: LiveChatService {
    public func liveChat(_ continuation: String) async throws -> LiveChatUpdate {
        let data = try await api.post("live_chat/get_live_chat", surface: .tv, ["continuation": continuation])
        return try await Self.parseLiveChat(data)
    }

    /// Convierte una respuesta cruda del chat (pruebas y diagnóstico).
    public static func parseLiveChat(_ data: Data) async throws -> LiveChatUpdate {
        try await InnertubeDecoding.run { try LiveChatParser.update(data) }
    }

    public func liveChatUpdates(_ continuation: String) -> AsyncThrowingStream<LiveChatUpdate, Error> {
        AsyncThrowingStream { stream in
            let task = Task {
                var token = continuation
                var failures = 0
                var seen = Set<String>()
                while !Task.isCancelled {
                    do {
                        var update = try await self.liveChat(token)
                        failures = 0
                        // Al volver a empezar, YouTube repite los últimos mensajes.
                        update.messages = update.messages.filter { seen.insert($0.id).inserted }
                        if seen.count > 5000 { seen = Set(update.messages.map(\.id)) }
                        if !update.messages.isEmpty || !update.removedIds.isEmpty { stream.yield(update) }
                        if let next = update.continuation {
                            token = next
                        } else {
                            // Sin token: el directo terminó o el chat se cerró.
                            break
                        }
                        let wait = update.isReload ? 1000 : min(10_000, max(1000, update.timeoutMs ?? 5000))
                        try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
                    } catch is CancellationError {
                        break
                    } catch {
                        // Token vencido (400) o red: se vuelve a empezar con el del `next`, como SmartTube.
                        failures += 1
                        guard failures < 6 else {
                            stream.finish(throwing: error)
                            return
                        }
                        token = continuation
                        Log.debug("chat: \(error); reintento \(failures) en 5 s")
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                }
                stream.finish()
            }
            stream.onTermination = { _ in task.cancel() }
        }
    }
}
