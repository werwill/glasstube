import AppKit
import Foundation
import Observation
import YTKit

/// Los almacenes de esta Mac que entran en un respaldo. Aparte de `AppModel` para poder probarlo sin servicios de red.
struct BackupStores {
    let library: LocalLibrary
    let groups: ChannelGroupStore
    let queue: PlayQueue
    let settings: AppSettings

    /// Todo lo de esta Mac, listo para el ZIP.
    func contents() -> BackupContents {
        BackupContents(groups: groups.groups, subscriptions: groups.subscriptions, blockedChannels: library.blockedChannels,
                       history: library.history, watchLater: library.watchLater, hiddenVideos: library.hiddenVideos.sorted(),
                       queue: queue.items, queueTitle: queue.sourceTitle, settings: settings.snapshot)
    }

    /// Combina las partes elegidas de un respaldo con lo que hay (no borra nada; ver cada `restore`).
    func restore(_ contents: BackupContents, sections: Set<BackupSection>) -> BackupRestoreSummary {
        var summary = BackupRestoreSummary()
        if sections.contains(.groups) {
            (summary.groupsCreated, summary.groupsUpdated) = groups.restore(groups: contents.groups)
        }
        if sections.contains(.subscriptions) { summary.subscriptions = groups.restore(subscriptions: contents.subscriptions) }
        if sections.contains(.blocked) { summary.blocked = library.restore(blocked: contents.blockedChannels) }
        if sections.contains(.history) {
            summary.history = library.restore(history: contents.history, watchLater: contents.watchLater, hidden: contents.hiddenVideos)
        }
        if sections.contains(.queue) { summary.queue = queue.restore(contents.queue, title: contents.queueTitle) }
        if sections.contains(.settings), let snapshot = contents.settings { summary.settings = settings.apply(snapshot) }
        return summary
    }
}

/// Lo que entró al restaurar, para el aviso.
struct BackupRestoreSummary: Equatable {
    var groupsCreated = 0
    var groupsUpdated = 0
    var subscriptions = 0
    var blocked = 0
    var history = 0
    var queue = 0
    var settings = 0

    var message: String {
        var parts: [String] = []
        if groupsCreated > 0 { parts.append(groupsCreated == 1 ? String(localized: "1 grupo nuevo") : String(localized: "\(groupsCreated) grupos nuevos")) }
        if groupsUpdated > 0 { parts.append(groupsUpdated == 1 ? String(localized: "1 grupo con canales nuevos") : String(localized: "\(groupsUpdated) grupos con canales nuevos")) }
        if subscriptions > 0 { parts.append(subscriptions == 1 ? String(localized: "1 suscripción") : String(localized: "\(subscriptions) suscripciones")) }
        if blocked > 0 { parts.append(blocked == 1 ? String(localized: "1 canal bloqueado") : String(localized: "\(blocked) canales bloqueados")) }
        if history > 0 { parts.append(history == 1 ? String(localized: "1 video del historial") : String(localized: "\(history) videos del historial")) }
        if queue > 0 { parts.append(queue == 1 ? String(localized: "1 video en la cola") : String(localized: "\(queue) videos en la cola")) }
        if settings > 0 { parts.append(settings == 1 ? String(localized: "1 ajuste") : String(localized: "\(settings) ajustes")) }
        return parts.isEmpty ? String(localized: "No había nada nuevo: todo lo del respaldo ya estaba en esta Mac")
                             : String(localized: "Se restauró: \(parts.joined(separator: ", "))")
    }
}

/// Respaldo de la app (fase 5b): exportar e importar el ZIP, el respaldo automático en iCloud Drive y los archivos para
/// otras apps (PocketTube, NewPipe). Como `BackupSettingsPresenter` de SmartTube, sin Google Drive.
@Observable
final class BackupService {
    /// Un respaldo leído que espera la hoja «Restaurar» (qué partes traer).
    var pending: PendingBackup?
    /// El último resultado, para Ajustes.
    private(set) var lastMessage: String?
    private(set) var lastICloudBackup: Date?
    private(set) var isWorking = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let defaults: UserDefaults
    /// `-GTiCloudCarpeta ruta`: otra carpeta en lugar de iCloud Drive (pruebas y capturas, sin tocar el iCloud de nadie).
    @ObservationIgnored let iCloudFolderOverride: URL?

