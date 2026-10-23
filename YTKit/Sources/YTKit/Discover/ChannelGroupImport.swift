import Foundation

// Importar grupos de canales de otras apps, con los mismos formatos que acepta SmartTube (`ChannelGroupServiceImpl`,
// que prueba `PocketTubeService`, `GrayJayService` y `NewPipeService` en ese orden y se queda con el primero que lo
// entiende):
//
// - PocketTube (extensión de navegador): un objeto JSON; `ysc_collection` nombra los grupos y cada grupo es una clave de
//   la raíz con la lista de ids de canal (`{"Música": ["UC…", …], "ysc_collection": {"Música": "Música"}, …}`).
// - GrayJay: una lista de grupos, cada uno un objeto JSON (o, como lo exporta GrayJay, una cadena con el JSON dentro)
//   con `id`, `name`, `image.url` y `urls` (URL de canales de cualquier plataforma: solo cuentan los de YouTube).
// - NewPipe: `{"subscriptions": [{"service_id": 0, "url": "https://www.youtube.com/channel/UC…", "name": "…"}]}`. Solo
//   son las suscripciones: SmartTube las suma a sus suscripciones locales y no crea un grupo (`isSubscriptions`).

/// Un canal importado. PocketTube y GrayJay solo dan el id; el nombre y la foto llegan después (feed RSS, página).
public struct ImportedChannel: Codable, Sendable, Hashable {
    public var channelId: String
    public var title: String?

    public init(channelId: String, title: String? = nil) {
        self.channelId = channelId
        self.title = title
    }
}

public struct ImportedGroup: Codable, Sendable, Hashable {
    public var title: String
    public var iconURL: String?
    public var channels: [ImportedChannel]

    public init(title: String, iconURL: String? = nil, channels: [ImportedChannel]) {
        self.title = title
        self.iconURL = iconURL
        self.channels = channels
    }
}

public struct ChannelGroupImport: Sendable, Hashable {
    public enum Format: String, Sendable, Hashable {
        case pocketTube = "PocketTube", grayJay = "GrayJay", newPipe = "NewPipe"
    }

    public var format: Format
    public var groups: [ImportedGroup]
    /// Entradas que no son canales de YouTube (Rumble, LBRY… en GrayJay; otros servicios en NewPipe) o sin un id UC…
    public var skipped: Int

    /// NewPipe solo exporta las suscripciones: van a las suscripciones locales, no a un grupo (como en SmartTube).
    public var isSubscriptions: Bool { format == .newPipe }
    public var channelCount: Int { groups.reduce(0) { $0 + $1.channels.count } }

    public init(format: Format, groups: [ImportedGroup], skipped: Int = 0) {
        self.format = format
        self.groups = groups
        self.skipped = skipped
    }
    /// El formato que se reconozca (PocketTube, GrayJay, NewPipe), o nil.
    public static func parse(_ data: Data) -> ChannelGroupImport? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return pocketTube(json, raw: data) ?? grayJay(json) ?? newPipe(json)
    }

    // MARK: - Formatos

    static func pocketTube(_ json: Any, raw: Data) -> ChannelGroupImport? {
        guard let root = json as? [String: Any], let collection = root["ysc_collection"] as? [String: Any] else { return nil }
        // JSONSerialization pierde el orden de las claves: los grupos van en el orden en que aparecen en el archivo.
        let text = String(decoding: raw, as: UTF8.self)
        let names = collection.keys.sorted { position(of: $0, in: text) < position(of: $1, in: text) }
        var skipped = 0
        var groups: [ImportedGroup] = []
        for name in names {
            guard let ids = root[name] as? [Any] else { continue }
            var channels: [ImportedChannel] = []
            for case let id as String in ids {
                if isChannelId(id) { channels.append(ImportedChannel(channelId: id)) } else { skipped += 1 }
            }
            groups.append(ImportedGroup(title: name, channels: unique(channels)))
        }
        return ChannelGroupImport(format: .pocketTube, groups: groups, skipped: skipped)
    }

    static func grayJay(_ json: Any) -> ChannelGroupImport? {
        guard let list = json as? [Any], !list.isEmpty else { return nil }
        var skipped = 0
        var groups: [ImportedGroup] = []
        for element in list {
            // GrayJay exporta cada grupo como una cadena con su JSON (SmartTube la «arregla» quitando comillas).
            let object: [String: Any]?
            if let text = element as? String {
                object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            } else {
                object = element as? [String: Any]
            }
            guard let object, let name = object["name"] as? String else { continue }
            var channels: [ImportedChannel] = []
            for case let url as String in object["urls"] as? [Any] ?? [] {
                if let id = channelId(fromURL: url) { channels.append(ImportedChannel(channelId: id)) } else { skipped += 1 }
            }
            let icon = (object["image"] as? [String: Any])?["url"] as? String
            groups.append(ImportedGroup(title: name, iconURL: icon, channels: unique(channels)))
        }
        guard !groups.isEmpty else { return nil }
        return ChannelGroupImport(format: .grayJay, groups: groups, skipped: skipped)
    }

    static func newPipe(_ json: Any) -> ChannelGroupImport? {
        guard let root = json as? [String: Any], let subscriptions = root["subscriptions"] as? [Any] else { return nil }
        var skipped = 0
        var channels: [ImportedChannel] = []
        for case let entry as [String: Any] in subscriptions {
            // service_id 0 = YouTube (1 SoundCloud, 2 media.ccc.de, 3 PeerTube, 4 Bandcamp).
            let service = (entry["service_id"] as? NSNumber)?.intValue ?? 0
            guard service == 0, let url = entry["url"] as? String, let id = channelId(fromURL: url) else {
                skipped += 1
                continue
            }
            channels.append(ImportedChannel(channelId: id, title: entry["name"] as? String))
        }
        return ChannelGroupImport(format: .newPipe, groups: [ImportedGroup(title: "NewPipe", channels: unique(channels))],
                                  skipped: skipped)
    }

    // MARK: - Ayudas

    /// `UC` y 22 caracteres de base64 de URL.
    public static func isChannelId(_ text: String) -> Bool {
        text.count == 24 && text.hasPrefix("UC")
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// El id UC… de una URL de canal de YouTube (`/channel/UC…`, con o sin `www.`/`m.`, o el id solo). Los `@handle` y
    /// las URL de otras plataformas dan nil: para resolver un handle hace falta la red.
    public static func channelId(fromURL url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if isChannelId(trimmed) { return trimmed }
        guard let components = URLComponents(string: trimmed), let host = components.host?.lowercased(),
              host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "channel"), parts.indices.contains(index + 1), isChannelId(parts[index + 1]) else {
            return nil
        }
        return parts[index + 1]
    }

    private static func unique(_ channels: [ImportedChannel]) -> [ImportedChannel] {
        var seen = Set<String>()
        return channels.filter { seen.insert($0.channelId).inserted }
    }

    private static func position(of key: String, in text: String) -> Int {
        let escaped = (try? JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\(key)\""
        guard let range = text.range(of: escaped + ":") ?? text.range(of: escaped) else { return Int.max }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }
}
