import Foundation

/// Reporte del tiempo visto a YouTube (`track/TrackingService` de SmartTube): lo que hace que un video aparezca en el
/// Historial de la cuenta con su barra de progreso y que "seguir viendo" funcione en otros dispositivos.
///
/// YouTube no tiene un endpoint "guardar posición": el reproductor oficial manda estadísticas a `api/stats/playback`
/// (crea el registro de visualización) y `api/stats/watchtime` (tramos vistos). Las dos URL salen de
/// `playbackTracking` de un `/player` hecho con la cuenta y el `cpn` es uno por video. SmartTube arma URL mínimas con
/// `ei`, `vm` y `of`; el 15-oct-2026 YouTube las aceptaba (HTTP 204) pero solo guardaba "empezado" (~10 %), así que aquí
/// se usan las URL completas de YouTube (como el `mark_watched` de yt-dlp) con `cpn`, `cmt`, `st`, `et`, `len` y `rt`.
actor WatchTimeTracker {
    /// `START_THRESHOLD_SEC`: antes de los tres minutos, el primer registro empieza en 0.
    static let startThreshold: Double = 3 * 60
    /// `HISTORY_RENEW_MS`: un registro de más de 30 min se vuelve a crear.
    static let recordLifetime: TimeInterval = 30 * 60

    /// Datos de seguimiento de un video con la cuenta elegida.
    struct Tracking: Sendable, Equatable {
        var videoId: String
        var lengthSeconds: Double
        /// `videostatsPlaybackUrl.baseUrl` y `videostatsWatchtimeUrl.baseUrl`.
        var playbackBase: String
        var watchtimeBase: String
        var cpn: String
        var accountKey: String
        /// Cuándo se creó el registro (para `rt`, segundos de reproducción real).
        var startedAt = Date()
    }

    private var tracking: Tracking?
    /// Última posición reportada (`mPosition`: video, segundos, cuándo).
    private var last: (videoId: String, position: Double, date: Date)?

    func update(videoId: String, position: Double, service: YouTubeService) async throws {
        guard let headers = try await service.session?.authorizationHeaders() else { throw YTKitError.signInRequired("El historial") }
        let accountKey = headers["X-Goog-Pageid"] ?? "principal"
        var info: Tracking
        if let tracking, tracking.videoId == videoId, tracking.accountKey == accountKey {
            info = tracking
        } else {
            let data = try await service.authenticatedPlayer(videoId: videoId)
            guard let parsed = Self.tracking(fromPlayer: data, videoId: videoId, accountKey: accountKey) else {
                throw YTKitError.badResponse("/player sin playbackTracking para \(videoId)")
            }
            info = parsed
            tracking = parsed
            last = nil
        }
        info.lengthSeconds = max(info.lengthSeconds, position)
        for request in plan(info, position: position) {
            try await send(request, headers: headers)
        }
        last = (videoId, position, Date())
    }

    /// Las peticiones de `updateWatchTimeFull` para esta posición, en orden.
    func plan(_ info: Tracking, position: Double, now: Date = Date()) -> [URL] {
        let length = info.lengthSeconds
        let sameVideo = last?.videoId == info.videoId
        let oldPosition = sameVideo ? last!.position : (position < Self.startThreshold ? 0 : position)
        let rt = Self.seconds(max(0, now.timeIntervalSince(info.startedAt)))

        // Si queda menos del 5 %, se marca como visto entero (las variantes "short" con final=1).
        if length - position < length * 0.05 {
            return [
                Self.url(info.playbackBase, info, ["final": "1", "len": Self.seconds(length), "cmt": Self.seconds(length), "rt": rt]),
                Self.url(info.watchtimeBase, info, ["final": "1", "len": Self.seconds(length), "st": Self.seconds(oldPosition),
                                                     "et": Self.seconds(length), "cmt": Self.seconds(length), "rt": rt]),
            ]
        }
        var urls: [URL] = []
        let outdated = last.map { now.timeIntervalSince($0.date) > Self.recordLifetime } ?? true
        if !sameVideo || outdated {
            urls.append(Self.url(info.playbackBase, info, ["len": Self.seconds(length), "cmt": Self.seconds(oldPosition), "rt": rt]))
        }
        urls.append(Self.url(info.watchtimeBase, info, [
            "len": Self.seconds(length),
            "st": Self.seconds(oldPosition),
            "et": Self.seconds(position),
            "cmt": Self.seconds(position),
            "rt": rt,
            "state": "playing",
        ]))
        return urls
    }

    private func send(_ url: URL, headers: [String: String]) async throws {
        var all = headers
        all["User-Agent"] = OAuthClient.userAgent
        all["Referer"] = "https://www.youtube.com/tv"
        let (_, response) = try await HTTP.shared.request(url, headers: all)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError(status: response.statusCode, url: "\(url.host ?? "")\(url.path)", body: "")
        }
    }

    // MARK: - Utilidades

    /// La URL de YouTube con sus parámetros (`docid`, `ei`, `vm`, `of`, `plid`, `el`, `c`, `cver`…) más `ver=2`, el `cpn`
    /// y los de este reporte, que reemplazan a los que ya tuviera.
    static func url(_ base: String, _ info: Tracking, _ extra: [String: String]) -> URL {
        var components = URLComponents(string: base) ?? URLComponents(string: "https://www.youtube.com/api/stats/watchtime")!
        components.set("ns", components.value("ns") ?? "yt")
        components.set("ver", "2")
        components.set("docid", components.value("docid") ?? info.videoId)
        components.set("cpn", info.cpn)
        for key in extra.keys.sorted() { components.set(key, extra[key]) }
        return components.url!
    }

    static func seconds(_ value: Double) -> String { String(format: "%.3f", value) }

    static func hasTracking(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["playbackTracking"] != nil
    }

    /// Las dos URL de `playbackTracking` y la duración de `videoDetails.lengthSeconds`.
    static func tracking(fromPlayer data: Data, videoId: String, accountKey: String) -> Tracking? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracking = json["playbackTracking"] as? [String: Any],
              let playback = (tracking["videostatsPlaybackUrl"] as? [String: Any])?["baseUrl"] as? String,
              let watchtime = (tracking["videostatsWatchtimeUrl"] as? [String: Any])?["baseUrl"] as? String else { return nil }
        let details = json["videoDetails"] as? [String: Any]
        let len = URLComponents(string: watchtime)?.value("len")
        let length = Double(details?["lengthSeconds"] as? String ?? "") ?? Double(len ?? "") ?? 0
        return Tracking(videoId: videoId, lengthSeconds: length, playbackBase: playback, watchtimeBase: watchtime,
                        cpn: Innertube.makeCPN(), accountKey: accountKey)
    }
}
