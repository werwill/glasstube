import Foundation

// Return YouTube Dislike (https://returnyoutubedislike.com): YouTube ocultó el número de "no me gusta" en 2021; esta API
// lo estima con los datos de antes de 2021 y los votos de sus usuarios. SmartTube la declara en `WatchNextApi`
// (`returnyoutubedislikeapi.com/votes`) aunque muestra un número calculado (likes × 0,032); aquí se usa la API.

/// Votos de un video según Return YouTube Dislike.
public struct VoteCounts: Codable, Sendable, Hashable {
    public var videoId: String
    public var likes: Int
    public var dislikes: Int
    /// De 1 a 5 (como las estrellas de antes).
    public var rating: Double?
    public var viewCount: Int?

    public init(videoId: String, likes: Int, dislikes: Int, rating: Double? = nil, viewCount: Int? = nil) {
        self.videoId = videoId
        self.likes = likes
        self.dislikes = dislikes
        self.rating = rating
        self.viewCount = viewCount
    }

    /// Parte de "me gusta" sobre el total (0…1).
    public var likeRatio: Double? {
        let total = likes + dislikes
        return total > 0 ? Double(likes) / Double(total) : nil
    }
}

/// Cliente de `returnyoutubedislikeapi.com/votes?videoId=…`, con caché en memoria.
public actor DislikeClient {
    static let endpoint = "https://returnyoutubedislikeapi.com/votes"

    public static let shared = DislikeClient()
    private var cache: [String: VoteCounts] = [:]

    public init() {}

    public func votes(videoId: String) async throws -> VoteCounts {
        if let cached = cache[videoId] { return cached }
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "videoId", value: videoId)]
        let (data, response) = try await HTTP.shared.request(components.url!, headers: ["User-Agent": "Glasstube"], timeout: 10)
        guard response.statusCode == 200 else {
            throw HTTPError(status: response.statusCode, url: Self.endpoint, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
        let votes = try Self.parse(data, videoId: videoId)
        cache[videoId] = votes
        return votes
    }

    nonisolated static func parse(_ data: Data, videoId: String) throws -> VoteCounts {
        struct Response: Decodable {
            @Lenient var likes: FlexibleInt?
            @Lenient var dislikes: FlexibleInt?
            @Lenient var rating: Double?
            @Lenient var viewCount: FlexibleInt?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let dislikes = response.dislikes?.value else { throw YTKitError.badResponse("Return YouTube Dislike sin dislikes") }
        return VoteCounts(videoId: videoId, likes: response.likes?.value ?? 0, dislikes: dislikes, rating: response.rating,
                          viewCount: response.viewCount?.value)
    }

    /// "18 K", "1,2 M": el número corto en el idioma del sistema (como los de YouTube).
    public nonisolated static func compact(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.notation(.compactName).locale(locale).precision(.significantDigits(1...2)))
    }
}
