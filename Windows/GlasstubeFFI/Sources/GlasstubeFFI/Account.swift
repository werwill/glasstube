import Foundation
import YTKit

// La cuenta en el reproductor: estado de «me gusta» y de la suscripción al canal (YTKit, `next` de TV con la cuenta),
// los votos de Return YouTube Dislike, y las acciones me gusta / no me gusta / suscribirse (ActionsApi de YTKit).

// MARK: - Metadatos compartidos

/// `/next` de un video, compartido por detalles, sugeridos y cuenta (el reproductor los pide a la vez): una sola
/// petición por video, guardada un rato. Las acciones de la cuenta la invalidan.
@MainActor
enum MetadataCache {
    private static var entries: [String: (task: Task<MediaItemMetadata, Error>, at: Date)] = [:]

    static func metadata(videoId: String, service: YouTubeService) async throws -> MediaItemMetadata {
        if let entry = entries[videoId], Date().timeIntervalSince(entry.at) < 120 { return try await entry.task.value }
        let task = Task { try await service.metadata(videoId: videoId) }
        entries[videoId] = (task, Date())
        if entries.count > 30, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key { entries[oldest] = nil }
        do {
            return try await task.value
        } catch {
            entries[videoId] = nil
            throw error
        }
    }

    static func invalidate(_ videoId: String) { entries[videoId] = nil }

    static func invalidateAll() { entries = [:] }
}

// MARK: - Estado de la cuenta en un video

struct VideoAccountPayload: Encodable {
    var videoId: String
    var signedIn: Bool
    /// "like", "dislike", "indifferent"; nil sin sesión o si YouTube no lo dio.
    var likeStatus: String?
    var isSubscribed: Bool?
    var subscribeParams: String?
    var channelId: String?
    var channel: String?
    var channelAvatar: String?
    var subscribers: String?
    /// "1.2 K" de YouTube.
    var likeCountText: String?
    /// Return YouTube Dislike (estimados); nil si su API no respondió.
    var likes: Int?
    var dislikes: Int?
}

/// Estado de la cuenta en un video: {"videoId", "signedIn", "likeStatus", "isSubscribed", "subscribeParams", "channelId",
/// "channel", "channelAvatar", "subscribers", "likeCountText", "likes", "dislikes"}.
@_cdecl("gt_video_account")
public func gt_video_account(_ videoId: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let videoId = string(videoId) else { return reply.fail("falta el videoId") }
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            async let votes = try? DislikeClient.shared.votes(videoId: videoId)
            let metadata = try await MetadataCache.metadata(videoId: videoId, service: engine.service)
            let found = await votes
            if engine.session.knownSignedIn == nil { _ = try? await engine.session.load() }
            let signedIn = engine.session.knownSignedIn ?? false
            log("cuenta en \(videoId): sesión \(signedIn), me gusta \(metadata.likeStatus?.rawValue ?? "-"), suscrito \(metadata.isSubscribed.map(String.init) ?? "-"), RYD \(found.map { "\($0.likes)/\($0.dislikes)" } ?? "sin datos")")
            reply.ok(VideoAccountPayload(
                videoId: videoId, signedIn: signedIn, likeStatus: signedIn ? metadata.likeStatus?.rawValue : nil,
                isSubscribed: signedIn ? metadata.isSubscribed : nil, subscribeParams: metadata.subscribeParams,
                channelId: metadata.channelId, channel: metadata.author,
                channelAvatar: metadata.authorThumbnails.best(forWidth: 88).map { absolute($0.url) },
                subscribers: metadata.subscriberCountText, likeCountText: metadata.likeCountText,
                likes: found?.likes, dislikes: found?.dislikes))
        } catch {
            log("cuenta en \(videoId): \(error)")
            reply.fail(error)
        }
    }
}

// MARK: - Acciones

/// Me gusta: `status` 1 = me gusta, -1 = no me gusta, 0 = ninguno; `previous` es el que había (para quitarlo).
/// Responde {"likeStatus"}.
@_cdecl("gt_set_like")
public func gt_set_like(_ videoId: UnsafePointer<CChar>?, _ status: Int32, _ previous: Int32, _ callback: GTCallback,
                        _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let videoId = string(videoId) else { return reply.fail("falta el videoId") }
    Task { @MainActor in
        do {
            let service = try Engine.require().service
            switch status {
            case 1: try await service.setLike(videoId: videoId)
            case -1: try await service.setDislike(videoId: videoId)
            default:
                if previous == 1 { try await service.removeLike(videoId: videoId) }
                if previous == -1 { try await service.removeDislike(videoId: videoId) }
            }
            MetadataCache.invalidate(videoId)
            let value = status == 1 ? "like" : status == -1 ? "dislike" : "indifferent"
            log("me gusta en \(videoId): \(value)")
            reply.ok(["likeStatus": value])
        } catch {
            log("me gusta en \(videoId): \(error)")
            reply.fail(error)
        }
    }
}

/// Suscribirse (`subscribe` 1) o anular la suscripción (0) a un canal. `params` es el `subscribeParams` del video o del
/// canal (puede ser NULL). Responde {"isSubscribed"}.
@_cdecl("gt_subscribe")
public func gt_subscribe(_ channelId: UnsafePointer<CChar>?, _ subscribe: Int32, _ params: UnsafePointer<CChar>?,
                         _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let channelId = string(channelId) else { return reply.fail("falta el canal") }
    let params = string(params)
    Task { @MainActor in
        do {
            let service = try Engine.require().service
            if subscribe != 0 {
                try await service.subscribe(channelId: channelId, params: params)
            } else {
                try await service.unsubscribe(channelId: channelId)
            }
            log("suscripción a \(channelId): \(subscribe != 0)")
            reply.ok(["isSubscribed": subscribe != 0])
        } catch {
            log("suscripción a \(channelId): \(error)")
            reply.fail(error)
        }
    }
}

/// Si la cuenta está suscrita a un canal: {"signedIn", "isSubscribed", "params"} (`isSubscribed` nil sin sesión).
@_cdecl("gt_subscription_state")
public func gt_subscription_state(_ channelId: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let channelId = string(channelId) else { return reply.fail("falta el canal") }
    Task { @MainActor in
        struct Payload: Encodable {
            var signedIn: Bool
            var isSubscribed: Bool?
            var params: String?
        }
        do {
            let engine = try Engine.require()
            if engine.session.knownSignedIn == nil { _ = try? await engine.session.load() }
            guard engine.session.knownSignedIn ?? false else { return reply.ok(Payload(signedIn: false)) }
            let state = try await engine.service.subscriptionState(channelId: channelId)
            reply.ok(Payload(signedIn: true, isSubscribed: state?.isSubscribed, params: state?.params))
        } catch {
            log("suscripción a \(channelId) (estado): \(error)")
            reply.fail(error)
        }
    }
}
