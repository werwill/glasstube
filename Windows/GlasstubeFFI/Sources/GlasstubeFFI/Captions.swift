import Foundation
import GlasstubeCore
import YTKit

// Subtítulos: las `captionTracks` del `/player` de VISIONOS (PlayerExtrasService de GlasstubeCore), que se descargan sin
// PoToken. La app las carga en mpv con `sub-add` en WebVTT.

struct CaptionPayload: Encodable {
    var languageCode: String
    var name: String
    /// "Español (automáticos)" para los automáticos.
    var title: String
    var isAutomatic: Bool
    /// WebVTT (`&fmt=vtt`).
    var url: String
}

struct CaptionsPayload: Encodable {
    var videoId: String
    var tracks: [CaptionPayload]
}

@MainActor var playerExtras: PlayerExtrasService?

/// Pistas de subtítulos: {"videoId", "tracks": [{"languageCode", "name", "title", "isAutomatic", "url"}]}. Sin
/// subtítulos, `tracks` vacío.
@_cdecl("gt_captions")
public func gt_captions(_ videoId: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let videoId = string(videoId) else { return reply.fail("falta el videoId") }
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            let service = playerExtras ?? PlayerExtrasService(catalog: engine.service.catalog)
            playerExtras = service
            let extras = try await service.extras(videoId: videoId)
            let tracks = extras.captions.compactMap { track in
                track.vttURL.map {
                    CaptionPayload(languageCode: track.languageCode, name: track.name, title: track.title,
                                   isAutomatic: track.isAutomatic, url: $0.absoluteString)
                }
            }
            log("subtítulos de \(videoId): \(tracks.count) pistas")
            reply.ok(CaptionsPayload(videoId: videoId, tracks: tracks))
        } catch {
            log("subtítulos de \(videoId): \(error)")
            reply.fail(error)
        }
    }
}
