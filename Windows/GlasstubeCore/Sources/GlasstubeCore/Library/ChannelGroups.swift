import Foundation
import Observation
import YTKit

/// Un canal de un grupo o de las suscripciones locales (`ItemGroup.Item` de SmartTube: id, nombre e ícono). Lo que se
/// importa de PocketTube o GrayJay solo trae el id: el nombre llega con su feed RSS y la foto al abrir el canal.
public nonisolated struct GroupChannel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String?
    public var avatarURL: String?

    public init(id: String, title: String? = nil, avatarURL: String? = nil) {
        self.id = id
        self.title = title
        self.avatarURL = avatarURL
    }

    /// El canal de una tarjeta (video, Short o canal), si se sabe su id.
    public init?(item: MediaItem) {
        guard let channelId = item.channelId, ChannelGroupImport.isChannelId(channelId) else { return nil }
        id = channelId
        title = item.kind == .channel ? item.title : item.author
        let avatars = item.kind == .channel && item.authorThumbnails.isEmpty ? item.thumbnails : item.authorThumbnails
        avatarURL = avatars.best(forWidth: 88)?.url
    }

    public var displayName: String { title ?? id }
}

/// Grupo de canales (`ItemGroup` de SmartTube): un nombre y sus canales. Su feed son los videos nuevos de esos canales
/// por RSS, con cuenta o sin ella.
public nonisolated struct ChannelGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var iconURL: String?
    public var channels: [GroupChannel]

    public init(id: String, title: String, iconURL: String? = nil, channels: [GroupChannel] = []) {
        self.id = id
        self.title = title
        self.iconURL = iconURL
        self.channels = channels
    }

    public func contains(_ channelId: String) -> Bool { channels.contains { $0.id == channelId } }
}

/// Lo que dejó una importación, para el aviso.
public struct GroupImportSummary: Equatable {
    public var format: ChannelGroupImport.Format
    public var created: [String] = []
    public var updated: [String] = []
    public var channelsAdded = 0
    public var subscriptionsAdded = 0
    public var skipped = 0

    public var message: String {
        var parts: [String] = []
        if format == .newPipe {
            parts.append(subscriptionsAdded == 1 ? "1 suscripción nueva en esta PC" : "\(subscriptionsAdded) suscripciones nuevas en esta PC")
        } else {
            if !created.isEmpty { parts.append(created.count == 1 ? "grupo «\(created[0])»" : "\(created.count) grupos nuevos") }
            if !updated.isEmpty { parts.append(updated.count == 1 ? "«\(updated[0])» actualizado" : "\(updated.count) grupos actualizados") }
            parts.append(channelsAdded == 1 ? "1 canal" : "\(channelsAdded) canales")
        }
        if skipped > 0 { parts.append("\(skipped) \(skipped == 1 ? "entrada omitida" : "entradas omitidas") (no son canales de YouTube)") }
        return "\(format.rawValue): " + parts.joined(separator: ", ")
    }
}

/// Grupos de canales y suscripciones locales (`ChannelGroupServiceImpl` de SmartTube, que guarda las suscripciones sin
/// cuenta como un grupo más, el «1000»). Se guardan como la biblioteca local: JSON en
/// Application Support/Glasstube/groups.json, escrito poco después de cada cambio.
@Observable
public final class ChannelGroupStore {
    private nonisolated struct Store: Codable {
        public var groups: [ChannelGroup] = []
        public var subscriptions: [GroupChannel] = []
    }

