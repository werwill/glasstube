import Foundation
import Observation
import YTKit

/// Un video guardado en la app con su posición (el `VideoStateController` de SmartTube, sin cuenta).
public nonisolated struct SavedVideo: Codable, Hashable, Sendable, Identifiable {
    public var item: MediaItem
    public var position: Double
    public var duration: Double?
    public var updatedAt: Date

    public init(item: MediaItem, position: Double, duration: Double?, updatedAt: Date) {
        self.item = item
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }

    public var id: String { item.id }

    public var fraction: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(1, max(0, position / duration))
    }
}

public nonisolated struct BlockedChannel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Datos locales mientras no haya cuentas: historial de reproducción con posiciones, "Ver más tarde", videos
/// marcados como "No me interesa" y canales bloqueados. Se guardan en Application Support/Glasstube/library.json.
@Observable
public final class LocalLibrary {
    private nonisolated struct Store: Codable {
        public var history: [SavedVideo] = []
        public var watchLater: [SavedVideo] = []
        public var hiddenVideos: [String] = []
        public var blockedChannels: [BlockedChannel] = []
    }

    public private(set) var history: [SavedVideo] = []
    public private(set) var watchLater: [SavedVideo] = []
    public private(set) var hiddenVideos: Set<String> = []
    public private(set) var blockedChannels: [BlockedChannel] = []
    private var saveTask: Task<Void, Never>?
    /// Sin archivo: pruebas y capturas (`-GTBibliotecaEnMemoria`), que no tocan el historial de esta PC.
    @ObservationIgnored private let persistent: Bool

    public static let historyLimit = 500

    private nonisolated static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Glasstube", isDirectory: true).appendingPathComponent("library.json")
    }()

    public init(persistent: Bool = true) {
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
    public var continueWatching: [SavedVideo] {
        history.filter { ($0.fraction ?? 0) > 0.02 && ($0.fraction ?? 1) < 0.95 }
    }

    public func savedPosition(for videoId: String) -> SavedVideo? {
        history.first { $0.item.videoId == videoId }
    }

    public func progress(for videoId: String?) -> Double? {
        guard let videoId else { return nil }
        return savedPosition(for: videoId)?.fraction
    }

    public func recordPlayback(of item: MediaItem, position: Double, duration: Double?) {
        var entry = SavedVideo(item: item, position: position, duration: duration, updatedAt: Date())
        if let index = history.firstIndex(where: { $0.item.id == item.id }) {
            if duration == nil { entry.duration = history[index].duration }
            history.remove(at: index)
        }
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        scheduleSave()
    }

    /// Corrige los datos de un video guardado (título, canal, miniatura) en el historial y en Ver más tarde, sin
    /// moverlo ni tocar su posición.
    public func updateItem(videoId: String, _ change: (inout MediaItem) -> Void) {
        var changed = false
        for index in history.indices where history[index].item.videoId == videoId {
            change(&history[index].item)
            changed = true
        }
        for index in watchLater.indices where watchLater[index].item.videoId == videoId {
            change(&watchLater[index].item)
            changed = true
        }
        if changed { scheduleSave() }
    }

    public func removeFromHistory(_ item: MediaItem) {
        history.removeAll { $0.item.id == item.id }
        scheduleSave()
    }

    public func clearHistory() {
        history.removeAll()
        scheduleSave()
    }

    // MARK: - Ver más tarde

    public func isInWatchLater(_ item: MediaItem) -> Bool { watchLater.contains { $0.item.id == item.id } }

    public func toggleWatchLater(_ item: MediaItem) {
        if let index = watchLater.firstIndex(where: { $0.item.id == item.id }) {
            watchLater.remove(at: index)
        } else {
            watchLater.insert(SavedVideo(item: item, position: 0, duration: item.durationSeconds.map(Double.init), updatedAt: Date()), at: 0)
        }
        scheduleSave()
    }

    // MARK: - Filtros

    public func hide(_ item: MediaItem) {
        hiddenVideos.insert(item.id)
        scheduleSave()
    }

    public func block(channelId: String, name: String) {
        guard !blockedChannels.contains(where: { $0.id == channelId }) else { return }
        blockedChannels.append(BlockedChannel(id: channelId, name: name))
        scheduleSave()
    }

    public func unblock(_ channel: BlockedChannel) {
        blockedChannels.removeAll { $0.id == channel.id }
        scheduleSave()
    }

    public func unhideAll() {
        hiddenVideos.removeAll()
        scheduleSave()
    }

    public func isBlocked(channelId: String) -> Bool { blockedChannels.contains { $0.id == channelId } }

    /// Video, Short, canal o lista de un canal bloqueado. Sin id de canal (la búsqueda de TV no lo da), por el nombre.
    public func isBlocked(_ item: MediaItem) -> Bool {
        guard !blockedChannels.isEmpty else { return false }
        if let channelId = item.channelId { return isBlocked(channelId: channelId) }
        let name = item.kind == .channel ? item.title : item.author
        return name.map { name in blockedChannels.contains { $0.name == name } } ?? false
    }

    /// Quita lo oculto y lo de canales bloqueados (como los filtros de contenido de SmartTube): en todos los feeds, la
    /// búsqueda, los sugeridos y la reproducción automática.
    public func visible(_ items: [MediaItem]) -> [MediaItem] {
        guard !hiddenVideos.isEmpty || !blockedChannels.isEmpty else { return items }
        return items.filter { !hiddenVideos.contains($0.id) && !isBlocked($0) }
    }

    // MARK: - Disco

    /// Guarda ya, sin esperar (al cerrar la app: la escritura diferida de `scheduleSave` podría no llegar).
    public func saveNow() {
        guard persistent else { return }
        saveTask?.cancel()
        let store = Store(history: history, watchLater: watchLater, hiddenVideos: Array(hiddenVideos), blockedChannels: blockedChannels)
        do {
            let url = Self.fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(store).write(to: url, options: .atomic)
        } catch {
            NSLog("Glasstube: no se pudo guardar la biblioteca: \(error)")
        }
    }

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
