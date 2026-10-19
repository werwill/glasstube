import Foundation

// Inicio de sesión de la app de TV de YouTube: OAuth 2.0 para dispositivos de entrada limitada (RFC 8628), como
// `auth/V2/AuthService` + `AuthApiHelper` de SmartTube. La app pide un código, la persona lo escribe en
// youtube.com/activate con su cuenta y la app sondea hasta recibir el refresh token. YTKit nunca ve contraseñas ni
// cookies; los tokens viven en el Llavero (`CredentialStore`) y nunca se registran.

/// Código que la persona escribe en `verificationURL` (`UserCode` de SmartTube). `deviceCode` es secreto: con él se
/// recoge el token, así que no se muestra ni se guarda.
public struct DeviceCode: Sendable {
    /// "KFY-NNL-STYL".
    public let userCode: String
    /// youtube.com/activate (Google devuelve google.com/device; las dos sirven).
    public let verificationURL: URL
    public let expiresAt: Date
    /// Segundos entre sondeos que pide Google.
    public let interval: Int
    let deviceCode: String
    let client: OAuthClientCredentials
}

/// `client_id` y `client_secret` de la app de TV. No son de la persona: YouTube los publica en el `base.js` de
/// youtube.com/tv, de donde los saca SmartTube (`ClientData`).
struct OAuthClientCredentials: Sendable, Codable, Equatable {
    let clientId: String
    let clientSecret: String
}

/// Respuesta de `/o/oauth2/token`. Contiene secretos: nunca se imprime (no es `CustomStringConvertible`).
struct TokenGrant: Sendable {
    let accessToken: String
    let tokenType: String
    let expiresIn: TimeInterval
    let refreshToken: String?
}

public enum AuthError: Error, CustomStringConvertible, Sendable, Equatable {
    /// El código venció antes de que lo escribieran.
    case codeExpired
    /// La persona rechazó el acceso en la página de activación.
    case accessDenied
    /// Google ya no acepta el refresh token (se revocó desde la cuenta o se cerró la sesión en otro lado).
    case revoked
    /// No se encontró el `client_id` de la app de TV en youtube.com/tv.
    case clientNotFound
    /// Google rechazó la petición con este código de error de OAuth.
    case rejected(String)
    /// No hay ninguna cuenta con sesión iniciada.
    case notSignedIn

    public var description: String {
        switch self {
        case .codeExpired: return "el código venció antes de autorizarlo"
        case .accessDenied: return "se rechazó el acceso en la página de activación"
        case .revoked: return "Google ya no acepta esta sesión; hay que volver a iniciarla"
        case .clientNotFound: return "no se encontró el client_id de la app de TV de YouTube"
        case .rejected(let error): return "Google rechazó la petición (\(error))"
        case .notSignedIn: return "no hay ninguna sesión iniciada"
        }
    }
}

/// Lo que `AccountManager` necesita de OAuth (las pruebas usan uno falso, sin red).
protocol TokenService: Sendable {
    func requestDeviceCode(deviceId: String) async throws -> DeviceCode
    func waitForGrant(_ code: DeviceCode) async throws -> TokenGrant
    func refresh(_ refreshToken: String) async throws -> TokenGrant
    func revoke(_ token: String) async throws
}

/// Endpoints de OAuth de la app de TV (`AuthApi` de SmartTube: `www.youtube.com/o/oauth2/…`, cuerpo JSON).
struct OAuthClient: TokenService {
    static let deviceCodeURL = URL(string: "https://www.youtube.com/o/oauth2/device/code")!
    static let tokenURL = URL(string: "https://www.youtube.com/o/oauth2/token")!
    static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
    /// `AuthApiHelper.APP_SCOPE`.
    static let scope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
    /// `AuthApiHelper.GRANT_TYPE_DEFAULT` (el de la app de TV, anterior al estándar `urn:ietf:…:device_code`).
    static let deviceGrantType = "http://oauth.net/grant_type/device/1.0"
    static let userAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"

    let http: HTTP
    let credentials: ClientCredentialsCache

    init(http: HTTP = .shared, credentials: ClientCredentialsCache = .shared) {
        self.http = http
        self.credentials = credentials
    }

    // MARK: - Código de dispositivo

