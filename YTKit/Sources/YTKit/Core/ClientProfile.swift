import Foundation

/// Perfil de cliente de Innertube (equivalente a `AppClient` de SmartTube), cargado de `clients.json`.
public struct ClientProfile: Codable, Sendable, Hashable {
    public enum PoTokenKind: String, Codable, Sendable { case web, tv }
    public enum PlayerVariant: String, Codable, Sendable { case tv, tcl, main }

    public let id: String
    public let clientName: String
    public let clientVersion: String
    public let clientNameId: String
    public let userAgent: String
    public var referer: String?
    public var clientScreen: String?
    public var deviceMake: String?
    public var deviceModel: String?
    public var osName: String?
    public var osVersion: String?
    public var androidSdkVersion: String?
    public var params: String?
    public var embedded: Bool?
    public var poToken: PoTokenKind?
    public var playerVariant: PlayerVariant?
    public var note: String?

    public var isTV: Bool { id.hasPrefix("TV") }
    public var isEmbedded: Bool { embedded ?? false }
    public var requiresPoToken: Bool { poToken != nil }

    /// `extractBrowserInfo` de AppClient.kt: el primer navegador conocido que aparezca en el User-Agent.
    public var browser: (name: String, version: String)? {
        for name in ["SamsungBrowser", "LG Browser", "Cobalt", "Chrome", "Safari"] {
            guard userAgent.range(of: name, options: .caseInsensitive) != nil,
                  let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: name) + "/([a-zA-Z0-9.-]+)"),
                  let match = regex.firstMatch(in: userAgent, range: NSRange(userAgent.startIndex..., in: userAgent)),
                  let range = Range(match.range(at: 1), in: userAgent)
            else { continue }
            return (name, String(userAgent[range]))
        }
        return nil
    }
}

public struct ClientCatalog: Codable, Sendable {
    public let version: Int
    public let source: String
    public let rotation: [String]
    public let defaultStart: String
    public let clients: [ClientProfile]

    public static func load(from url: URL? = nil) throws -> ClientCatalog {
        let fileURL = url ?? Bundle.module.url(forResource: "clients", withExtension: "json")!
        return try JSONDecoder().decode(ClientCatalog.self, from: Data(contentsOf: fileURL))
    }

    public func profile(_ id: String) -> ClientProfile? {
        clients.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Rotación cíclica de `VideoInfoService.firstInfoWith`: empieza en `start` y recorre la lista hasta volver a él.
    public func rotation(startingAt start: String?) -> [ClientProfile] {
        let order = rotation.compactMap(profile)
        guard let start, let index = order.firstIndex(where: { $0.id.caseInsensitiveCompare(start) == .orderedSame }) else {
            return order
        }
        return Array(order[index...] + order[..<index])
    }
}