    static let lastICloudKey = "backupICloudLast"
    /// Respaldos que se conservan en iCloud Drive (uno por día).
    static let iCloudKeep = 7

    struct PendingBackup: Identifiable {
        let id = UUID()
        var name: String
        var file: BackupFile
    }

    init(app: AppModel?, defaults: UserDefaults = .standard) {
        self.app = app
        self.defaults = defaults
        iCloudFolderOverride = defaults.string(forKey: "GTiCloudCarpeta").map { URL(fileURLWithPath: $0, isDirectory: true) }
        lastICloudBackup = defaults.object(forKey: Self.lastICloudKey) as? Date
    }

    private var stores: BackupStores? {
        app.map { BackupStores(library: $0.library, groups: $0.groups, queue: $0.queue, settings: $0.settings) }
    }

    static var appVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    // MARK: - Exportar

    func makeArchive() throws -> Data {
        guard let stores else { throw BackupArchive.Failure.unknown }
        return try BackupArchive.make(stores.contents(), appVersion: Self.appVersion)
    }

    /// Lo que va en el respaldo, para Ajustes.
    var summary: BackupContents? { stores?.contents() }

    func didExport(to url: URL?, error: Error?) {
        if let error {
            report(String(localized: "No se pudo guardar el respaldo: \(error.localizedDescription)"))
        } else if let url {
            report(String(localized: "Respaldo guardado en «\(url.lastPathComponent)»"))
        }
    }

    // MARK: - Importar

