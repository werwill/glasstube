import Foundation

/// Obtiene la URL del player JS (raspando /tv, como `AppServiceCore`), lo descarga con caché en disco
/// y extrae `signatureTimestamp` (`CommonExtractor.extractSignatureTimestamp`).
public actor PlayerScriptStore {
    public static let shared = PlayerScriptStore()

    private static let playerSection = "player-js"
    private let innertube = Innertube()
    private var appInfoTask: Task<AppInfo, Error>?
    private var memory: [String: String] = [:]

    /// Fuerza una variante distinta a la de SmartTube (por ejemplo `main` = player_ias.vflset/en_US/base.js).
    public var overrideVariant: ClientProfile.PlayerVariant?

    public func setOverrideVariant(_ variant: ClientProfile.PlayerVariant?) { overrideVariant = variant }

    /// Fija el hash del player (YouTube sirve varios a la vez en pruebas A/B).
    public var overrideHash: String?

    public func setOverrideHash(_ hash: String?) { overrideHash = hash }

    /// /tv (URL del player JS, `visitorData` y `LIVING_ROOM_PO_TOKEN_ID`). Se vuelve a leer cada 10 h, como
    /// `AppServiceCoreCached` de SmartTube; antes se guardaba mientras la app estuviera abierta, y todos los videos iban
    /// con el mismo visitante. Un fallo no se guarda.
    public func appInfo() async throws -> AppInfo {
        if let appInfoTask, Date().timeIntervalSince(appInfoFetchedAt) < Self.appInfoLifetime { return try await appInfoTask.value }
        let task = Task { try await innertube.fetchAppInfo() }
        appInfoTask = task
        appInfoFetchedAt = Date()
        do {
            return try await task.value
        } catch {
            if appInfoTask == task { appInfoTask = nil }
            throw error
        }
    }

    static let appInfoLifetime: TimeInterval = 10 * 3600
    private var appInfoFetchedAt = Date.distantPast

    /// Olvida /tv: la próxima llamada trae visitante y `LIVING_ROOM_PO_TOKEN_ID` nuevos (tras un LOGIN_REQUIRED).
    public func renewAppInfo() {
        appInfoTask = nil
    }

    /// URL del player para un cliente. SmartTube usa la URL de /tv tal cual para todos los clientes
    /// (`WebPlayerDataExtractor`), salvo TV, que usa la variante TCL (`TclPlayerDataExtractor`).
    public func playerURL(for client: ClientProfile) async throws -> (url: String, variant: ClientProfile.PlayerVariant) {
        var base = try await appInfo().playerURL
        if let overrideHash {
            base = base.replacingOccurrences(of: #"/s/player/[0-9a-f]{8}/"#, with: "/s/player/\(overrideHash)/", options: .regularExpression)
        }
        let variant = overrideVariant ?? client.playerVariant ?? .tv
        switch variant {
        case .tv:
            return (base, .tv)
        case .main:
            guard let range = base.range(of: "/tv-player-") else { return (base, .main) }
            return (String(base[..<range.lowerBound]) + "/player_ias.vflset/en_US/base.js", .main)
        case .tcl:
            let tclPath = "/tv-player-ias-tcl.vflset/tv-player-ias-tcl.js"
            var url = base
            for path in ["/tv-player-es6.vflset/tv-player-es6.js", "/tv-player-ias.vflset/tv-player-ias.js",
                         "/player_es6.vflset/en_US/base.js", "/player_ias.vflset/en_US/base.js"] {
                url = url.replacingOccurrences(of: path, with: tclPath)
            }
            return (url.replacingOccurrences(of: "-es6", with: "-ias"), .tcl)
        }
    }

    public func code(for url: String) async throws -> String {
        if let cached = memory[url] { return cached }
        if let cached = DiskCache.load(section: Self.playerSection, key: url), cached.count > 100_000 {
            Log.debug("player JS desde caché en disco: \(url)")
            memory[url] = cached
            return cached
        }
        Log.debug("descargando player JS: \(url)")
        let code = try await HTTP.shared.string(URL(string: url)!, headers: ["User-Agent": Innertube.tvUserAgent])
        DiskCache.store(section: Self.playerSection, key: url, value: code)
        memory[url] = code
        return code
    }

    public func signatureTimestamp(for url: String) async throws -> Int? {
        let code = try await code(for: url)
        return code.firstMatch(#"signatureTimestamp:(\d+)"#).flatMap(Int.init)
    }
}