    public private(set) var groups: [ChannelGroup] = []
    /// Suscripciones de esta PC (sin cuenta), las más recientes primero.
    public private(set) var subscriptions: [GroupChannel] = []
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public nonisolated static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Glasstube", isDirectory: true).appendingPathComponent("groups.json")
    }()

    /// `fileURL` nil: solo en memoria (pruebas y capturas con `-GTGruposEnMemoria`).
    public init(fileURL: URL? = ChannelGroupStore.defaultURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let store = try? JSONDecoder().decode(Store.self, from: data) {
            groups = store.groups
            subscriptions = store.subscriptions
        }
    }

    public func group(_ id: String) -> ChannelGroup? { groups.first { $0.id == id } }

    public func groups(containing channelId: String) -> [ChannelGroup] { groups.filter { $0.contains(channelId) } }

    // MARK: - Grupos

    /// Un grupo nuevo al final de la lista (con otro nombre si ya hay uno igual).
    @discardableResult
    public func create(title: String, channels: [GroupChannel] = [], iconURL: String? = nil) -> ChannelGroup {
        var seen = Set<String>()
        let group = ChannelGroup(id: UUID().uuidString, title: uniqueTitle(Self.clean(title) ?? "Grupo nuevo"), iconURL: iconURL,
                                 channels: channels.filter { seen.insert($0.id).inserted })
        groups.append(group)
        scheduleSave()
        return group
    }

    public func rename(_ id: String, to title: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }), let title = Self.clean(title), title != groups[index].title else { return }
        groups[index].title = uniqueTitle(title, ignoring: id)
        scheduleSave()
    }

    public func delete(_ id: String) {
        groups.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Reordenar arrastrando en la barra lateral. Lo mismo que `Array.move(fromOffsets:toOffset:)` de SwiftUI, que fuera
    /// de Apple no existe: `destination` cuenta en la lista de antes de mover.
    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.filter { groups.indices.contains($0) }.map { groups[$0] }
        let target = destination - offsets.filter { $0 < destination }.count
        for index in offsets.sorted(by: >) where groups.indices.contains(index) { groups.remove(at: index) }
        groups.insert(contentsOf: moving, at: min(max(0, target), groups.count))
        scheduleSave()
    }

    /// Subir (-1) o bajar (+1) un puesto.
    public func move(_ id: String, by offset: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard groups.indices.contains(target) else { return }
        groups.swapAt(index, target)
        scheduleSave()
    }

    /// Agrega el canal al grupo (si ya estaba, le completa el nombre y la foto).
    public func add(_ channel: GroupChannel, to groupId: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        if let existing = groups[index].channels.firstIndex(where: { $0.id == channel.id }) {
            groups[index].channels[existing] = Self.merged(groups[index].channels[existing], channel)
        } else {
            groups[index].channels.append(channel)
        }
        scheduleSave()
    }

    public func remove(channelId: String, from groupId: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[index].channels.removeAll { $0.id == channelId }
        scheduleSave()
    }

    // MARK: - Suscripciones locales

    public func isSubscribed(_ channelId: String) -> Bool { subscriptions.contains { $0.id == channelId } }

    /// Como `ChannelGroupServiceImpl.subscribe`: el canal va primero.
    public func subscribe(_ channel: GroupChannel) {
        if let index = subscriptions.firstIndex(where: { $0.id == channel.id }) {
            subscriptions[index] = Self.merged(subscriptions[index], channel)
        } else {
            subscriptions.insert(channel, at: 0)
        }
        scheduleSave()
    }

    public func unsubscribe(_ channelId: String) {
        subscriptions.removeAll { $0.id == channelId }
        scheduleSave()
    }

    // MARK: - Nombres y fotos

    /// Completa nombres que faltan (los de los feeds RSS) y pone los que se ven al abrir un canal. No hace nada si no hay
    /// cambios, para no reescribir el archivo en cada feed.
    public func update(titles: [String: String] = [:], channel: GroupChannel? = nil) {
        var changed = false
        func apply(_ list: inout [GroupChannel]) {
            for index in list.indices {
                var entry = list[index]
                if entry.title == nil, let title = titles[entry.id] { entry.title = title }
                if let channel, channel.id == entry.id { entry = Self.merged(entry, channel) }
                if entry != list[index] {
                    list[index] = entry
                    changed = true
                }
            }
        }
        for index in groups.indices { apply(&groups[index].channels) }
        apply(&subscriptions)
        if changed { scheduleSave() }
    }

    // MARK: - Importar

    /// Grupos de PocketTube o GrayJay (un grupo con el mismo nombre recibe los canales que le falten, en lugar de
    /// duplicarse) o, de NewPipe, suscripciones locales (como SmartTube).
    @discardableResult
    public func importGroups(_ result: ChannelGroupImport) -> GroupImportSummary {
        var summary = GroupImportSummary(format: result.format, skipped: result.skipped)
        for imported in result.groups {
            let channels = imported.channels.map { GroupChannel(id: $0.channelId, title: $0.title) }
            if result.isSubscriptions {
                for channel in channels where !isSubscribed(channel.id) {
                    subscriptions.append(channel)
                    summary.subscriptionsAdded += 1
                }
                continue
            }
            let title = Self.clean(imported.title) ?? "Grupo importado"
            if let index = groups.firstIndex(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) {
                let fresh = channels.filter { !groups[index].contains($0.id) }
                guard !fresh.isEmpty else { continue }
                groups[index].channels += fresh
                summary.updated.append(groups[index].title)
                summary.channelsAdded += fresh.count
            } else {
                groups.append(ChannelGroup(id: UUID().uuidString, title: title, iconURL: imported.iconURL, channels: channels))
                summary.created.append(title)
                summary.channelsAdded += channels.count
            }
        }
        scheduleSave()
        return summary
    }

    // MARK: - Ayudas

    private static func clean(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    /// «Música», «Música 2», «Música 3»…
    private func uniqueTitle(_ title: String, ignoring id: String? = nil) -> String {
        let taken = Set(groups.filter { $0.id != id }.map { $0.title.lowercased() })
        guard taken.contains(title.lowercased()) else { return title }
        var number = 2
        while taken.contains("\(title) \(number)".lowercased()) { number += 1 }
        return "\(title) \(number)"
    }

    private static func merged(_ old: GroupChannel, _ new: GroupChannel) -> GroupChannel {
        GroupChannel(id: old.id, title: new.title ?? old.title, avatarURL: new.avatarURL ?? old.avatarURL)
    }

    private func scheduleSave() {
        guard let fileURL else { return }
        saveTask?.cancel()
        let store = Store(groups: groups, subscriptions: subscriptions)
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(store).write(to: fileURL, options: .atomic)
            } catch {
                NSLog("Glasstube: no se pudieron guardar los grupos: \(error)")
            }
        }
    }
}