    /// Lee un ZIP de Glasstube o de SmartTube y abre la hoja para elegir qué restaurar.
    func open(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let file = try BackupArchive.read(data)
            guard !file.contents.sections.isEmpty else {
                report(String(localized: "«\(url.lastPathComponent)» no trae nada que se pueda restaurar"))
                return
            }
            pending = PendingBackup(name: url.lastPathComponent, file: file)
        } catch let failure as BackupArchive.Failure {
            report("«\(url.lastPathComponent)»: \(failure.description)")
        } catch {
            report(String(localized: "No se pudo leer «\(url.lastPathComponent)»: \(error.localizedDescription)"))
        }
    }

    /// Restaura las partes elegidas del respaldo pendiente.
    @discardableResult
    func restorePending(sections: Set<BackupSection>) -> String? {
        guard let pending, let stores else { return nil }
        self.pending = nil
        let summary = stores.restore(pending.file.contents, sections: sections)
        report(summary.message, seconds: 5)
        return summary.message
    }

    // MARK: - iCloud Drive

    /// La carpeta «Glasstube» de iCloud Drive. La app no está en el sandbox ni tiene contenedor de iCloud (eso pide un
    /// perfil de Apple): escribe en la carpeta de iCloud Drive de la persona, y macOS pide permiso la primera vez.
    var iCloudFolder: URL? {
        if let iCloudFolderOverride { return iCloudFolderOverride }
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: drive.path) ? drive.appendingPathComponent("Glasstube", isDirectory: true) : nil
    }

    var isICloudAvailable: Bool { iCloudFolder != nil }

    /// Guarda el respaldo de hoy en iCloud Drive (si ya había uno de hoy, lo reemplaza) y deja solo los `iCloudKeep` más
    /// nuevos de los que hizo Glasstube.
    @discardableResult
    func backupToICloud(now: Date = Date()) -> URL? {
        guard let folder = iCloudFolder else {
            report(String(localized: "iCloud Drive no está activado en esta Mac (Ajustes del Sistema › Apple ID › iCloud)"))
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try makeArchive()
            let target = folder.appendingPathComponent(BackupArchive.fileName(for: now))
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    writeError = error
                }
            }
            if let error = writeError ?? coordinationError { throw error }
            pruneICloud(folder)
            lastICloudBackup = now
            defaults.set(now, forKey: Self.lastICloudKey)
            report(String(localized: "Respaldo guardado en iCloud Drive › Glasstube › \(target.lastPathComponent)"))
            return target
        } catch {
            report(String(localized: "No se pudo guardar en iCloud Drive: \(error.localizedDescription)"))
            return nil
        }
    }

    /// Al abrir la app: si está activado y pasó un día.
    func backupToICloudIfDue(now: Date = Date()) {
        guard app?.settings.iCloudBackup == true, isICloudAvailable else { return }
        if let lastICloudBackup, now.timeIntervalSince(lastICloudBackup) < 20 * 3600 { return }
        backupToICloud(now: now)
    }

    func revealICloudFolder() {
        guard let folder = iCloudFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Los respaldos de Glasstube en iCloud Drive, del más nuevo al más viejo.
    func iCloudBackups() -> [URL] {
        guard let folder = iCloudFolder else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["Glasstube-respaldo-", "Glasstube-backup-"].contains(where: $0.lastPathComponent.hasPrefix) && $0.pathExtension == "zip" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func pruneICloud(_ folder: URL) {
        for old in iCloudBackups().dropFirst(Self.iCloudKeep) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: - Otras apps

    /// Grupos para PocketTube (y SmartTube, que importa ese formato).
    func pocketTubeData() -> Data? {
        app.map { ExternalExport.pocketTube(groups: $0.groups.groups) }
    }

    /// Suscripciones para NewPipe (y SmartTube). `includeGroups`: también los canales de los grupos.
    func newPipeData(includeGroups: Bool) -> Data? {
        guard let groups = app?.groups else { return nil }
        var channels = groups.subscriptions
        if includeGroups {
            for channel in groups.groups.flatMap(\.channels) where !channels.contains(where: { $0.id == channel.id }) {
                channels.append(channel)
            }
        }
        return ExternalExport.newPipe(channels: channels)
    }

    private func report(_ message: String, seconds: Double = 4) {
        lastMessage = message
        app?.show(banner: message, seconds: seconds)
        if Automation.shared.logsBackup { NSLog("Glasstube respaldo: \(message)") }
    }
}

/// Archivos que leen otras apps, en los mismos formatos que Glasstube y SmartTube importan (`ChannelGroupImport`).
nonisolated enum ExternalExport {
    /// PocketTube: cada grupo es una clave de la raíz con sus ids, y `ysc_collection` los nombra. Se escribe a mano para que
    /// los grupos queden en su orden (el importador de Glasstube los lee en el orden del archivo).
    static func pocketTube(groups: [ChannelGroup]) -> Data {
        var seen = Set<String>()
        let unique = groups.filter { seen.insert($0.title).inserted && $0.title.hasPrefix("ysc_") == false }
        var lines: [String] = []
        for group in unique {
            let ids = group.channels.map(\.id).filter(ChannelGroupImport.isChannelId).map(json).joined(separator: ",")
            lines.append("\t\(json(group.title)):[\(ids)]")
        }
        let names = unique.map { "\(json($0.title)):\(json($0.title))" }.joined(separator: ",")
        lines.append("\t\"ysc_collection\":{\(names)}")
        return Data(("{\n" + lines.joined(separator: ",\n") + "\n}\n").utf8)
    }

    /// NewPipe (Suscripciones › Exportar a archivo): `service_id` 0 es YouTube.
    static func newPipe(channels: [GroupChannel]) -> Data {
        let subscriptions: [[String: Any]] = channels.filter { ChannelGroupImport.isChannelId($0.id) }.map {
            ["service_id": 0, "url": "https://www.youtube.com/channel/\($0.id)", "name": $0.title ?? $0.id]
        }
        let root: [String: Any] = ["app_version": "0.27.6", "app_version_int": 1006, "subscriptions": subscriptions]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    private static func json(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}
