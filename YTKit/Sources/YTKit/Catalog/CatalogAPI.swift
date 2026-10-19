import Foundation

/// Idioma y región que se le piden a YouTube (`hl`, `gl`). Por omisión, los del sistema; para español de América
/// se pide `es-419` (con `es` YouTube responde en español de España: "vídeos").
public struct CatalogLocale: Sendable, Hashable {
    public var language: String
    public var region: String

    public init(language: String, region: String) {
        self.language = language
        self.region = region
    }

    public static var current: CatalogLocale {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier ?? "US"
        return CatalogLocale(language: language == "es" && region != "ES" ? "es-419" : language, region: region)
    }
}

/// `visitorData` anónimo (`/youtubei/v1/visitor_id`), pedido una vez y compartido por todas las peticiones del catálogo,
/// como `AppService.getVisitorData()` en SmartTube.
actor VisitorStore {
    private var task: Task<String?, Never>?
    private let catalog: ClientCatalog

    init(catalog: ClientCatalog) { self.catalog = catalog }

    func visitorData() async -> String? {
        if let task { return await task.value }
        let catalog = catalog
        let task = Task<String?, Never> {
            guard let web = catalog.profile("WEB") else { return nil }
            return try? await Innertube().fetchVisitorData(web: web)
        }
        self.task = task
        return await task.value
    }
}

/// Peticiones de catálogo a Innertube (`/browse`, `/search`, `/next`, `/navigation/resolve_url`) con el cliente de TV
/// o el de WEB. Reproduce `PostDataHelper` + `AppClient.browseTemplate` de SmartTube: el cuerpo base de `QueryBuilder`
/// y, en TV, el `tvAppInfo` que pide la interfaz de TV completa (`POST_DATA_BROWSE_TV`).
final class CatalogAPI: Sendable {
    /// Con qué identidad va una petición.
    enum Authorization: Sendable {
        /// La cuenta elegida si hay sesión; si no, anónima.
        case session
        /// Siempre anónima (aunque haya sesión).
        case anonymous
        /// Exige sesión: sin cuenta lanza `YTKitError.signInRequired`.
        case required(String)
        /// Cabeceras dadas (lo usa `AccountManager` para `accounts_list` de una sesión concreta).
        case headers([String: String])
    }

    let catalog: ClientCatalog
    let locale: CatalogLocale
    let visitor: VisitorStore
    /// Sesión de YouTube (nil = YTKit sin cuentas).
    let session: AccountManager?

    init(catalog: ClientCatalog, locale: CatalogLocale, session: AccountManager? = nil) {
        self.catalog = catalog
        self.locale = locale
        self.session = session
        visitor = VisitorStore(catalog: catalog)
    }

    /// Cabeceras de autorización para `auth`. Nunca se registran.
    ///
    /// La sesión es de la app de TV: YouTube solo la acepta con el cliente TVHTML5. Con el cliente WEB responde HTTP 400
    /// (`INVALID_ARGUMENT`) a cualquier petición con `Authorization` (comprobado el 15-oct-2026 en browse y next), así
    /// que en WEB `.session` va anónima y `.required` es un error de programación.
    func authorizationHeaders(_ auth: Authorization, surface: Surface) async throws -> [String: String] {
        switch auth {
        case .anonymous: return [:]
        case .headers(let headers): return headers
        case .session:
            // Solo si ya se sabe que hay sesión: no se espera a leer el Llavero (ver `AccountManager.knownSignedIn`).
            guard surface == .tv, session?.knownSignedIn == true else { return [:] }
            return try await session?.authorizationHeaders() ?? [:]
        case .required(let what):
            guard surface == .tv else { throw YTKitError.notAvailable("\(what): la sesión de TV solo vale con el cliente TV") }
            guard let headers = try await session?.authorizationHeaders() else { throw YTKitError.signInRequired(what) }
            return headers
        }
    }

    /// Hay una cuenta elegida (sin pedir un access token ni esperar al Llavero: mientras no se ha leído, no). Cuando la
    /// sesión aparece, `AccountManager.updates()` avisa y la app vuelve a pedir sus páginas.
    var isSignedIn: Bool {
        get async { session?.knownSignedIn ?? false }
    }

    func profile(_ surface: Surface) throws -> ClientProfile {
        let id = surface == .tv ? "TV" : "WEB"
        guard let profile = catalog.profile(id) else { throw YTKitError.badResponse("clients.json no tiene el perfil \(id)") }
        return profile
    }

