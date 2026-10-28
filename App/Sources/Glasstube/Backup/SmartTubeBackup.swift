import Foundation
import YTKit

/// Lo que se puede traer de un respaldo de SmartTube (Ajustes › Respaldo › Respaldo local, el ZIP que deja en
/// `Documents/SmartTubeBackup/` o en Google Drive). `BackupAndRestoreManager` copia la carpeta de datos de la app tal cual:
///
///     data/<paquete>/Backup/shared_prefs/*.xml                 preferencias de Android (ajustes, en su propio formato)
///     data/<paquete>/Backup/files/app_prefs/<clave>            `AppPrefs.setData`: un archivo de texto por clave
///     data/<paquete>/Backup/files/yt_service_prefs/<clave>     `MediaServicePrefs.setData`
///
/// Cada clave de perfil lleva delante el nombre del perfil («anonymous» o el de la cuenta). Las que sirven aquí:
///
/// - `<perfil>_state_updater_data` (`VideoStateService`): el historial con posiciones, del más viejo al más nuevo.
///   Estados separados por `&si;`; cada uno `video&sf;posiciónMs&sf;duraciónMs&sf;velocidad`, y el video es
///   `Video.toString()`, 23 campos separados por `&vi;` (título en el 2, videoId en el 3, canal en el 6, «autor • vistas»
///   en el 14). Al final, `%OB%` y si el historial de YouTube estaba roto.
/// - `<perfil>_channel_group_data` (`ChannelGroupServiceImpl`): grupos separados por `%AR%`, cada uno
///   `id&sgi;título&sgi;ícono&sgi;canales&sgi;insignia`, con los canales separados por `&sga;` y cada canal
///   `título&ci;ícono&ci;idDelCanal&ci;…`. El grupo «1000» son las suscripciones sin cuenta; el «1001», avisos.
/// - `blocked_channel_data` (o con perfil, `BlockedChannelData`): `id&vi;nombre` separados por `%AR%`, y después de
///   `%OB%` el formato viejo (`id%PR%nombre`).
///
/// Las versiones viejas guardaban lo mismo como `<string name="clave">` en los XML de `shared_prefs`; se leen también.
/// Los ajustes de SmartTube no se traen: son de Android TV y se guardan en otro formato (posiciones en una cadena).
nonisolated struct SmartTubeBackup: Equatable {
    var groups: [ChannelGroup] = []
    var subscriptions: [GroupChannel] = []
    var blockedChannels: [BlockedChannel] = []
    /// Del más nuevo al más viejo, como el historial de Glasstube.
    var history: [SavedVideo] = []
    /// Entradas que no se pudieron usar (canales sin id UC…, videos sin id válido).
    var skipped = 0

    var isEmpty: Bool { groups.isEmpty && subscriptions.isEmpty && blockedChannels.isEmpty && history.isEmpty }

    /// ¿Parece un respaldo de SmartTube? (carpetas `shared_prefs` o `files/app_prefs` de una app de Android).
    static func looksLike(_ entries: [ZipArchive.Entry]) -> Bool {
        entries.contains { entry in
            let parts = entry.path.split(separator: "/")
            return parts.contains("shared_prefs") || parts.contains("app_prefs") || parts.contains("yt_service_prefs")
        }
    }

    /// `date`: la hora de la importación. SmartTube no guarda cuándo se vio cada video: el historial conserva su orden con
    /// horas inventadas un día antes de importar, así queda debajo de lo que ya había en esta Mac.
    static func parse(_ entries: [ZipArchive.Entry], date: Date = Date()) -> SmartTubeBackup {
        var values: [(key: String, value: String)] = []
        for entry in entries {
            let parts = entry.path.split(separator: "/").map(String.init)
            guard let name = parts.last else { continue }
            if parts.contains("shared_prefs"), name.hasSuffix(".xml") {
                values += PreferencesXML.strings(entry.data)
            } else if parts.count >= 2, ["app_prefs", "yt_service_prefs"].contains(parts[parts.count - 2]) {
                values.append((name, String(decoding: entry.data, as: UTF8.self)))
            }
        }

        var backup = SmartTubeBackup()
        var historySpecs: [String] = []
        for (key, value) in values {
            if key == "state_updater_data" || key.hasSuffix("_state_updater_data") {
                historySpecs.append(value)
            } else if key.hasSuffix("channel_group_data") {
                backup.addGroups(value)
            } else if key.hasSuffix("blocked_channel_data") {
                backup.addBlocked(value)
            }
        }
        backup.addHistory(historySpecs, date: date)
        return backup
    }

    // MARK: - Historial

    private mutating func addHistory(_ specs: [String], date: Date) {
        // Cada perfil es una lista del más viejo al más nuevo; se juntan y se quedan sin repetir, el último gana.
        var states: [(item: MediaItem, position: Double, duration: Double?)] = []
        for spec in specs {
            let list = Self.field(Self.split(spec, "%OB%"), 0) ?? ""
            for state in Self.split(list, "&si;") {
                let parts = Self.split(state, "&sf;")
                guard let video = Self.field(parts, 0), let item = Self.video(video) else {
                    skipped += 1
                    continue
                }
                let position = Double(Self.field(parts, 1) ?? "").map { $0 / 1000 } ?? 0
                let duration = Double(Self.field(parts, 2) ?? "").flatMap { $0 > 0 ? $0 / 1000 : nil }
                states.removeAll { $0.item.id == item.id }
                states.append((item, max(0, position), duration))
            }
        }
        let start = date.addingTimeInterval(-86_400)
        history = states.reversed().prefix(LocalLibrary.historyLimit).enumerated().map { index, state in
            var item = state.item
            if item.durationSeconds == nil, let duration = state.duration { item.durationSeconds = Int(duration) }
            return SavedVideo(item: item, position: state.position, duration: state.duration,
                              updatedAt: start.addingTimeInterval(-Double(index)))
        }
    }

    /// `Video.fromString`: 23 campos (las versiones viejas, de 10 en adelante); en los primeros respaldos, solo el id.
    static func video(_ spec: String) -> MediaItem? {
        let fields = split(spec, "&vi;")
        let videoId = fields.count >= 10 ? field(fields, 3) : field(fields, 0)
        guard let videoId, isVideoId(videoId) else { return nil }
        var item = MediaItem(kind: .video, title: field(fields, 2) ?? videoId, renderer: "smarttube")
        item.videoId = videoId
        if fields.count >= 10 {
            item.channelId = field(fields, 6).flatMap { ChannelGroupImport.isChannelId($0) ? $0 : nil }
            // «Canal • 1,2 M de vistas • hace 2 días»: el canal es lo primero.
            let subtitle = field(fields, 18) ?? field(fields, 14)
            item.author = subtitle.flatMap { $0.components(separatedBy: "•").first?.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 }
            item.isLive = field(fields, 20) == "true"
        }
        return item
    }

    // MARK: - Grupos y suscripciones

    private mutating func addGroups(_ data: String) {
        let list = Self.field(Self.split(data, "%OB%"), 0) ?? ""
        for spec in Self.split(list, "%AR%") {
            let parts = Self.split(spec, "&sgi;")
            guard let id = Self.field(parts, 0), let title = Self.field(parts, 1) else {
                skipped += 1
                continue
            }
            var channels: [GroupChannel] = []
            for itemSpec in Self.split(Self.field(parts, 3) ?? "", "&sga;") {
                let item = Self.split(itemSpec, "&ci;")
                guard let channelId = Self.field(item, 2), ChannelGroupImport.isChannelId(channelId) else {
                    skipped += 1
                    continue
                }
                guard !channels.contains(where: { $0.id == channelId }) else { continue }
                channels.append(GroupChannel(id: channelId, title: Self.field(item, 0), avatarURL: Self.field(item, 1).flatMap(Self.webURL)))
            }
            switch id {
            case "1000":
                // Suscripciones sin cuenta: en SmartTube, la más reciente primero, como en Glasstube.
                for channel in channels where !subscriptions.contains(where: { $0.id == channel.id }) { subscriptions.append(channel) }
            case "1001":
                break // avisos de canales con cuenta: no aplica
            default:
                if let index = groups.firstIndex(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) {
                    groups[index].channels += channels.filter { !groups[index].contains($0.id) }
                } else {
                    groups.append(ChannelGroup(id: "smarttube-\(id)", title: title, iconURL: Self.field(parts, 2).flatMap(Self.webURL),
                                               channels: channels))
                }
            }
        }
    }

    // MARK: - Bloqueados

    private mutating func addBlocked(_ data: String) {
        let parts = Self.split(data, "%OB%")
        var pairs: [(String?, String?)] = Self.split(Self.field(parts, 0) ?? "", "%AR%").map { spec in
            let channel = Self.split(spec, "&vi;")
            return (Self.field(channel, 0), Self.field(channel, 1))
        }
        // Formato viejo: `id%PR%nombre` separados por `%AR%`.
        pairs += Self.split(Self.field(parts, 1) ?? "", "%AR%").map { spec in
            let pair = Self.split(spec, "%PR%")
            return (Self.field(pair, 0), Self.field(pair, 1))
        }
        for (id, name) in pairs {
            guard let id, ChannelGroupImport.isChannelId(id) else {
                if id != nil || name != nil { skipped += 1 }
                continue
            }
            guard !blockedChannels.contains(where: { $0.id == id }) else { continue }
            blockedChannels.append(BlockedChannel(id: id, name: name ?? id))
        }
    }

    // MARK: - Ayudas (`Helpers` de SmartTube)

    /// `Helpers.split`: un texto vacío o de espacios es una lista vacía.
    static func split(_ text: String, _ separator: String) -> [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : text.components(separatedBy: separator)
    }

    /// `Helpers.parseStr`: «null» y lo que falta son nil (y aquí también lo vacío).
    static func field(_ fields: [String], _ index: Int) -> String? {
        guard fields.indices.contains(index) else { return nil }
        let value = fields[index]
        return value == "null" || value.isEmpty ? nil : value
    }

    static func isVideoId(_ text: String) -> Bool {
        text.count == 11 && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    private static func webURL(_ text: String) -> String? {
        text.hasPrefix("https://") || text.hasPrefix("http://") ? text : nil
    }
}

/// Las cadenas de un XML de `SharedPreferences` de Android (`<map><string name="clave">valor</string>…</map>`).
nonisolated private final class PreferencesXML: NSObject, XMLParserDelegate {
    private var values: [(key: String, value: String)] = []
    private var key: String?
    private var text = ""

    static func strings(_ data: Data) -> [(key: String, value: String)] {
        let delegate = PreferencesXML()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.values
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        key = element == "string" ? attributes["name"] : nil
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if key != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "string", let key { values.append((key, text)) }
        key = nil
    }
}
