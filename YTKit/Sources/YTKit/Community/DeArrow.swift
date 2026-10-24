#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: la misma API de CryptoKit fuera de Apple
#endif
import Foundation

// DeArrow (https://dearrow.ajay.app, de los autores de SponsorBlock): títulos y miniaturas que vota la comunidad en
// lugar de los "clickbait". Como `DeArrowService` de SmartTube (`youtubeapi/dearrow`), pero con la consulta por prefijo
// de hash (`/api/branding/<4 primeros hex de sha256(videoId)>`), que no envía el id del video: responde con todos los
// videos de ese prefijo (~150, ~17 KB) y se elige el pedido. La miniatura sí lleva el id: es una imagen que genera
// `dearrow-thumb.ajay.app` en el segundo votado (igual en SmartTube y en la extensión).
//
// Qué se usa (API_Docs/DeArrow): los títulos y miniaturas vienen ordenados del mejor al peor; se descartan los de votos
// negativos que no estén bloqueados; si el mejor es el original, no se cambia nada. En los títulos, `>` marca palabras
// que el formateador de la extensión no toca y se quita (SmartTube, MediaServiceCore#9).

/// Título y miniatura de la comunidad para un video (`DeArrowData` de SmartTube). Nil = se queda el de YouTube.
public struct DeArrowBranding: Codable, Sendable, Hashable {
    public var videoId: String
    public var title: String?
    /// Segundo del video que la comunidad eligió como miniatura.
    public var thumbnailTime: Double?

    public init(videoId: String, title: String?, thumbnailTime: Double?) {
        self.videoId = videoId
        self.title = title
        self.thumbnailTime = thumbnailTime
    }

    /// `dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=…&time=…` (la genera el servidor; puede tardar o fallar).
    public var thumbnailURL: URL? {
        guard let thumbnailTime else { return nil }
        var components = URLComponents(string: DeArrowClient.thumbnailEndpoint)!
        components.queryItems = [URLQueryItem(name: "videoID", value: videoId), URLQueryItem(name: "time", value: String(thumbnailTime))]
        return components.url
    }

    public var isEmpty: Bool { title == nil && thumbnailTime == nil }
}

/// Respuesta de `/api/branding` para un video.
struct DeArrowBrandingList: Decodable, Sendable {
    struct Title: Decodable, Sendable {
        @Lenient var title: String?
        @Lenient var original: Bool?
        @Lenient var votes: Int?
        @Lenient var locked: Bool?
    }
    struct Thumbnail: Decodable, Sendable {
        @Lenient var timestamp: Double?
        @Lenient var original: Bool?
        @Lenient var votes: Int?
        @Lenient var locked: Bool?
    }
    @Lenient var titles: [Title]?
    @Lenient var thumbnails: [Thumbnail]?

    func branding(videoId: String) -> DeArrowBranding {
        let title = (titles ?? []).first { ($0.votes ?? 0) >= 0 || $0.locked == true }
        let thumbnail = (thumbnails ?? []).first { ($0.votes ?? 0) >= 0 || $0.locked == true }
        var text = title?.original == true ? nil : title?.title?.replacingOccurrences(of: ">", with: "")
        text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if text?.isEmpty == true { text = nil }
        let time = thumbnail?.original == true ? nil : thumbnail?.timestamp
        return DeArrowBranding(videoId: videoId, title: text, thumbnailTime: time)
    }
}

