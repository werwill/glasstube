#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tramo de SponsorBlock (patrocinio, intro, autopromoción…) de un video.
public nonisolated struct SponsorSegment: Sendable, Hashable, Identifiable {
    public var start: Double
    public var end: Double
    public var category: String
    public var uuid: String

    public init(start: Double, end: Double, category: String, uuid: String) {
        self.start = start
        self.end = end
        self.category = category
        self.uuid = uuid
    }

    public var id: String { uuid }

    /// "Saltar patrocinio", "Saltar intro"… (las categorías de SmartTube).
    public var skipTitle: String {
        switch category {
        case "sponsor": "Saltar patrocinio"
        case "selfpromo": "Saltar autopromoción"
        case "interaction": "Saltar recordatorio"
        case "intro": "Saltar intro"
        case "outro": "Saltar créditos"
        case "preview": "Saltar avance"
        case "music_offtopic": "Saltar parte sin música"
        case "filler": "Saltar relleno"
        default: "Saltar segmento"
        }
    }
}

/// Un color sin depender de la interfaz (SwiftUI en la Mac, `Windows.UI.Color` en WinUI).
public nonisolated struct RGBColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

extension SponsorSegment {
    /// Color de la barra en RGB de 0 a 1 (los de SponsorBlock, en la paleta de la app de Mac); la interfaz los dibuja con
    /// borde oscuro para que se distingan sobre cualquier imagen.
    public var color: RGBColor {
        switch category {
        case "sponsor": RGBColor(red: 0.19, green: 0.82, blue: 0.35)
        case "selfpromo": RGBColor(red: 1.0, green: 0.84, blue: 0.04)
        case "interaction": RGBColor(red: 0.75, green: 0.35, blue: 0.95)
        case "intro": RGBColor(red: 0.39, green: 0.82, blue: 1.0)
        case "outro": RGBColor(red: 0.04, green: 0.52, blue: 1.0)
        case "preview": RGBColor(red: 0.35, green: 0.78, blue: 0.98)
        case "music_offtopic": RGBColor(red: 1.0, green: 0.62, blue: 0.04)
        default: RGBColor(red: 0.6, green: 0.6, blue: 0.65)
        }
    }
}

/// Cliente de la API pública de SponsorBlock (sponsor.ajay.app), sin cuenta. Usa la consulta por prefijo de hash
/// (`/api/skipSegments/<4 primeros hex de sha256(videoId)>`) para no enviar el id del video, como recomienda la API.
public actor SponsorBlockClient {
    public static let categories = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "music_offtopic"]

    private var cache: [String: [SponsorSegment]] = [:]

    public init() {}

    public func segments(videoId: String) async -> [SponsorSegment] {
        if let cached = cache[videoId] { return cached }
        let hash = SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(hash.prefix(4))")!
        let categories = "[" + Self.categories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        components.queryItems = [URLQueryItem(name: "categories", value: categories), URLQueryItem(name: "actionTypes", value: "[\"skip\"]")]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Glasstube", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            cache[videoId] = []
            return []
        }
        let raw = entries.first { ($0["videoID"] as? String) == videoId }?["segments"] as? [[String: Any]] ?? []
        let segments = raw.compactMap { entry -> SponsorSegment? in
            guard let bounds = entry["segment"] as? [Double], bounds.count == 2, bounds[1] > bounds[0],
                  let category = entry["category"] as? String else { return nil }
            return SponsorSegment(start: bounds[0], end: bounds[1], category: category, uuid: entry["UUID"] as? String ?? UUID().uuidString)
        }.sorted { $0.start < $1.start }
        cache[videoId] = segments
        return segments
    }
}
