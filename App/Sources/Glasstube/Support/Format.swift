import Foundation
import PlaybackKit
import YTKit

enum Format {
    /// 8:30, 1:04:21.
    static func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 1,25× (separador decimal del idioma).
    static func rate(_ rate: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return (formatter.string(from: NSNumber(value: rate)) ?? "\(rate)") + "×"
    }

    /// "1080p60" para una calidad de video, con el criterio de YouTube: la altura equivalente en 16:9 (un video 2:1
    /// de 3840×1920 es "2160p", no "1920p"; uno vertical de 1080×1920, "1080p").
    static func quality(width: Int?, height: Int?, fps: Double?) -> String {
        guard let height else { return String(localized: "Auto") }
        let fpsText = (fps ?? 0) > 30 ? String(Int((fps ?? 0).rounded())) : ""
        return "\(qualityClass(width: width, height: height))p\(fpsText)"
    }

    static func quality(_ track: MediaTrack) -> String {
        quality(width: track.width, height: track.height, fps: track.fps)
    }

    static func qualityClass(width: Int?, height: Int) -> Int {
        let short = min(width ?? height, height), long = max(width ?? height, height)
        let equivalent = max(short, Int((Double(long) * 9 / 16).rounded()))
        let classes = [144, 240, 360, 480, 720, 1080, 1440, 2160, 4320]
        return classes.min { abs($0 - equivalent) < abs($1 - equivalent) } ?? equivalent
    }
}

extension Error {
    /// Cancelación de la tarea o de su petición. URLSession la informa como `URLError.cancelled` y no como
    /// `CancellationError`: al recargar una página (p. ej. cuando aparece la sesión) la petición vieja no es un error.
    var isCancellation: Bool { self is CancellationError || (self as? URLError)?.code == .cancelled }
}

extension BrowsePage {
    /// YTKit no sabe del idioma de la interfaz y pone en español los pocos títulos que YouTube no da: «Resultados» en la
    /// búsqueda, «Más recientes» en Suscripciones (el mismo título que las tandas que llegan al bajar, ver
    /// `mergingUntitledRows`) y los nombres de las páginas. Aquí van en el idioma de la app. Solo para esas páginas: en un
    /// canal o una playlist, el título es de quien lo creó.
    var localizingFixedTitles: BrowsePage {
        func localized(_ title: String?) -> String? {
            switch title {
            case "Resultados": String(localized: "Resultados")
            case "Más recientes": String(localized: "Más recientes")
            case "Inicio": String(localized: "Inicio")
            case "Suscripciones": String(localized: "Suscripciones")
            case "Historial": String(localized: "Historial")
            default: title
            }
        }
        var copy = self
        copy.title = localized(copy.title)
        for index in copy.groups.indices { copy.groups[index].title = localized(copy.groups[index].title) }
        return copy
    }
}

extension MediaItem {
    /// Segunda línea de la tarjeta: "Canal · 1,2 M vistas · hace 2 días".
    var cardSubtitle: String {
        switch kind {
        case .video:
            let parts = [author, viewCountText, publishedText].compactMap { $0 }.filter { !$0.isEmpty }
            if parts.count > 1 { return parts.joined(separator: " · ") }
            return metadataLines.isEmpty ? parts.joined(separator: " · ") : metadataLines.joined(separator: " · ")
        case .channel:
            return [handle, subscriberCountText].compactMap { $0 }.joined(separator: " · ")
        case .playlist, .mix:
            return metadataLines.first ?? [author, videoCountText].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Duración para el distintivo de la miniatura.
    var durationBadge: String? {
        if isLive { return String(localized: "EN VIVO") }
        if let durationText, !durationText.isEmpty { return durationText }
        if let durationSeconds { return Format.time(Double(durationSeconds)) }
        if kind == .playlist || kind == .mix { return videoCountText }
        return nil
    }

    var isPlayable: Bool { videoId != nil && (kind == .video || kind == .mix) }
}
