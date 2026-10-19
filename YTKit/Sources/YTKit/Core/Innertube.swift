import Foundation

/// Datos raspados de https://www.youtube.com/tv (`AppInfo` de SmartTube).
public struct AppInfo: Sendable {
    public let playerURL: String
    public let visitorData: String?
    public let livingRoomPoTokenId: String?
}

/// Cliente de Innertube con URLSession. Reproduce `VideoInfoApi` + `QueryBuilder` + el interceptor de
/// `RetrofitOkHttpHelper` (key, prettyPrint, Referer, X-Goog-Visitor-Id).
public struct Innertube: Sendable {
    /// Clave pública de InnerTube: la que trae la web de YouTube en cada página y usan muchos clientes libres
    /// (yt-dlp, NewPipe, SmartTube). No es una credencial de este proyecto ni de nadie que lo use, y no se puede
    /// revocar ni rotar: es de Google. El escaneo de secretos de GitHub la marca por la forma `AIza…`.
    public static let apiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    public static let tvUserAgent = "Mozilla/5.0 (Linux armeabi-v7a; Android 7.1.2; Fire OS 6.0) Cobalt/22.lts.3.306369-gold (unlike Gecko) v8/8.8.278.8-jit gles Starboard/13, Amazon_ATV_mediatek8695_2019/NS6294 (Amazon, AFTMM, Wireless) com.amazon.firetv.youtube/22.3.r2.v66.0"
    static let apiReferer = "https://www.youtube.com/tv"

    let http = HTTP.shared

    public init() {}

    // MARK: - /tv (player_url, visitorData)

