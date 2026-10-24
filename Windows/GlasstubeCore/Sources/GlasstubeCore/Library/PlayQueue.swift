import Foundation
import Observation
import YTKit

/// Cola de reproducción: lo que va después del video actual, antes de los sugeridos («Reproducir a continuación» y
/// «Agregar a la cola» de los menús, o la playlist desde la que se abrió un video). Como la `Playlist` de SmartTube: la
/// cola se reproduce siempre; la reproducción automática con sugeridos (ajuste) solo cuando la cola está vacía.
@Observable
public final class PlayQueue {
    public private(set) var items: [MediaItem] = []
    /// De dónde salió la cola cuando es una playlist («Playlist: Blender Open Movies»); nil si se armó a mano.
    public private(set) var sourceTitle: String?

    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var next: MediaItem? { items.first }

    /// «Reproducir a continuación»: primero en la cola (si ya estaba, se mueve).
    public func playNext(_ item: MediaItem) {
        guard item.isPlayable else { return }
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
    }

    /// «Agregar a la cola»: al final (si ya estaba, no se repite).
    public func append(_ item: MediaItem) {
        guard item.isPlayable, !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
    }

    public func remove(_ item: MediaItem) {
        items.removeAll { $0.id == item.id }
        if items.isEmpty { sourceTitle = nil }
    }

    public func clear() {
        items = []
        sourceTitle = nil
    }

    /// Saca el siguiente para reproducirlo.
    public func popNext() -> MediaItem? {
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        if items.isEmpty { sourceTitle = nil }
        return item
    }

    /// Al abrir un video de una playlist: la cola pasa a ser el resto de la lista (lo que viene después), como en
    /// SmartTube. Lo que se había puesto a mano se pierde, igual que al empezar otra lista en YouTube.
    public func load(playlist: [MediaItem], after item: MediaItem, title: String?) {
        let playable = playlist.filter { $0.isPlayable && !$0.isShort }
        guard let index = playable.firstIndex(where: { $0.id == item.id }) else { return }
        items = Array(playable[(index + 1)...])
        sourceTitle = items.isEmpty ? nil : title
    }
}
