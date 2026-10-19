import AppKit
import Foundation
import YTKit

/// Hojas de miniaturas de un video (`playerStoryboardSpecRenderer`): las mismas que SmartTube usa al adelantar
/// (formatbuilders/storyboard). Formato del `spec`: `base|nivel0|nivel1|…`, cada nivel
/// `ancho#alto#cuadros#columnas#filas#intervalo#nombre#sigh`; en la URL, `$L` es el nivel, `$N` el nombre y `$M` la hoja.
nonisolated struct StoryboardSpec: Sendable, Hashable {
    struct Level: Sendable, Hashable {
        var index: Int
        var width: Int
        var height: Int
        var count: Int
        var columns: Int
        var rows: Int
        var name: String
        var sigh: String

        var perSheet: Int { max(1, columns * rows) }
    }

    var baseURL: String
    var levels: [Level]

    init?(spec: String) {
        let parts = spec.components(separatedBy: "|")
        guard parts.count > 1 else { return nil }
        baseURL = parts[0]
        levels = parts.dropFirst().enumerated().compactMap { index, raw in
            let f = raw.components(separatedBy: "#")
            guard f.count >= 8, let w = Int(f[0]), let h = Int(f[1]), let n = Int(f[2]), let c = Int(f[3]), let r = Int(f[4]),
                  n > 0, c > 0, r > 0 else { return nil }
            return Level(index: index, width: w, height: h, count: n, columns: c, rows: r, name: f[6], sigh: f[7])
        }
        guard !levels.isEmpty else { return nil }
    }

    /// El nivel más detallado (160×90 en casi todos los videos).
    var best: Level { levels.max { $0.width < $1.width }! }

    /// Hoja y recorte (en píxeles de la hoja) del cuadro que corresponde a `seconds`.
    func frame(at seconds: Double, duration: Double, level: Level? = nil) -> (url: URL, rect: CGRect)? {
        let level = level ?? best
        guard duration > 0 else { return nil }
        let index = min(level.count - 1, max(0, Int(seconds / duration * Double(level.count))))
        let sheet = index / level.perSheet
        let inSheet = index % level.perSheet
        let name = level.name.replacingOccurrences(of: "$M", with: String(sheet))
        var url = baseURL.replacingOccurrences(of: "$L", with: String(level.index)).replacingOccurrences(of: "$N", with: name)
        url += (url.contains("?") ? "&" : "?") + "sigh=" + level.sigh
        guard let sheetURL = URL(string: url) else { return nil }
        let rect = CGRect(x: (inSheet % level.columns) * level.width, y: (inSheet / level.columns) * level.height,
                          width: level.width, height: level.height)
        return (sheetURL, rect)
    }

    /// Recorta el cuadro de una hoja ya descargada.
    static func crop(_ sheet: NSImage, rect: CGRect) -> NSImage? {
        guard let cg = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bounded = rect.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !bounded.isEmpty, let cropped = cg.cropping(to: bounded) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: bounded.width, height: bounded.height))
    }
}

/// Pista de subtítulos de YouTube (`captionTracks`). Se pide en WebVTT con `&fmt=vtt`.
nonisolated struct CaptionTrack: Sendable, Hashable, Identifiable {
    var baseURL: String
    var languageCode: String
    var name: String
    var isAutomatic: Bool

    var id: String { baseURL }
    var vttURL: URL? { URL(string: baseURL + "&fmt=vtt") }
    var title: String { isAutomatic ? "\(name) (automáticos)" : name }
}

/// Lo que la app necesita del `/player` además de los streams: storyboard, subtítulos y, en directos, el HLS.
nonisolated struct PlayerExtras: Sendable {
    var title: String?
    var author: String?
    var duration: Double?
    var isLive = false
    var storyboard: StoryboardSpec?
    var captions: [CaptionTrack] = []
    var hlsURL: URL?
}

/// Pide `/player` con el cliente VISIONOS, que no exige `n`, firma ni PoToken y trae storyboard y subtítulos que se
/// descargan sin `pot` (probado con rfscVS0vtbw: 14 pistas, WebVTT 200). La reproducción va aparte, por SABR.
actor PlayerExtrasService {
    private let catalog: ClientCatalog
    private var cache: [String: PlayerExtras] = [:]
    private var inFlight: [String: Task<PlayerExtras, Error>] = [:]

    init(catalog: ClientCatalog) {
        self.catalog = catalog
    }

    func extras(videoId: String) async throws -> PlayerExtras {
        if let cached = cache[videoId] { return cached }
        if let task = inFlight[videoId] { return try await task.value }
        let catalog = catalog
        let task = Task { try await Self.fetch(videoId: videoId, catalog: catalog) }
        inFlight[videoId] = task
        defer { inFlight[videoId] = nil }
        let value = try await task.value
        cache[videoId] = value
        return value
    }

    private nonisolated static func fetch(videoId: String, catalog: ClientCatalog) async throws -> PlayerExtras {
        guard let client = catalog.profile("VISIONOS") else { throw YTKitError.notAvailable("clients.json sin VISIONOS") }
        var request = Innertube.PlayerRequest(videoId: videoId, client: client)
        request.visitorData = try? await PlayerScriptStore.shared.appInfo().visitorData
        let reply = try await Innertube().player(request)
        guard reply.status == 200, let root = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any] else {
            throw YTKitError.badResponse("player HTTP \(reply.status)")
        }
        var extras = PlayerExtras()
        let details = root["videoDetails"] as? [String: Any]
        extras.title = details?["title"] as? String
        extras.author = details?["author"] as? String
        extras.duration = (details?["lengthSeconds"] as? String).flatMap(Double.init)
        extras.isLive = details?["isLive"] as? Bool ?? false
        let storyboards = root["storyboards"] as? [String: Any]
        if let spec = (storyboards?["playerStoryboardSpecRenderer"] as? [String: Any])?["spec"] as? String {
            extras.storyboard = StoryboardSpec(spec: spec)
        }
        let tracklist = (root["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any]
        for track in tracklist?["captionTracks"] as? [[String: Any]] ?? [] {
            guard let base = track["baseUrl"] as? String, let language = track["languageCode"] as? String else { continue }
            extras.captions.append(CaptionTrack(baseURL: base, languageCode: language, name: text(track["name"]) ?? language,
                                                isAutomatic: (track["kind"] as? String) == "asr"))
        }
        if let hls = (root["streamingData"] as? [String: Any])?["hlsManifestUrl"] as? String {
            extras.hlsURL = URL(string: hls)
        }
        return extras
    }

    private nonisolated static func text(_ value: Any?) -> String? {
        if let simple = (value as? [String: Any])?["simpleText"] as? String { return simple }
        if let runs = (value as? [String: Any])?["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }
}
