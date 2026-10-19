import AppKit
import CoreSpotlight
import UniformTypeIdentifiers
import YTKit

/// Spotlight (fase 4): los videos vistos y los canales (los de esos videos y los que se abren) van al índice de Core
/// Spotlight de la app, con título, canal, duración y miniatura. Al abrir un resultado, macOS le pasa a la app una
/// `NSUserActivity` con el identificador (`video:<id>` o `channel:<id>`) y la app lo reproduce o abre el canal.
/// Solo datos públicos de YouTube y la fecha en que se vio; se puede apagar y vaciar en Ajustes > General.
final class SpotlightIndex {
    static let videoDomain = "mx.glasstube.videos"
    static let channelDomain = "mx.glasstube.channels"

    private let settings: AppSettings
    private let index = CSSearchableIndex.default()
    /// Lo ya indexado en esta sesión (id → título), para no volver a bajar la miniatura en cada evento.
    private var indexed: [String: String] = [:]

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Identificadores

    static func identifier(video id: String) -> String { "video:\(id)" }
    static func identifier(channel id: String) -> String { "channel:\(id)" }

    /// Lo que hay que abrir para un resultado de Spotlight.
    static func link(for identifier: String) -> YouTubeLink? {
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "video": return .video(id: parts[1])
        case "channel": return .channel(parts[1])
        default: return nil
        }
    }

    // MARK: - Indexar

    /// Un video que se está viendo (con lo que se sepa de él) y su canal.
    func index(video item: MediaItem, duration: Double?) {
        guard settings.spotlightEnabled, let videoId = item.videoId, item.title != videoId else { return }
        let identifier = Self.identifier(video: videoId)
        guard indexed[identifier] != item.title else { return }
        indexed[identifier] = item.title
        let attributes = CSSearchableItemAttributeSet(contentType: .movie)
        attributes.title = item.title
        attributes.displayName = item.title
        let length = (duration ?? item.durationSeconds.map(Double.init)).map { Format.time($0) }
        attributes.contentDescription = [item.author, length, "YouTube · Glasstube"].compactMap { $0 }.joined(separator: " · ")
        if let author = item.author {
            attributes.creator = author
            attributes.authorNames = [author]
        }
        if let duration { attributes.duration = NSNumber(value: duration) }
        attributes.keywords = ["YouTube", "Glasstube", "video"] + [item.author].compactMap { $0 }
        attributes.lastUsedDate = Date()
        attributes.identifier = videoId
        let urls = MediaItemImages.card(item, width: 320)
        Task {
            attributes.thumbnailData = await Self.thumbnail(from: urls)
            self.save(CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: Self.videoDomain, attributeSet: attributes))
        }
        if let channelId = item.channelId, let author = item.author {
            index(channel: channelId, name: author, avatar: item.authorThumbnails, detail: nil)
        }
    }

    /// Un canal (al ver uno de sus videos o al abrir su página).
    func index(channel channelId: String, name: String, avatar: [YTThumbnail], detail: String?) {
        guard settings.spotlightEnabled else { return }
        let identifier = Self.identifier(channel: channelId)
        let key = name + (detail ?? "")
        guard indexed[identifier] != key else { return }
        indexed[identifier] = key
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = name
        attributes.displayName = name
        attributes.contentDescription = ["Canal de YouTube", detail].compactMap { $0 }.joined(separator: " · ")
        attributes.keywords = ["YouTube", "Glasstube", "canal", name]
        attributes.lastUsedDate = Date()
        attributes.identifier = channelId
        let urls = MediaItemImages.avatar(avatar)
        Task {
            attributes.thumbnailData = await Self.thumbnail(from: urls)
            self.save(CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: Self.channelDomain, attributeSet: attributes))
        }
    }

    private func save(_ item: CSSearchableItem) {
        // Por omisión vencen al mes; lo visto se queda un año.
        item.expirationDate = Date().addingTimeInterval(365 * 24 * 3600)
        let identifier = item.uniqueIdentifier
        let logs = Automation.shared.logsSpotlight
        index.indexSearchableItems([item]) { @Sendable error in
            if let error {
                NSLog("Glasstube: Spotlight no indexó \(identifier): \(error.localizedDescription)")
            } else if logs {
                NSLog("Glasstube spotlight: indexado \(identifier)")
            }
        }
    }

    /// JPEG pequeño para la vista previa de Spotlight.
    private static func thumbnail(from urls: [URL]) async -> Data? {
        guard let image = await ImagePipeline.shared.firstImage(from: urls),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }

    // MARK: - Quitar

    func remove(videoId: String) {
        let identifier = Self.identifier(video: videoId)
        indexed[identifier] = nil
        index.deleteSearchableItems(withIdentifiers: [identifier]) { @Sendable _ in }
    }

    /// «Quitar todo de Spotlight».
    func removeAll(completion: (@Sendable (Error?) -> Void)? = nil) {
        indexed = [:]
        index.deleteSearchableItems(withDomainIdentifiers: [Self.videoDomain, Self.channelDomain]) { @Sendable error in
            completion?(error)
        }
    }

    // MARK: - Verificación

    /// Busca en el índice de la app (lo que Spotlight encontraría con ese texto). Para la automatización de pruebas.
    /// Los cierres son `@Sendable`: Core Spotlight los llama desde su cola y, aislados al actor principal, la app caía
    /// en `dispatch_assert_queue` (visto el 18-oct-2026).
    func query(_ text: String) async -> [String] {
        let escaped = text.replacingOccurrences(of: "\"", with: "")
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title", "contentDescription"]
        let query = CSSearchQuery(queryString: "title == \"*\(escaped)*\"cd || contentDescription == \"*\(escaped)*\"cd",
                                  queryContext: context)
        return await withCheckedContinuation { continuation in
            let found = FoundItems()
            query.foundItemsHandler = { @Sendable items in
                found.append(items.map { "\($0.uniqueIdentifier) «\($0.attributeSet.title ?? "")»" })
            }
            query.completionHandler = { @Sendable error in
                if let error { found.append(["error: \(error.localizedDescription)"]) }
                continuation.resume(returning: found.all)
            }
            query.start()
        }
    }
}

/// Lo que va encontrando `CSSearchQuery` (llega desde su propia cola).
private nonisolated final class FoundItems: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ more: [String]) { lock.withLock { items += more } }
    var all: [String] { lock.withLock { items } }
}