    public func fetchAppInfo() async throws -> AppInfo {
        let html = try await http.string(URL(string: "https://www.youtube.com/tv")!, headers: ["User-Agent": Self.tvUserAgent])
        guard let rawPlayer = html.firstMatch(#""player_url":"(.*?)""#) else {
            throw HTTPError(status: 200, url: "https://www.youtube.com/tv", body: "sin player_url")
        }
        return AppInfo(
            playerURL: Self.tidyURL(rawPlayer),
            visitorData: html.firstMatch(#""visitorData":"(.*?)""#),
            livingRoomPoTokenId: html.firstMatch(#""LIVING_ROOM_PO_TOKEN_ID":"(.*?)""#)?.replacingOccurrences(of: "\\u003d", with: "=")
        )
    }

    /// `ServiceHelper.tidyUrl`: quita escapes de JSON y completa el host.
    static func tidyURL(_ url: String) -> String {
        let clean = url.replacingOccurrences(of: "\\/", with: "/")
        return clean.hasPrefix("http") ? clean : "https://www.youtube.com" + clean
    }

    // MARK: - /youtubei/v1/visitor_id (VisitorService, usado por el PoToken web)

    public func fetchVisitorData(web: ClientProfile) async throws -> String? {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false")!
        // VisitorApiHelper: QueryBuilder(AppClient.WEB).build(), sin videoId ni visitorData
        let body = try JSONSerialization.data(withJSONObject: [
            "context": ["client": Self.clientChunk(web, visitorData: nil, livingRoomPoTokenId: nil),
                        "user": ["enableSafetyMode": false, "lockedSafetyMode": false]],
        ])
        let headers = [
            "Content-Type": "application/json",
            "Accept-Language": "en-US, en;q=0.9",
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0",
            "X-Youtube-Client-Name": "1",
            "X-Youtube-Client-Version": web.clientVersion,
        ]
        let text = try await http.string(url, method: "POST", headers: headers, body: body)
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        return (json?["responseContext"] as? [String: Any])?["visitorData"] as? String
    }

    // MARK: - /youtubei/v1/player

    public struct PlayerRequest: Sendable {
        public var videoId: String
        public var client: ClientProfile
        public var signatureTimestamp: Int?
        public var visitorData: String?
        public var poToken: String?
        public var livingRoomPoTokenId: String?
        /// Token de `ReloadPlayerResponse` de SABR (`ReloadPlaybackGate.kt`); un solo uso.
        public var reloadPlaybackToken: String?
        public var cpn: String = Innertube.makeCPN()
        /// Cabeceras de más (la autorización de la cuenta, para `playbackTracking`). No se registran.
        public var extraHeaders: [String: String] = [:]

        public init(videoId: String, client: ClientProfile) {
            self.videoId = videoId
            self.client = client
        }
    }

    public struct PlayerReply: Sendable {
        public let status: Int
        public let data: Data
        public let elapsed: TimeInterval
    }

    public func player(_ req: PlayerRequest) async throws -> PlayerReply {
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/player")!
        components.queryItems = [URLQueryItem(name: "key", value: Self.apiKey), URLQueryItem(name: "prettyPrint", value: "false")]
        var headers = [
            "Content-Type": "application/json",
            "User-Agent": req.client.userAgent,
            "X-Youtube-Client-Name": req.client.clientNameId,
            "X-Youtube-Client-Version": req.client.clientVersion,
            "Referer": Self.apiReferer,
        ]
        if let visitor = req.visitorData { headers["X-Goog-Visitor-Id"] = visitor }
        headers.merge(req.extraHeaders) { _, new in new }

        let body = try JSONSerialization.data(withJSONObject: Self.playerBody(req), options: [.sortedKeys])
        Log.debug("player[\(req.client.id)] body: \(String(decoding: body, as: UTF8.self).prefix(900))")
        let start = Date()
        let (data, response) = try await http.request(components.url!, method: "POST", headers: headers, body: body)
        return PlayerReply(status: response.statusCode, data: data, elapsed: Date().timeIntervalSince(start))
    }

    /// Cuerpo de `QueryBuilder.build()` para `PostDataType.Player`.
    static func playerBody(_ req: PlayerRequest) -> [String: Any] {
        let c = req.client
        var context: [String: Any] = [
            "client": clientChunk(c, visitorData: req.visitorData, livingRoomPoTokenId: req.livingRoomPoTokenId),
            "user": ["enableSafetyMode": false, "lockedSafetyMode": false],
        ]
        if c.isEmbedded { context["thirdParty"] = ["embedUrl": "https://www.reddit.com/"] }

        var body: [String: Any] = [
            "context": context,
            "racyCheckOk": true,
            "contentCheckOk": true,
            "videoId": req.videoId,
            "cpn": req.cpn,
        ]
        if let sts = req.signatureTimestamp {
            body["playbackContext"] = [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS",
                    "lactMilliseconds": 60000,
                    "isInlinePlaybackNoAd": true,
                    "signatureTimestamp": sts,
                ],
                "devicePlaybackCapabilities": [
                    "supportsVp9Encoding": true,
                    "supportXhr": !c.isTV,
                ],
            ]
        }
        if let token = req.reloadPlaybackToken {
            var playbackContext = body["playbackContext"] as? [String: Any] ?? [:]
            playbackContext["reloadPlaybackContext"] = ["reloadPlaybackParams": ["token": token]]
            body["playbackContext"] = playbackContext
        }
        if let pot = req.poToken { body["serviceIntegrityDimensions"] = ["poToken": pot] }
        if let params = c.params { body["params"] = params }
        return body
    }

    /// `QueryBuilder.createClientChunk()`.
    static func clientChunk(_ c: ClientProfile, visitorData: String?, livingRoomPoTokenId: String?) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": c.clientName,
            "clientVersion": c.clientVersion,
            "clientScreen": c.clientScreen ?? "WATCH",
            "userAgent": c.userAgent,
            "acceptLanguage": language,
            "acceptRegion": region,
            "utcOffsetMinutes": String(TimeZone.current.secondsFromGMT() / 60),
        ]
        if let browser = c.browser {
            client["browserName"] = browser.name
            client["browserVersion"] = browser.version
        }
        // POST_DATA_ANDROID_SDK / _OS / _MODEL e IOS_MODEL
        if let sdk = c.androidSdkVersion { client["androidSdkVersion"] = sdk }
        if let osName = c.osName { client["osName"] = osName }
        if let osVersion = c.osVersion { client["osVersion"] = osVersion }
        if let model = c.deviceModel { client["deviceModel"] = model }
        if let make = c.deviceMake { client["deviceMake"] = make }
        if let id = livingRoomPoTokenId { client["tvAppInfo"] = ["livingRoomPoTokenId": id] }
        if let visitorData { client["visitorData"] = visitorData }
        return client
    }

    // MARK: - Utilidades

    static var language: String { Locale.current.language.languageCode?.identifier ?? "en" }
    static var region: String { Locale.current.region?.identifier ?? "US" }

    /// Client Playback Nonce: 16 caracteres del alfabeto base64url (`YouTubeHelper.generateCPNParameter2`).
    public static func makeCPN() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}
