import Foundation
import Observation
import YTKit

/// Títulos y miniaturas de DeArrow para tarjetas y reproductor (el `DeArrowProcessor` de SmartTube). Cada tarjeta pide
/// el de su video al aparecer; los pedidos se juntan un momento y YTKit los consulta por prefijo de hash (sin enviar los
/// ids). Con el ajuste apagado no se pide nada.
@Observable
public final class DeArrowStore {
    public private(set) var brandings: [String: DeArrowBranding] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let client: DeArrowClient

    public init(settings: AppSettings, client: DeArrowClient = .shared) {
        self.settings = settings
        self.client = client
    }

    public var isActive: Bool { settings.deArrowEnabled && (settings.deArrowTitles || settings.deArrowThumbnails) }

    /// Pide lo de DeArrow para un video (una vez por sesión).
    public func request(_ videoId: String?) {
        guard isActive, let videoId, !requested.contains(videoId) else { return }
        requested.insert(videoId)
        pending.append(videoId)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.flush()
        }
    }

    private func flush() async {
        let ids = pending
        pending = []
        flushTask = nil
        guard !ids.isEmpty else { return }
        let found = await client.branding(for: ids)
        var updated = brandings
        for (id, branding) in found where !branding.isEmpty { updated[id] = branding }
        if updated.count != brandings.count { brandings = updated }
        if !pending.isEmpty, flushTask == nil {
            flushTask = Task { [weak self] in await self?.flush() }
        }
    }

    /// Pruebas: lo que DeArrow "respondió" para un video.
    public func setBrandingForTesting(_ branding: DeArrowBranding) {
        brandings[branding.videoId] = branding
    }

    /// El título que se muestra: el de la comunidad si está activado y lo hay; si no, el de YouTube.
    public func title(for item: MediaItem) -> String {
        guard settings.deArrowEnabled, settings.deArrowTitles, let id = item.videoId, let title = brandings[id]?.title else { return item.title }
        return title
    }

    public func title(videoId: String?, fallback: String) -> String {
        guard settings.deArrowEnabled, settings.deArrowTitles, let videoId, let title = brandings[videoId]?.title else { return fallback }
        return title
    }

    /// La miniatura de la comunidad (la genera el servidor de DeArrow en el segundo votado).
    public func thumbnailURL(for item: MediaItem) -> URL? {
        guard settings.deArrowEnabled, settings.deArrowThumbnails, let id = item.videoId else { return nil }
        return brandings[id]?.thumbnailURL
    }

    /// El título de DeArrow reemplaza al original (para el «Título original: …» de la ayuda).
    public func replacesTitle(of item: MediaItem) -> Bool { title(for: item) != item.title }
}
