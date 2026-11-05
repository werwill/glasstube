import Foundation
import YTKit

/// Lo que va en un respaldo de Glasstube (fase 5b). Solo datos de esta Mac: nunca sesiones, tokens ni nada del Llavero;
/// tampoco la vinculación del control remoto ni lo que es de cada Mac (el aviso de versiones, iCloud Drive).
nonisolated struct BackupContents: Equatable, Sendable {
    var groups: [ChannelGroup] = []
    var subscriptions: [GroupChannel] = []
    var blockedChannels: [BlockedChannel] = []
    var history: [SavedVideo] = []
    var watchLater: [SavedVideo] = []
    var hiddenVideos: [String] = []
    var queue: [MediaItem] = []
    var queueTitle: String?
    var settings: SettingsSnapshot?

    func count(_ section: BackupSection) -> Int {
        switch section {
        case .groups: groups.count
        case .subscriptions: subscriptions.count
        case .blocked: blockedChannels.count
        case .history: history.count + watchLater.count + hiddenVideos.count
        case .queue: queue.count
        case .settings: settings?.count ?? 0
        }
    }

    /// Las partes que traen algo.
    var sections: [BackupSection] { BackupSection.allCases.filter { count($0) > 0 } }

    /// Sin lo que dejan las respuestas con sesión en las tarjetas (`feedbackToken`, el menú de TV): son de la cuenta.
    func sanitized() -> BackupContents {
        var copy = self
        copy.history = history.map { $0.sanitized() }
        copy.watchLater = watchLater.map { $0.sanitized() }
        copy.queue = queue.map { $0.sanitizedForBackup() }
        return copy
    }
}

/// Las partes de un respaldo que se pueden elegir al restaurar.
enum BackupSection: String, CaseIterable, Identifiable, Sendable {
    case groups, subscriptions, blocked, history, queue, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .groups: String(localized: "Grupos de canales")
        case .subscriptions: String(localized: "Suscripciones de esta Mac")
        case .blocked: String(localized: "Canales bloqueados")
        case .history: String(localized: "Historial, posiciones y Ver más tarde")
        case .queue: String(localized: "Cola de reproducción")
        case .settings: String(localized: "Ajustes")
        }
    }

    var symbol: String {
        switch self {
        case .groups: "folder"
        case .subscriptions: "play.rectangle.on.rectangle"
        case .blocked: "nosign"
        case .history: "clock.arrow.circlepath"
        case .queue: "list.bullet"
        case .settings: "gearshape"
        }
    }
}

/// Un respaldo leído de un archivo: de Glasstube o de SmartTube.
nonisolated struct BackupFile: Equatable {
    enum Source: Equatable {
        /// Versión de la app que lo hizo y cuándo.
        case glasstube(app: String?, created: Date?)
        case smartTube
    }

    var source: Source
    var contents: BackupContents
    /// Lo que no se trae (para la hoja de restaurar).
    var notes: [String] = []
}

