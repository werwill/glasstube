import Foundation
import Observation
import YTKit

/// Un video guardado en la app con su posición (el `VideoStateController` de SmartTube, sin cuenta).
nonisolated struct SavedVideo: Codable, Hashable, Sendable, Identifiable {
    var item: MediaItem
    var position: Double
    var duration: Double?
    var updatedAt: Date

    var id: String { item.id }

    var fraction: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(1, max(0, position / duration))
    }
}

nonisolated struct BlockedChannel: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
}

/// Datos locales mientras no haya cuentas: historial de reproducción con posiciones, "Ver más tarde", videos
/// marcados como "No me interesa" y canales bloqueados. Se guardan en Application Support/Glasstube/library.json.
@Observable
final class LocalLibrary {
    private nonisolated struct Store: Codable {
        var history: [SavedVideo] = []
        var watchLater: [SavedVideo] = []
        var hiddenVideos: [String] = []
        var blockedChannels: [BlockedChannel] = []
    }

    private(set) var history: [SavedVideo] = []
    private(set) var watchLater: [SavedVideo] = []
    private(set) var hiddenVideos: Set<String> = []
    private(set) var blockedChannels: [BlockedChannel] = []
    private var saveTask: Task<Void, Never>?
    /// Sin archivo: pruebas y capturas (`-GTBibliotecaEnMemoria`), que no tocan el historial de esta Mac.
    @ObservationIgnored private let persistent: Bool

    static let historyLimit = 500

    private nonisolated static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Glasstube", isDirectory: true).appendingPathComponent("library.json")
    }()

    init(persistent: Bool = true) {
        self.persistent = persistent
        if persistent, let data = try? Data(contentsOf: Self.fileURL), let store = try? JSONDecoder().decode(Store.self, from: data) {
            history = store.history
            watchLater = store.watchLater
            hiddenVideos = Set(store.hiddenVideos)
            blockedChannels = store.blockedChannels
        }
    }

    // MARK: - Historial

    /// Videos empezados y sin terminar, para "Seguir viendo".
    var continueWatching: [SavedVideo] {
        history.filter { ($0.fraction ?? 0) > 0.02 && ($0.fraction ?? 1) < 0.95 }
    }

    func savedPosition(for videoId: String) -> SavedVideo? {
        history.first { $0.item.videoId == videoId }
    }

    func progress(for videoId: String?) -> Double? {
        guard let videoId else { return nil }
        return savedPosition(for: videoId)?.fraction
    }

    func recordPlayback(of item: MediaItem, position: Double, duration: Double?) {
        var entry = SavedVideo(item: item, position: position, duration: duration, updatedAt: Date())
        if let index = history.firstIndex(where: { $0.item.id == item.id }) {
            if duration == nil { entry.duration = history[index].duration }
            history.remove(at: index)
        }
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        scheduleSave()
    }

    func removeFromHistory(_ item: MediaItem) {
        history.removeAll { $0.item.id == item.id }
        scheduleSave()
    }

    func clearHistory() {
        history.removeAll()
        scheduleSave()
    }

    // MARK: - Ver más tarde

    func isInWatchLater(_ item: MediaItem) -> Bool { watchLater.contains { $0.item.id == item.id } }

    func toggleWatchLater(_ item: MediaItem) {
        if let index = watchLater.firstIndex(where: { $0.item.id == item.id }) {
            watchLater.remove(at: index)
        } else {
            watchLater.insert(SavedVideo(item: item, position: 0, duration: item.durationSeconds.map(Double.init), updatedAt: Date()), at: 0)
        }
        scheduleSave()
    }

    // MARK: - Filtros

    func hide(_ item: MediaItem) {
        hiddenVideos.insert(item.id)
        scheduleSave()
    }

    func block(channelId: String, name: String) {
        guard !blockedChannels.contains(where: { $0.id == channelId }) else { return }
        blockedChannels.append(BlockedChannel(id: channelId, name: name))
        scheduleSave()
    }

    func unblock(_ channel: BlockedChannel) {
        blockedChannels.removeAll { $0.id == channel.id }
        scheduleSave()
    }

    func unhideAll() {
        hiddenVideos.removeAll()
        scheduleSave()
    }

    func isBlocked(channelId: String) -> Bool { blockedChannels.contains { $0.id == channelId } }

    /// Video, Short, canal o lista de un canal bloqueado. Sin id de canal (la búsqueda de TV no lo da), por el nombre.
    func isBlocked(_ item: MediaItem) -> Bool {
        guard !blockedChannels.isEmpty else { return false }
        if let channelId = item.channelId { return isBlocked(channelId: channelId) }
        let name = item.kind == .channel ? item.title : item.author
        return name.map { name in blockedChannels.contains { $0.name == name } } ?? false
    }

    /// Quita lo oculto y lo de canales bloqueados (como los filtros de contenido de SmartTube): en todos los feeds, la
    /// búsqueda, los sugeridos y la reproducción automática.
    func visible(_ items: [MediaItem]) -> [MediaItem] {
        guard !hiddenVideos.isEmpty || !blockedChannels.isEmpty else { return items }
        return items.filter { !hiddenVideos.contains($0.id) && !isBlocked($0) }
    }

    // MARK: - Disco

    private func scheduleSave() {
        guard persistent else { return }
        saveTask?.cancel()
        let store = Store(history: history, watchLater: watchLater, hiddenVideos: Array(hiddenVideos), blockedChannels: blockedChannels)
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                let url = LocalLibrary.fileURL
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(store).write(to: url, options: .atomic)
            } catch {
                NSLog("Glasstube: no se pudo guardar la biblioteca: \(error)")
            }
        }
    }
}
