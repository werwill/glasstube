import Foundation
import GlasstubeCore
import YTKit

// Lo que el reproductor y la vista previa de la Bandeja necesitan además del stream: descripción, capítulos (de /next,
// YTKit) y tramos de SponsorBlock (GlasstubeCore). Las dos peticiones van a la vez; si una falla, la otra sigue.

struct ChapterPayload: Encodable {
    var title: String
    var start: Double
}

struct SegmentPayload: Encodable {
    var start: Double
    var end: Double
    var category: String
    /// "Saltar patrocinio", "Saltar intro"…
    var title: String
}

struct DetailsPayload: Encodable {
    var videoId: String
    var title: String?
    var description: String?
    var author: String?
    var channelId: String?
    var avatar: String?
    var views: String?
    var published: String?
    var chapters: [ChapterPayload]
    var segments: [SegmentPayload]
}

/// Detalles de un video: {"videoId", "title", "description", "author", "channelId", "avatar", "views", "published",
/// "chapters": [{"title", "start"}], "segments": [{"start", "end", "category", "title"}]} (segundos).
@_cdecl("gt_video_details")
public func gt_video_details(_ videoId: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let videoId = string(videoId) else { return reply.fail("falta el videoId") }
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            let sponsorBlock = Library.shared.sponsorBlock
            async let segments = sponsorBlock.segments(videoId: videoId)
            var metadata: MediaItemMetadata?
            do { metadata = try await MetadataCache.metadata(videoId: videoId, service: engine.service) } catch {
                log("detalles de \(videoId): \(error)")
            }
            let found = await segments
            reply.ok(DetailsPayload(
                videoId: videoId, title: metadata?.title, description: metadata?.description, author: metadata?.author,
                channelId: metadata?.channelId,
                avatar: metadata?.authorThumbnails.best(forWidth: 88).map { absolute($0.url) },
                views: metadata?.viewCountText, published: metadata?.publishedDate ?? metadata?.relativeDate,
                chapters: (metadata?.chapters ?? []).map { ChapterPayload(title: $0.title, start: Double($0.startMs) / 1000) },
                segments: found.map { SegmentPayload(start: $0.start, end: $0.end, category: $0.category, title: $0.skipTitle) }))
        } catch {
            reply.fail(error)
        }
    }
}