/// El ZIP del respaldo:
///
///     manifest.json   formato «mx.glasstube.respaldo», versión 1, la de la app, la fecha y qué lleva
///     groups.json     grupos y suscripciones de esta Mac (el mismo esquema que Application Support/Glasstube/groups.json)
///     library.json    historial con posiciones, Ver más tarde, «No me interesa» y canales bloqueados (como library.json)
///     queue.json      la cola de reproducción
///     settings.json   los ajustes de Glasstube que no son de cada Mac
///
/// JSON legible, para que un respaldo se pueda revisar o editar a mano.
nonisolated enum BackupArchive {
    static let format = "mx.glasstube.respaldo"
    static let version = 1

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unknown
        case newerVersion(Int)
        case damaged(String)

        var description: String {
            switch self {
            case .unknown: String(localized: "no es un respaldo de Glasstube ni de SmartTube")
            case .newerVersion(let version): String(localized: "es de una versión más nueva de Glasstube (formato \(version)); actualiza la app")
            case .damaged(let detail): String(localized: "el archivo está dañado (\(detail))")
            }
        }
    }

    struct Manifest: Codable, Equatable {
        var format: String
        var version: Int
        var app: String?
        var created: Date?
        /// Cuántos elementos de cada parte lleva (informativo).
        var contents: [String: Int]?
    }

    struct GroupsFile: Codable, Equatable {
        var groups: [ChannelGroup] = []
        var subscriptions: [GroupChannel] = []

        init(groups: [ChannelGroup], subscriptions: [GroupChannel]) {
            self.groups = groups
            self.subscriptions = subscriptions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            groups = try container.decodeIfPresent([ChannelGroup].self, forKey: .groups) ?? []
            subscriptions = try container.decodeIfPresent([GroupChannel].self, forKey: .subscriptions) ?? []
        }
    }

    struct LibraryFile: Codable, Equatable {
        var history: [SavedVideo] = []
        var watchLater: [SavedVideo] = []
        var hiddenVideos: [String] = []
        var blockedChannels: [BlockedChannel] = []

        init(history: [SavedVideo], watchLater: [SavedVideo], hiddenVideos: [String], blockedChannels: [BlockedChannel]) {
            self.history = history
            self.watchLater = watchLater
            self.hiddenVideos = hiddenVideos
            self.blockedChannels = blockedChannels
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            history = try container.decodeIfPresent([SavedVideo].self, forKey: .history) ?? []
            watchLater = try container.decodeIfPresent([SavedVideo].self, forKey: .watchLater) ?? []
            hiddenVideos = try container.decodeIfPresent([String].self, forKey: .hiddenVideos) ?? []
            blockedChannels = try container.decodeIfPresent([BlockedChannel].self, forKey: .blockedChannels) ?? []
        }
    }

    struct QueueFile: Codable, Equatable {
        var title: String?
        var items: [MediaItem]
    }

    // MARK: - Escribir

    static func make(_ contents: BackupContents, appVersion: String?, date: Date = Date()) throws -> Data {
        let contents = contents.sanitized()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var counts: [String: Int] = [:]
        for section in BackupSection.allCases { counts[section.rawValue] = contents.count(section) }
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = encoder.outputFormatting
        manifestEncoder.dateEncodingStrategy = .iso8601
        var entries = [
            ZipArchive.Entry(path: "manifest.json", data: try manifestEncoder.encode(
                Manifest(format: format, version: version, app: appVersion, created: date, contents: counts))),
            ZipArchive.Entry(path: "groups.json", data: try encoder.encode(GroupsFile(groups: contents.groups, subscriptions: contents.subscriptions))),
            ZipArchive.Entry(path: "library.json", data: try encoder.encode(LibraryFile(
                history: contents.history, watchLater: contents.watchLater, hiddenVideos: contents.hiddenVideos,
                blockedChannels: contents.blockedChannels))),
            ZipArchive.Entry(path: "queue.json", data: try encoder.encode(QueueFile(title: contents.queueTitle, items: contents.queue))),
        ]
        if let settings = contents.settings {
            entries.append(ZipArchive.Entry(path: "settings.json", data: try encoder.encode(settings)))
        }
        return ZipArchive.make(entries, date: date)
    }

    /// Nombre sugerido: `Glasstube-respaldo-2026-10-26.zip`.
    static func fileName(for date: Date = Date()) -> String {
        String(localized: "Glasstube-respaldo-\(dayStamp(date)).zip")
    }

    static func dayStamp(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Leer

    /// Un respaldo de Glasstube o, si no, uno de SmartTube (lo que sea compatible).
    static func read(_ data: Data, date: Date = Date()) throws -> BackupFile {
        let entries: [ZipArchive.Entry]
        do {
            entries = try ZipArchive.read(data)
        } catch ZipArchive.Failure.notAZip {
            throw Failure.unknown
        } catch {
            throw Failure.damaged(String(describing: error))
        }
        // Un respaldo de Glasstube abierto y vuelto a comprimir en Finder queda dentro de una carpeta.
        func entry(_ name: String) -> Data? {
            entries.first { $0.path == name || $0.path.hasSuffix("/" + name) && !$0.path.contains("__MACOSX") }?.data
        }
        let decoder = JSONDecoder()
        if let manifestData = entry("manifest.json") {
            let manifestDecoder = JSONDecoder()
            manifestDecoder.dateDecodingStrategy = .iso8601
            guard let manifest = try? manifestDecoder.decode(Manifest.self, from: manifestData), manifest.format == format else {
                throw Failure.unknown
            }
            guard manifest.version <= version else { throw Failure.newerVersion(manifest.version) }
            var contents = BackupContents()
            do {
                if let data = entry("groups.json") {
                    let file = try decoder.decode(GroupsFile.self, from: data)
                    contents.groups = file.groups
                    contents.subscriptions = file.subscriptions
                }
                if let data = entry("library.json") {
                    let file = try decoder.decode(LibraryFile.self, from: data)
                    contents.history = file.history
                    contents.watchLater = file.watchLater
                    contents.hiddenVideos = file.hiddenVideos
                    contents.blockedChannels = file.blockedChannels
                }
                if let data = entry("queue.json") {
                    let file = try decoder.decode(QueueFile.self, from: data)
                    contents.queue = file.items
                    contents.queueTitle = file.title
                }
                if let data = entry("settings.json") { contents.settings = try decoder.decode(SettingsSnapshot.self, from: data) }
            } catch {
                throw Failure.damaged(String(describing: error))
            }
            return BackupFile(source: .glasstube(app: manifest.app, created: manifest.created), contents: contents.sanitized())
        }
        guard SmartTubeBackup.looksLike(entries) else { throw Failure.unknown }
        let smartTube = SmartTubeBackup.parse(entries, date: date)
        let contents = BackupContents(groups: smartTube.groups, subscriptions: smartTube.subscriptions,
                                      blockedChannels: smartTube.blockedChannels, history: smartTube.history)
        var notes = [String(localized: "Los ajustes de SmartTube no se traen: son de Android TV y no corresponden uno a uno con los de Glasstube."),
                     String(localized: "Las cuentas tampoco: inicia sesión de nuevo en Ajustes › Cuentas.")]
        if smartTube.skipped > 0 {
            notes.append(smartTube.skipped == 1 ? String(localized: "1 entrada no se pudo usar (sin un id de canal o de video válido).")
                : String(localized: "\(smartTube.skipped) entradas no se pudieron usar (sin un id de canal o de video válido)."))
        }
        return BackupFile(source: .smartTube, contents: contents, notes: notes)
    }
}

// MARK: - Sin tokens

extension SavedVideo {
    nonisolated func sanitized() -> SavedVideo {
        var copy = self
        copy.item = item.sanitizedForBackup()
        return copy
    }
}

extension MediaItem {
    /// Sin el token de «No me interesa»/«Quitar del historial» ni el menú de la TV, que vienen de la cuenta.
    nonisolated func sanitizedForBackup() -> MediaItem {
        var copy = self
        copy.feedbackToken = nil
        copy.menuPanel = nil
        return copy
    }
}
