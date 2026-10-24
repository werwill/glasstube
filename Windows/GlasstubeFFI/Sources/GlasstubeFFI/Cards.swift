import Foundation
import GlasstubeCore
import YTKit

// Tarjetas de video para la interfaz: de un MediaItem de YTKit (feeds) o de lo guardado en la biblioteca local, con la
// posición guardada y una fecha aproximada para ordenar y agrupar por día.

extension VideoCard {
    /// Tarjeta de un video de un feed, con la posición que haya en la biblioteca local.
    @MainActor
    init(_ item: MediaItem, shelf: String?, avatar: String? = nil) {
        let id = item.videoId ?? item.id
        let thumbnail = item.thumbnails.best(forWidth: 480) ?? item.standardThumbnails.dropFirst().first
        self.init(
            id: id, title: item.title, channel: item.author, channelId: item.channelId,
            thumbnail: thumbnail.map { absolute($0.url) }, duration: item.durationBadge,
            views: item.viewCountText, published: item.publishedText, subtitle: item.cardSubtitle,
            isLive: item.isLive, shelf: shelf)
        // maxresdefault no existe en todos los videos: la interfaz cae a `thumbnail` si no carga.
        thumbnailLarge = item.standardThumbnails.last.map { absolute($0.url) } ?? self.thumbnail
        self.avatar = avatar ?? item.authorThumbnails.best(forWidth: 88).map { absolute($0.url) }
        durationSeconds = item.durationSeconds ?? item.durationText.flatMap(Self.seconds)
        publishedAt = (item.publishedAt ?? item.publishedText.flatMap { RelativeDate.parse($0) })?.timeIntervalSince1970
        applySavedPosition()
    }

    /// Tarjeta de algo guardado (historial o Ver más tarde).
    @MainActor
    init(saved: SavedVideo) {
        self.init(saved.item, shelf: nil)
        position = saved.position
        progress = saved.fraction
        if durationSeconds == nil, let duration = saved.duration { durationSeconds = Int(duration) }
    }

    @MainActor
    mutating func applySavedPosition() {
        guard let saved = Library.shared.local.savedPosition(for: id) else { return }
        position = saved.position
        progress = saved.fraction
    }

    /// El MediaItem que guarda la biblioteca local.
    var mediaItem: MediaItem {
        var item = MediaItem(kind: .video, title: title, renderer: "glasstube")
        item.videoId = id
        item.channelId = channelId
        item.author = channel
        item.viewCountText = views
        item.publishedText = published
        item.durationText = isLive ? nil : duration
        item.durationSeconds = durationSeconds
        item.isLive = isLive
        item.publishedAt = publishedAt.map { Date(timeIntervalSince1970: $0) }
        if let thumbnail { item.thumbnails = [Thumbnail(url: thumbnail, width: 480, height: 270)] }
        if let avatar { item.authorThumbnails = [Thumbnail(url: avatar, width: 88, height: 88)] }
        return item
    }

    /// "1:04:21" → 3861.
    static func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
    }
}

/// Fecha aproximada a partir del texto relativo de YouTube ("hace 3 horas", "Transmitido hace 2 días",
/// "41 minutes ago"). Innertube no da la fecha exacta en los feeds; basta para ordenar y agrupar por día.
enum RelativeDate {
    private static let units: [(String, Double)] = [
        ("segund", 1), ("second", 1), ("minut", 60), ("hora", 3600), ("hour", 3600), ("día", 86400), ("dia", 86400),
        ("day", 86400), ("semana", 604_800), ("week", 604_800), ("mes", 2_592_000), ("month", 2_592_000),
        ("año", 31_536_000), ("ano", 31_536_000), ("year", 31_536_000),
    ]

    static func parse(_ text: String, now: Date = Date()) -> Date? {
        let lower = text.lowercased()
        let scanner = Scanner(string: lower)
        scanner.charactersToBeSkipped = CharacterSet.decimalDigits.inverted
        guard let number = scanner.scanInt() else {
            // "hace un día", "an hour ago"
            return units.first { lower.contains($0.0) }.map { now.addingTimeInterval(-$0.1) }
        }
        let rest = lower[scanner.currentIndex...]
        guard let unit = units.first(where: { rest.contains($0.0) }) else { return nil }
        return now.addingTimeInterval(-Double(number) * unit.1)
    }
}

// MARK: - Biblioteca local

/// Estado de la Bandeja de Suscripciones por video: visto y archivado. Va aparte de LocalLibrary (que comparte la app
/// de Mac) en %LOCALAPPDATA%\Glasstube\inbox.json.
struct InboxState: Codable {
    var seen: Set<String> = []
    var archived: Set<String> = []
}

