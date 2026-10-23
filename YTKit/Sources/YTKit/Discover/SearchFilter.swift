import Foundation

/// Filtros de búsqueda de YouTube: el `params` de `/search` (el `sp=` de las URL de resultados), un protobuf
/// `{1: prioridad, 2: {1: fecha, 2: tipo, 3: duración, N: característica}}` en base64.
///
/// Los valores son los del diálogo «Filtros de búsqueda» que manda la interfaz WEB en
/// `header.searchHeaderRenderer.searchFilterButton` (leídos el 23-oct-2026): YouTube ya no ofrece «Última hora» ni el
/// orden por fecha de subida o por calificación (con `CAI=` devuelve lo mismo que sin filtro); el tipo «Shorts» (9) y
/// las duraciones «menos de 3 minutos» (4) y «de 3 a 20» (5) son nuevos. Los filtros se combinan: «esta semana + videos +
/// de 3 a 20 minutos» es `EgYIAxABGAU=`.
public struct SearchFilter: Codable, Sendable, Hashable {
    /// «Prioridad» (antes «Ordenar por»).
    public enum Priority: Int, Codable, Sendable, CaseIterable {
        case relevance = 0, popularity = 3
    }

    /// «Fecha de carga».
    public enum UploadDate: Int, Codable, Sendable, CaseIterable {
        case today = 2, week = 3, month = 4, year = 5
    }

    /// «Tipo».
    public enum ResultType: Int, Codable, Sendable, CaseIterable {
        case video = 1, shorts = 9, channel = 2, playlist = 3, movie = 4
    }

    /// «Duración».
    public enum Duration: Int, Codable, Sendable, CaseIterable {
        case underThree = 4, threeToTwenty = 5, overTwenty = 2
    }

    /// «Características»: el valor es el número de campo dentro del mensaje de filtros (siempre con 1).
    public enum Feature: Int, Codable, Sendable, CaseIterable, Comparable {
        case hd = 4, subtitles = 5, creativeCommons = 6, live = 8, uhd = 14, hdr = 25

        public static func < (lhs: Feature, rhs: Feature) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var priority: Priority
    public var uploadDate: UploadDate?
    public var type: ResultType?
    public var duration: Duration?
    public var features: Set<Feature>

    public init(priority: Priority = .relevance, uploadDate: UploadDate? = nil, type: ResultType? = nil,
                duration: Duration? = nil, features: Set<Feature> = []) {
        self.priority = priority
        self.uploadDate = uploadDate
        self.type = type
        self.duration = duration
        self.features = features
    }

    /// Sin filtros: la búsqueda de siempre.
    public static let none = SearchFilter()

    public var isEmpty: Bool { self == .none }

    /// Cuántos filtros hay puestos (la prioridad cuenta si no es «Relevancia»).
    public var activeCount: Int {
        (priority == .relevance ? 0 : 1) + [uploadDate != nil, type != nil, duration != nil].filter { $0 }.count + features.count
    }

    /// El `params` de `/search`, o nil sin filtros.
    public var params: String? {
        guard !isEmpty else { return nil }
        var writer = ProtoWriter()
        if priority != .relevance { writer.int(1, priority.rawValue) }
        if uploadDate != nil || type != nil || duration != nil || !features.isEmpty {
            writer.message(2) { filters in
                filters.int(1, uploadDate?.rawValue)
                filters.int(2, type?.rawValue)
                filters.int(3, duration?.rawValue)
                for feature in features.sorted() { filters.int(feature.rawValue, 1) }
            }
        }
        return writer.data.base64EncodedString()
    }

    /// Lee un `params` (también con `%3D` en lugar de `=`, como llega en las URL y en los endpoints de YouTube). Nil si no
    /// es un filtro de búsqueda que se conozca.
    public init?(params: String) {
        let text = params.removingPercentEncoding ?? params
        guard let data = Data(base64Encoded: text), let fields = try? ProtoFields(data) else { return nil }
        self.init()
        if let value = fields.int(1) {
            guard let priority = Priority(rawValue: Int(value)) else { return nil }
            self.priority = priority
        }
        if let inner = try? fields.message(2) {
            if let value = inner.int(1) { uploadDate = UploadDate(rawValue: Int(value)) }
            if let value = inner.int(2) { type = ResultType(rawValue: Int(value)) }
            if let value = inner.int(3) { duration = Duration(rawValue: Int(value)) }
            features = Set(Feature.allCases.filter { inner.int($0.rawValue) == 1 })
        }
    }
}

extension YouTubeService {
    /// Resultados con filtros (`getSearch(query, options)` de SmartTube).
    public func search(_ query: String, filter: SearchFilter) async throws -> BrowsePage {
        try await search(query, params: filter.params)
    }
}