    func body(surface: Surface, visitorData: String?, extra: [String: Any]) throws -> [String: Any] {
        let profile = try profile(surface)
        var client = Innertube.clientChunk(profile, visitorData: visitorData, livingRoomPoTokenId: nil)
        client["hl"] = locale.language
        client["gl"] = locale.region
        client["acceptLanguage"] = locale.language
        client["acceptRegion"] = locale.region
        if surface == .tv {
            // TV_APP_QUALITY_FULL_ANIMATION separa los Shorts de las demás filas (AppClient.kt).
            client["tvAppInfo"] = ["appQuality": "TV_APP_QUALITY_FULL_ANIMATION", "zylonLeftNav": true]
            client["webpSupport"] = false
            client["animatedWebpSupport"] = true
        }
        var body: [String: Any] = [
            "context": ["client": client, "user": ["enableSafetyMode": false, "lockedSafetyMode": false]],
            "racyCheckOk": true,
            "contentCheckOk": true,
        ]
        body.merge(extra) { _, new in new }
        return body
    }

    /// POST a `/youtubei/v1/<path>`; devuelve el cuerpo crudo (lo decodifica quien llama, en el hilo de pila grande).
    func post(_ path: String, surface: Surface, _ extra: [String: Any], auth: Authorization = .session) async throws -> Data {
        let authorization = try await authorizationHeaders(auth, surface: surface)
        let (data, status) = try await send(path, surface: surface, extra, authorization: authorization)
        if status == 401, !authorization.isEmpty, case .session = auth, let session {
            // Access token vencido o revocado a medias: se pide otro una vez.
            await session.invalidateAccessToken()
            return try await post(path, surface: surface, extra, auth: .required(path))
        }
        guard status == 200 else {
            let url = "https://www.youtube.com/youtubei/v1/\(path)"
            throw HTTPError(status: status, url: url, body: String(decoding: data.prefix(400), as: UTF8.self))
        }
        return data
    }

    private func send(_ path: String, surface: Surface, _ extra: [String: Any], authorization: [String: String]) async throws -> (Data, Int) {
        let profile = try profile(surface)
        let visitorData = await visitor.visitorData()
        let payload = try JSONSerialization.data(withJSONObject: body(surface: surface, visitorData: visitorData, extra: extra))
        var headers = [
            "Content-Type": "application/json",
            "User-Agent": profile.userAgent,
            "X-Youtube-Client-Name": profile.clientNameId,
            "X-Youtube-Client-Version": profile.clientVersion,
            "Origin": "https://www.youtube.com",
            "Referer": profile.referer ?? "https://www.youtube.com/",
            "Accept-Language": locale.language,
        ]
        if let visitorData { headers["X-Goog-Visitor-Id"] = visitorData }
        headers.merge(authorization) { _, new in new }
        let url = URL(string: "https://www.youtube.com/youtubei/v1/\(path)?prettyPrint=false")!
        let (data, response) = try await HTTP.shared.request(url, method: "POST", headers: headers, body: payload)
        return (data, response.statusCode)
    }

    func post(_ api: Continuation.API, surface: Surface, _ extra: [String: Any], auth: Authorization = .session) async throws -> Data {
        try await post(api.rawValue, surface: surface, extra, auth: auth)
    }

    /// `@handle`, URL de canal o id → `browseId` (UC…), con `/navigation/resolve_url` del cliente WEB.
    func resolveChannelId(_ input: String) async throws -> String {
        if input.hasPrefix("UC"), input.count == 24 { return input }
        var url = input
        if input.hasPrefix("@") { url = "https://www.youtube.com/\(input)" }
        else if !input.hasPrefix("http") { url = "https://www.youtube.com/\(input)" }
        let data = try await post("navigation/resolve_url", surface: .web, ["url": url], auth: .anonymous)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let endpoint = json?["endpoint"] as? [String: Any]
        guard let browseId = (endpoint?["browseEndpoint"] as? [String: Any])?["browseId"] as? String else {
            throw YTKitError.notAvailable("no se encontró el canal \(input)")
        }
        return browseId
    }
}

/// Sugerencias de búsqueda (`SearchApi2.TAGS_URL` de SmartTube): `clients1.google.com/complete/search` con el
/// cliente `youtube-lr` (el de las TV). La respuesta es JSON con el prefijo anti-XSSI `)]}'`.
enum SearchSuggestions {
    static func url(query: String, locale: CatalogLocale) -> URL {
        var components = URLComponents(string: "https://clients1.google.com/complete/search")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "youtube-lr"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "xhr", value: "t"),
            URLQueryItem(name: "oe", value: "utf-8"),
            URLQueryItem(name: "xssi", value: "t"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "hl", value: locale.language),
            URLQueryItem(name: "gl", value: locale.region),
        ]
        return components.url!
    }

    /// `$[1][*][0]` de la respuesta (como `SearchTags.java`).
    static func parse(_ data: Data) throws -> [String] {
        var text = String(decoding: data, as: UTF8.self)
        if let newline = text.firstIndex(of: "\n"), text.hasPrefix(")]}'") {
            text = String(text[text.index(after: newline)...])
        }
        guard let array = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              array.count > 1, let entries = array[1] as? [Any] else {
            throw YTKitError.badResponse("sugerencias con forma desconocida")
        }
        return entries.compactMap { ($0 as? [Any])?.first as? String }
    }
}