@MainActor
final class Library {
    static let shared = Library()

    let local = LocalLibrary()
    let groups = ChannelGroupStore()
    let sponsorBlock = SponsorBlockClient()
    private(set) var inbox = InboxState()

    private let inboxURL: URL = {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Glasstube").appendingPathComponent("inbox.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: inboxURL), let state = try? JSONDecoder().decode(InboxState.self, from: data) {
            inbox = state
        }
    }

    func setInbox(_ videoId: String, seen: Bool?, archived: Bool?) {
        if let seen { if seen { inbox.seen.insert(videoId) } else { inbox.seen.remove(videoId) } }
        if let archived { if archived { inbox.archived.insert(videoId) } else { inbox.archived.remove(videoId) } }
        do {
            try FileManager.default.createDirectory(at: inboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(inbox).write(to: inboxURL, options: .atomic)
        } catch {
            log("no se pudo guardar inbox.json: \(error)")
        }
    }
}

struct LibraryPayload: Encodable {
    var history: [VideoCard]
    /// Empezados y sin terminar (entre el 2 % y el 95 %), para "Continuar viendo".
    var continueWatching: [VideoCard]
    var watchLater: [VideoCard]
    var seen: [String]
    var archived: [String]
}

/// Biblioteca local: historial con posiciones, Ver más tarde y el estado de la Bandeja.
@_cdecl("gt_library")
public func gt_library(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        let library = Library.shared
        reply.ok(LibraryPayload(
            history: library.local.history.map { VideoCard(saved: $0) },
            continueWatching: library.local.continueWatching.map { VideoCard(saved: $0) },
            watchLater: library.local.watchLater.map { VideoCard(saved: $0) },
            seen: Array(library.inbox.seen), archived: Array(library.inbox.archived)))
    }
}

func decodeCard(_ json: UnsafePointer<CChar>?) -> VideoCard? {
    guard let json = string(json) else { return nil }
    return try? JSONDecoder().decode(VideoCard.self, from: Data(json.utf8))
}

/// Guarda la posición de un video (`card` es una VideoCard en JSON). Responde {}.
@_cdecl("gt_library_record")
public func gt_library_record(_ card: UnsafePointer<CChar>?, _ position: Double, _ duration: Double,
                              _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let card = decodeCard(card) else { return reply.fail("tarjeta inválida") }
    Task { @MainActor in
        Library.shared.local.recordPlayback(of: card.mediaItem, position: max(0, position), duration: duration > 0 ? duration : nil)
        reply.ok([String: String]())
    }
}

/// Escribe la biblioteca en disco ya (al cerrar el reproductor o la app). Responde {}.
@_cdecl("gt_library_save")
public func gt_library_save(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        Library.shared.local.saveNow()
        reply.ok([String: String]())
    }
}

/// Posición guardada de un video: {"position", "duration"} (0 si no hay).
@_cdecl("gt_saved_position")
public func gt_saved_position(_ videoId: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let videoId = string(videoId) else { return reply.fail("falta el videoId") }
    Task { @MainActor in
        let saved = Library.shared.local.savedPosition(for: videoId)
        reply.ok(["position": saved?.position ?? 0, "duration": saved?.duration ?? 0])
    }
}

/// Pone o quita un video de Ver más tarde (local). Responde {"inWatchLater"}.
@_cdecl("gt_watch_later_toggle")
public func gt_watch_later_toggle(_ card: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let card = decodeCard(card) else { return reply.fail("tarjeta inválida") }
    Task { @MainActor in
        let library = Library.shared.local
        let item = card.mediaItem
        library.toggleWatchLater(item)
        reply.ok(["inWatchLater": library.isInWatchLater(item)])
    }
}

/// Estado de un video en la Bandeja: `seen` y `archived` son 1 (sí), 0 (no) o -1 (no cambiar). Responde
/// {"seen", "archived"}.
@_cdecl("gt_inbox_set")
public func gt_inbox_set(_ videoId: UnsafePointer<CChar>?, _ seen: Int32, _ archived: Int32, _ callback: GTCallback,
                         _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let videoId = string(videoId) else { return reply.fail("falta el videoId") }
    Task { @MainActor in
        let library = Library.shared
        library.setInbox(videoId, seen: seen < 0 ? nil : seen != 0, archived: archived < 0 ? nil : archived != 0)
        reply.ok(["seen": library.inbox.seen.contains(videoId), "archived": library.inbox.archived.contains(videoId)])
    }
}