/// Cliente de DeArrow con caché en memoria. Los pedidos simultáneos del mismo prefijo se juntan en uno.
public actor DeArrowClient {
    static let brandingEndpoint = "https://sponsor.ajay.app/api/branding"
    static let thumbnailEndpoint = "https://dearrow-thumb.ajay.app/api/v1/getThumbnail"

    public static let shared = DeArrowClient()

    private var cache: [String: DeArrowBranding] = [:]
    private var inFlight: [String: Task<[String: DeArrowBranding], Never>] = [:]
    /// Prefijos ya pedidos: un video de un prefijo pedido que no vino es que DeArrow no tiene nada para él.
    private var fetchedPrefixes: Set<String> = []
    private let maxConcurrent = 6

    public init() {}

    /// Lo que DeArrow tiene para un video (vacío si nada o si falla la red).
    public func branding(for videoId: String) async -> DeArrowBranding {
        await branding(for: [videoId])[videoId] ?? DeArrowBranding(videoId: videoId, title: nil, thumbnailTime: nil)
    }

    /// Varios videos a la vez (una petición por prefijo distinto, a lo más 6 en paralelo).
    public func branding(for videoIds: [String]) async -> [String: DeArrowBranding] {
        var result: [String: DeArrowBranding] = [:]
        var missing: [String: [String]] = [:]
        for id in Set(videoIds) {
            if let cached = cache[id] {
                result[id] = cached
            } else {
                missing[Self.prefix(for: id), default: []].append(id)
            }
        }
        let prefixes = Array(missing.keys)
        var index = 0
        while index < prefixes.count {
            let batch = prefixes[index..<min(prefixes.count, index + maxConcurrent)]
            index += maxConcurrent
            let tasks = batch.map { prefix in (prefix, task(for: prefix)) }
            for (prefix, task) in tasks {
                let found = await task.value
                for id in missing[prefix] ?? [] {
                    let branding = found[id] ?? DeArrowBranding(videoId: id, title: nil, thumbnailTime: nil)
                    if fetchedPrefixes.contains(prefix) { cache[id] = branding }
                    result[id] = branding
                }
            }
        }
        return result
    }

    private func task(for prefix: String) -> Task<[String: DeArrowBranding], Never> {
        if let existing = inFlight[prefix] { return existing }
        let task = Task<[String: DeArrowBranding], Never> {
            let fetched = await Self.fetch(prefix: prefix)
            self.finish(prefix: prefix, fetched: fetched)
            return fetched ?? [:]
        }
        inFlight[prefix] = task
        return task
    }

    private func finish(prefix: String, fetched: [String: DeArrowBranding]?) {
        inFlight[prefix] = nil
        guard let fetched else { return }
        fetchedPrefixes.insert(prefix)
        // Se guardan todos los del prefijo: es probable que salgan en la misma página.
        for (id, branding) in fetched { cache[id] = branding }
        if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
    }

    /// Los 4 primeros hex de sha256(videoId), como en SponsorBlock.
    public nonisolated static func prefix(for videoId: String) -> String {
        SHA256.hash(data: Data(videoId.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    /// `GET /api/branding/<prefijo>`: `{videoId: {titles, thumbnails, …}}`. 404 = ningún video de ese prefijo tiene datos.
    nonisolated static func fetch(prefix: String) async -> [String: DeArrowBranding]? {
        guard let url = URL(string: "\(brandingEndpoint)/\(prefix)") else { return nil }
        do {
            let (data, response) = try await HTTP.shared.request(url, headers: ["User-Agent": "Glasstube"], timeout: 10)
            if response.statusCode == 404 { return [:] }
            guard response.statusCode == 200 else { return nil }
            return try parse(data)
        } catch {
            Log.debug("DeArrow \(prefix): \(error)")
            return nil
        }
    }

    /// Respuesta por prefijo → lo que hay para cada video.
    nonisolated static func parse(_ data: Data) throws -> [String: DeArrowBranding] {
        let all = try JSONDecoder().decode([String: DeArrowBrandingList].self, from: data)
        var result: [String: DeArrowBranding] = [:]
        for (id, list) in all { result[id] = list.branding(videoId: id) }
        return result
    }

    /// Respuesta de `/api/branding?videoID=…` (un solo video).
    nonisolated static func parseSingle(_ data: Data, videoId: String) throws -> DeArrowBranding {
        try JSONDecoder().decode(DeArrowBrandingList.self, from: data).branding(videoId: videoId)
    }
}