    /// `getUserCode`. `deviceId` identifica a esta instalación (SmartTube usa un UUID guardado).
    func requestDeviceCode(deviceId: String) async throws -> DeviceCode {
        let client = try await credentials.get()
        let json = try await postJSON(Self.deviceCodeURL, [
            "client_id": client.clientId,
            "device_id": deviceId,
            "model_name": "ytlr::",
            "scope": Self.scope,
        ])
        guard let userCode = json["user_code"] as? String, let deviceCode = json["device_code"] as? String else {
            throw AuthError.rejected(json["error"] as? String ?? "sin user_code")
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 1800
        let interval = (json["interval"] as? NSNumber)?.intValue ?? 5
        return DeviceCode(userCode: userCode, verificationURL: URL(string: "https://www.youtube.com/activate")!,
                          expiresAt: Date().addingTimeInterval(expiresIn), interval: max(interval, 1),
                          deviceCode: deviceCode, client: client)
    }

    /// Sondea `/token` hasta que la persona autoriza (`getAccessTokenWait`). Se cancela con la tarea.
    func waitForGrant(_ code: DeviceCode) async throws -> TokenGrant {
        var interval = code.interval
        while Date() < code.expiresAt {
            try await Task.sleep(for: .seconds(interval))
            let json = try await postJSON(Self.tokenURL, [
                "code": code.deviceCode,
                "client_id": code.client.clientId,
                "client_secret": code.client.clientSecret,
                "grant_type": Self.deviceGrantType,
            ])
            if let grant = Self.grant(json), grant.refreshToken != nil { return grant }
            switch json["error"] as? String {
            case "authorization_pending", nil: continue
            case "slow_down": interval += 5
            case "expired_token": throw AuthError.codeExpired
            case "access_denied": throw AuthError.accessDenied
            case let other?: throw AuthError.rejected(other)
            }
        }
        throw AuthError.codeExpired
    }

    // MARK: - Renovación y revocación

    /// `updateAccessToken`: un access token nuevo (dura una hora) a partir del refresh token.
    func refresh(_ refreshToken: String) async throws -> TokenGrant {
        let client = try await credentials.get()
        let json = try await postJSON(Self.tokenURL, [
            "refresh_token": refreshToken,
            "client_id": client.clientId,
            "client_secret": client.clientSecret,
            "grant_type": "refresh_token",
        ])
        if let grant = Self.grant(json) { return grant }
        switch json["error"] as? String {
        case "invalid_grant": throw AuthError.revoked
        case "invalid_client", "unauthorized_client":
            // El client_id rotó: se olvida el guardado para que la próxima vez se vuelva a leer de youtube.com/tv.
            await credentials.invalidate()
            throw AuthError.rejected(json["error"] as? String ?? "invalid_client")
        case let other?: throw AuthError.rejected(other)
        case nil: throw AuthError.rejected("respuesta sin access_token")
        }
    }

    /// Revoca el token en Google (RFC 7009). Revocar el refresh token invalida también sus access tokens. El token va
    /// en el cuerpo, no en la URL.
    func revoke(_ token: String) async throws {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = "token=" + (token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token)
        let (_, response) = try await http.request(Self.revokeURL, method: "POST",
                                                   headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                                   body: Data(body.utf8))
        // 400 = el token ya no era válido; para quien cierra sesión es lo mismo.
        guard response.statusCode == 200 || response.statusCode == 400 else {
            throw AuthError.rejected("revoke HTTP \(response.statusCode)")
        }
    }

    // MARK: - Utilidades

    static func grant(_ json: [String: Any]) -> TokenGrant? {
        guard let access = json["access_token"] as? String else { return nil }
        return TokenGrant(accessToken: access, tokenType: json["token_type"] as? String ?? "Bearer",
                          expiresIn: (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600,
                          refreshToken: json["refresh_token"] as? String)
    }

    /// POST con cuerpo JSON. La respuesta de error de OAuth (400/401/428) también es JSON y se devuelve tal cual.
    private func postJSON(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await http.request(url, method: "POST",
                                                      headers: ["Content-Type": "application/json", "User-Agent": Self.userAgent],
                                                      body: payload)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.rejected("HTTP \(response.statusCode) sin JSON")
        }
        return json
    }
}

/// `client_id`/`client_secret` de la app de TV leídos de youtube.com/tv → `base.js` (`AppServiceCore.getClientData`).
/// Se guardan en la caché de disco (son públicos) para no bajar 1 MB de JavaScript en cada arranque.
actor ClientCredentialsCache {
    static let shared = ClientCredentialsCache()

    private var cached: OAuthClientCredentials?
    private var pending: Task<OAuthClientCredentials, Error>?
    private let http: HTTP

    init(http: HTTP = .shared) { self.http = http }

    func get() async throws -> OAuthClientCredentials {
        if let cached { return cached }
        if let stored = DiskCache.load(section: "oauth", key: "tv-client"),
           let decoded = try? JSONDecoder().decode(OAuthClientCredentials.self, from: Data(stored.utf8)) {
            cached = decoded
            return decoded
        }
        if let pending { return try await pending.value }
        let http = http
        let task = Task { try await Self.scrape(http: http) }
        pending = task
        defer { pending = nil }
        let value = try await task.value
        cached = value
        if let data = try? JSONEncoder().encode(value) {
            DiskCache.store(section: "oauth", key: "tv-client", value: String(decoding: data, as: UTF8.self))
        }
        return value
    }

    func invalidate() {
        cached = nil
        DiskCache.clear(section: "oauth")
    }

    static func scrape(http: HTTP) async throws -> OAuthClientCredentials {
        let html = try await http.string(URL(string: "https://www.youtube.com/tv")!, headers: ["User-Agent": OAuthClient.userAgent])
        guard let script = baseScriptURL(in: html) else { throw AuthError.clientNotFound }
        let js = try await http.string(script, headers: ["User-Agent": OAuthClient.userAgent])
        guard let credentials = credentials(in: js) else { throw AuthError.clientNotFound }
        return credentials
    }

    /// `AppInfo.mClientUrl`: el `<script id="base-js">` de la página o, en Cobalt, la asignación a `.src`.
    static func baseScriptURL(in html: String) -> URL? {
        let patterns = [#"id="base-js" src="(.*?)""#, #"\.src = '(.*?m=base)'"#, #"\.src = '(.*?)'; .\.id = 'base-js'"#]
        guard let raw = patterns.lazy.compactMap({ html.firstMatch($0) }).first else { return nil }
        return URL(string: Innertube.tidyURL(raw))
    }

    /// `ClientData`: la primera aparición es la de Android TV (las siguientes dan 401).
    static func credentials(in js: String) -> OAuthClientCredentials? {
        let pattern = #"clientId:"([-\w]+\.apps\.googleusercontent\.com)",\n?[$\w]+:"(\w+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
              let id = Range(match.range(at: 1), in: js), let secret = Range(match.range(at: 2), in: js) else { return nil }
        return OAuthClientCredentials(clientId: String(js[id]), clientSecret: String(js[secret]))
    }
}
