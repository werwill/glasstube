import Foundation
import YTKit

// Calidad y pista de audio del reproductor: las alturas que trae el cliente elegido (sus formatos ya resueltos, los de
// `formatInfo`) y, en videos doblados, sus pistas de audio. La app re-resuelve con la altura máxima o la pista elegida
// (`gt_resolve_stream_with`) y recarga mpv donde iba.

struct QualityOption: Encodable {
    var height: Int
    var fps: Int?
    /// "1080p60", "720p".
    var label: String
}

struct AudioTrackOption: Encodable {
    var id: String
    /// "Español (Latinoamérica)", "English (United States) original".
    var name: String
    var isDefault: Bool
}

/// Alturas con URL del cliente elegido, de mayor a menor (sin HDR, como la selección), con los fps más altos de cada una.
func qualityOptions(in attempt: ClientAttempt) -> [QualityOption] {
    var best: [Int: Int] = [:]
    for format in attempt.formats where format.kind == .video && format.url != nil && !format.isHDR {
        guard let height = format.height, height > 0 else { continue }
        best[height] = max(best[height] ?? 0, format.fps ?? 0)
    }
    return best.keys.sorted(by: >).map { height in
        let fps = best[height] ?? 0
        return QualityOption(height: height, fps: fps > 0 ? fps : nil, label: fps > 32 ? "\(height)p\(fps)" : "\(height)p")
    }
}

/// Pistas de audio distintas (doblajes y la original). Vacío si solo hay una.
func audioTrackOptions(in attempt: ClientAttempt) -> [AudioTrackOption] {
    var seen: Set<String> = []
    var tracks: [AudioTrackOption] = []
    for format in attempt.formats where format.kind == .audio && format.url != nil {
        guard let id = format.audioTrackId, seen.insert(id).inserted else { continue }
        tracks.append(AudioTrackOption(id: id, name: format.audioTrack ?? id, isDefault: format.isDefaultAudio))
    }
    guard tracks.count > 1 else { return [] }
    // La predeterminada (la original) primero; las demás, por nombre.
    return tracks.sorted { a, b in a.isDefault != b.isDefault ? a.isDefault : a.name < b.name }
}

/// El mejor audio de la pista `trackId` (nil si no se pidió o no existe en este cliente).
func audioFormat(in attempt: ClientAttempt, trackId: String?) -> StreamFormat? {
    guard let trackId else { return nil }
    return TrackSelector.bestAudio(attempt.formats.filter { $0.audioTrackId == trackId })
}

/// Como `gt_resolve_stream`, con la pista de audio `audio_track_id` (de `audioTracks`; NULL = la predeterminada).
@_cdecl("gt_resolve_stream_with")
public func gt_resolve_stream_with(_ videoId: UnsafePointer<CChar>?, _ maxHeight: Int32, _ audioTrackId: UnsafePointer<CChar>?,
                                   _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let videoId = string(videoId) else { return reply.fail("falta el videoId") }
    let audioTrackId = string(audioTrackId)
    Task { @MainActor in await resolveStream(videoId: videoId, maxHeight: maxHeight, audioTrackId: audioTrackId, reply: reply) }
}
