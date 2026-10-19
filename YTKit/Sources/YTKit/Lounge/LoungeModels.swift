import Foundation

// Control remoto desde la app de YouTube del teléfono por la API Lounge (fase 4). La Mac hace de «pantalla»
// (`LOUNGE_SCREEN`), como la app de TV y SmartTube (`youtubeapi/lounge`): pide un id de pantalla, un token de Lounge y un
// código para vincular, y abre el canal largo `bc/bind` (BrowserChannel de Google) por el que llegan los comandos del
// teléfono. Los reportes de vuelta (qué suena, estado, volumen) van por POST al mismo canal.

/// Código para «Vincular con código de TV» en la app de YouTube del teléfono (12 dígitos).
public struct LoungePairingCode: Sendable, Hashable {
    /// Los 12 dígitos tal cual.
    public var digits: String

    public init(digits: String) {
        self.digits = digits
    }

    /// `XXX-XXX-XXX-XXX`.
    public var formatted: String {
        stride(from: 0, to: digits.count, by: 3).map { offset -> String in
            let start = digits.index(digits.startIndex, offsetBy: offset)
            let end = digits.index(start, offsetBy: 3, limitedBy: digits.endIndex) ?? digits.endIndex
            return String(digits[start..<end])
        }.joined(separator: "-")
    }

    /// Lo que codifica el QR de la app de TV (comprobado al decodificar el que da `get_pairing_code?qr=1`): la cámara del
    /// teléfono lo abre en la app de YouTube y vincula sin escribir el código.
    public var pairURL: URL { URL(string: "https://youtube.com/pair/\(digits)?qr=1")! }

    /// `get_pairing_code` responde texto con los dígitos o, con `qr=1`, JSON con `code` y la imagen del QR.
    static func parse(_ data: Data) -> LoungePairingCode? {
        var text = String(decoding: data, as: UTF8.self)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let code = LoungeValue.string(object["code"]) else { return nil }
            text = code
        }
        let digits = text.filter(\.isNumber)
        return digits.count >= 8 ? LoungePairingCode(digits: digits) : nil
    }
}

/// Un dispositivo del salón: el teléfono que controla (`REMOTE_CONTROL`) o la propia pantalla.
public struct LoungeRemote: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// `REMOTE_CONTROL`, `LOUNGE_SCREEN`…
    public var type: String?
    /// `android`, `ios`, `lb-v4`…
    public var app: String?
    /// `manual` cuando se vinculó con el código.
    public var pairingType: String?

    public init(id: String, name: String, type: String? = nil, app: String? = nil, pairingType: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.app = app
        self.pairingType = pairingType
    }

    public var isScreen: Bool { type == "LOUNGE_SCREEN" }

    init?(_ object: [String: Any]?) {
        guard let object, let id = LoungeValue.string(object["id"]) else { return nil }
        self.init(id: id, name: LoungeValue.string(object["name"]) ?? "Dispositivo", type: LoungeValue.string(object["type"]),
                  app: LoungeValue.string(object["app"]), pairingType: LoungeValue.string(object["pairingType"]))
    }
}

/// Lo que manda el teléfono con `setPlaylist`/`updatePlaylist` (`PlaylistParams` de SmartTube).
public struct LoungePlaylist: Sendable, Hashable {
    public var videoId: String?
    /// La cola del teléfono (`videoIds`, separados por comas).
    public var videoIds: [String]
    public var currentIndex: Int?
    /// Id de la cola del salón (`RQ…`) o de la playlist.
    public var listId: String?
    /// Segundos.
    public var currentTime: Double?
    /// Token que hay que devolver en `nowPlaying`.
    public var ctt: String?
    public var params: String?

    public init(videoId: String? = nil, videoIds: [String] = [], currentIndex: Int? = nil, listId: String? = nil,
                currentTime: Double? = nil, ctt: String? = nil, params: String? = nil) {
        self.videoId = videoId
        self.videoIds = videoIds
        self.currentIndex = currentIndex
        self.listId = listId
        self.currentTime = currentTime
        self.ctt = ctt
        self.params = params
    }

    /// El video a reproducir: `videoId` o el de `currentIndex` en la cola.
    public var currentVideoId: String? {
        if let videoId, !videoId.isEmpty { return videoId }
        if let currentIndex, videoIds.indices.contains(currentIndex) { return videoIds[currentIndex] }
        return nil
    }

    init(_ object: [String: Any]?) {
        let object = object ?? [:]
        let ids = LoungeValue.string(object["videoIds"])?.split(separator: ",").map(String.init).filter { !$0.isEmpty } ?? []
        self.init(videoId: LoungeValue.string(object["videoId"]), videoIds: ids, currentIndex: LoungeValue.int(object["currentIndex"]),
                  listId: LoungeValue.string(object["listId"]), currentTime: LoungeValue.double(object["currentTime"]),
                  ctt: LoungeValue.string(object["ctt"]), params: LoungeValue.string(object["params"]))
    }
}

/// Tecla de la cruceta del teléfono (`dpadCommand`).
public enum LoungeKey: String, Sendable, Hashable {
    case up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT", enter = "ENTER", back = "BACK"
}

/// Pista de subtítulos que pide el teléfono (`setSubtitlesTrack`); sin idioma = quitarlos.
public struct LoungeSubtitles: Sendable, Hashable {
    public var videoId: String?
    public var languageCode: String?
    public var vssId: String?

    public init(videoId: String? = nil, languageCode: String? = nil, vssId: String? = nil) {
        self.videoId = videoId
        self.languageCode = languageCode
        self.vssId = vssId
    }

    public var isOff: Bool { (languageCode ?? "").isEmpty && (vssId ?? "").isEmpty }
}

/// Comandos que llegan del teléfono (`CommandItem` + `YouTubeCommand` de SmartTube).
public enum LoungeCommand: Sendable, Hashable {
    case setPlaylist(LoungePlaylist)
    case updatePlaylist(LoungePlaylist)
    case play
    case pause
    case next
    case previous
    /// Segundos.
    case seekTo(Double)
    /// `volume` 0–100 (el control del teléfono) o `delta` (los botones de volumen del teléfono).
    case setVolume(volume: Int?, delta: Int?)
    case stopVideo
    case setSubtitlesTrack(LoungeSubtitles)
    case dpad(LoungeKey)
    case getNowPlaying
    case getVolume
    case getSubtitlesTrack
    case remoteConnected(LoungeRemote)
    case remoteDisconnected(LoungeRemote)
    /// Al abrir la sesión: los dispositivos del salón.
    case loungeStatus([LoungeRemote])
    case voiceCommand(started: Bool)
    case noop
    /// Cualquier otro (se registra y se ignora).
    case other(String)

    /// Decodifica `["tipo", {argumentos}]` del canal.
    static func decode(_ payload: [Any]) -> LoungeCommand {
        guard let type = payload.first as? String else { return .other("?") }
        let args = payload.count > 1 ? payload[1] as? [String: Any] : nil
        switch type {
        case "setPlaylist": return .setPlaylist(LoungePlaylist(args))
        case "updatePlaylist": return .updatePlaylist(LoungePlaylist(args))
        case "play": return .play
        case "pause": return .pause
        case "next": return .next
        case "previous": return .previous
        case "seekTo": return LoungeValue.double(args?["newTime"]).map(LoungeCommand.seekTo) ?? .other(type)
        case "setVolume": return .setVolume(volume: LoungeValue.int(args?["volume"]), delta: LoungeValue.int(args?["delta"]))
        case "stopVideo": return .stopVideo
        case "setSubtitlesTrack":
            return .setSubtitlesTrack(LoungeSubtitles(videoId: LoungeValue.string(args?["videoId"]),
                                                      languageCode: LoungeValue.string(args?["languageCode"]),
                                                      vssId: LoungeValue.string(args?["vssId"] ?? args?["vss_id"])))
        case "dpadCommand": return LoungeValue.string(args?["key"]).flatMap(LoungeKey.init(rawValue:)).map(LoungeCommand.dpad) ?? .other(type)
        case "getNowPlaying": return .getNowPlaying
        case "getVolume": return .getVolume
        case "getSubtitlesTrack": return .getSubtitlesTrack
        case "remoteConnected": return LoungeRemote(args).map(LoungeCommand.remoteConnected) ?? .other(type)
        case "remoteDisconnected": return LoungeRemote(args).map(LoungeCommand.remoteDisconnected) ?? .other(type)
        case "loungeStatus":
            // `devices` es JSON dentro de una cadena.
            let devices = LoungeValue.string(args?["devices"]).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: Any]] } ?? []
            return .loungeStatus(devices.compactMap { LoungeRemote($0) })
        case "voiceCommand": return .voiceCommand(started: LoungeValue.string(args?["status"]) == "INITIATED")
        case "noop": return .noop
        default: return .other(type)
        }
    }

    /// Nombre corto para el registro (sin datos del teléfono).
    public var name: String {
        switch self {
        case .setPlaylist: "setPlaylist"
        case .updatePlaylist: "updatePlaylist"
        case .play: "play"
        case .pause: "pause"
        case .next: "next"
        case .previous: "previous"
        case .seekTo: "seekTo"
        case .setVolume: "setVolume"
        case .stopVideo: "stopVideo"
        case .setSubtitlesTrack: "setSubtitlesTrack"
        case .dpad: "dpadCommand"
        case .getNowPlaying: "getNowPlaying"
        case .getVolume: "getVolume"
        case .getSubtitlesTrack: "getSubtitlesTrack"
        case .remoteConnected: "remoteConnected"
        case .remoteDisconnected: "remoteDisconnected"
        case .loungeStatus: "loungeStatus"
        case .voiceCommand: "voiceCommand"
        case .noop: "noop"
        case .other(let type): type
        }
    }
}

/// Estado del reproductor como lo entiende el teléfono (el de YouTube: -1 sin empezar, 0 terminado, 1 reproduciendo,
/// 2 en pausa, 3 cargando). SmartTube manda 3 como «inactivo»; el teléfono muestra un indicador de carga.
public enum LoungePlayerState: Int, Sendable, Hashable {
    case unstarted = -1, ended = 0, playing = 1, paused = 2, buffering = 3
}

/// Lo que suena, para `nowPlaying`.
public struct LoungeNowPlaying: Sendable, Hashable {
    public var videoId: String
    public var currentTime: Double
    public var duration: Double?
    public var state: LoungePlayerState
    public var listId: String?
    public var currentIndex: Int?
    public var ctt: String?

    public init(videoId: String, currentTime: Double, duration: Double?, state: LoungePlayerState, listId: String? = nil,
                currentIndex: Int? = nil, ctt: String? = nil) {
        self.videoId = videoId
        self.currentTime = currentTime
        self.duration = duration
        self.state = state
        self.listId = listId
        self.currentIndex = currentIndex
        self.ctt = ctt
    }
}

/// Reportes de la pantalla al teléfono (`CommandParams` de SmartTube).
public enum LoungeReport: Sendable, Hashable {
    /// nil: no suena nada.
    case nowPlaying(LoungeNowPlaying?)
    case stateChange(state: LoungePlayerState, currentTime: Double, duration: Double?)
    /// 0–100.
    case volumeChanged(volume: Int, muted: Bool)
    /// `languageCode` nil: sin subtítulos.
    case subtitlesTrackChanged(videoId: String, languageCode: String?, vssId: String?)
    case hasPreviousNextChanged(hasPrevious: Bool, hasNext: Bool)

    var command: String {
        switch self {
        case .nowPlaying: "nowPlaying"
        case .stateChange: "onStateChange"
        case .volumeChanged: "onVolumeChanged"
        case .subtitlesTrackChanged: "onSubtitlesTrackChanged"
        case .hasPreviousNextChanged: "onHasPreviousNextChanged"
        }
    }

    /// Campos del reporte sin el prefijo `reqN_` (en orden estable).
    var fields: [(String, String)] {
        switch self {
        case .nowPlaying(let playing):
            guard let playing else { return [] }
            var fields = Self.timing(playing.currentTime, playing.duration)
            fields.insert(("videoId", playing.videoId), at: 0)
            fields.append(("state", String(playing.state.rawValue)))
            fields.append(("cpn", Self.cpn))
            if let listId = playing.listId { fields.append(("listId", listId)) }
            if let index = playing.currentIndex { fields.append(("currentIndex", String(index))) }
            if let ctt = playing.ctt { fields.append(("ctt", ctt)) }
            return fields
        case .stateChange(let state, let time, let duration):
            return [("state", String(state.rawValue))] + Self.timing(time, duration) + [("cpn", Self.cpn)]
        case .volumeChanged(let volume, let muted):
            return [("volume", String(max(0, min(100, volume)))), ("muted", muted ? "true" : "false")]
        case .subtitlesTrackChanged(let videoId, let languageCode, let vssId):
            var fields = [("videoId", videoId)]
            if let languageCode, !languageCode.isEmpty {
                fields.append(("languageCode", languageCode))
                fields.append(("sourceLanguageCode", languageCode))
                if let vssId { fields.append(("vss_id", vssId)) }
            }
            return fields
        case .hasPreviousNextChanged(let previous, let next):
            return [("hasPrevious", previous ? "true" : "false"), ("hasNext", next ? "true" : "false")]
        }
    }

    /// SmartTube manda «foo» como `cpn` cuando no tiene uno.
    static let cpn = "foo"

    private static func timing(_ time: Double, _ duration: Double?) -> [(String, String)] {
        var fields = [("currentTime", LoungeValue.seconds(max(0, time)))]
        if let duration, duration > 0 {
            fields.append(("duration", LoungeValue.seconds(duration)))
            fields.append(("seekableStartTime", "0"))
            fields.append(("seekableEndTime", LoungeValue.seconds(duration)))
        }
        fields.append(("loadedTime", "0"))
        return fields
    }

    /// El cuerpo del POST con varios reportes: `count`, `ofs` y `reqN__sc`, `reqN_campo` (`packageCommands`).
    static func formFields(_ reports: [LoungeReport], offset: Int) -> [(String, String)] {
        var fields = [("count", String(reports.count)), ("ofs", String(offset))]
        for (index, report) in reports.enumerated() {
            fields.append(("req\(index)__sc", report.command))
            fields += report.fields.map { ("req\(index)_\($0.0)", $0.1) }
        }
        return fields
    }
}

/// Estado del enlace con los servidores de Lounge.
public enum LoungeConnectionState: Sendable, Hashable {
    case stopped
    case connecting
    /// El canal está abierto: el teléfono puede encontrar la pantalla.
    case connected
    /// Falló y se reintenta en unos segundos.
    case retrying(after: TimeInterval, reason: String)
}

/// Lo que publica `LoungeScreen`.
public enum LoungeEvent: Sendable, Hashable {
    case state(LoungeConnectionState)
    case command(LoungeCommand)
    /// Teléfonos conectados ahora (sin la pantalla).
    case remotes([LoungeRemote])
}

/// Lectura tolerante de los argumentos, que llegan como texto o como número.
enum LoungeValue {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        double(value).flatMap { $0.isFinite ? Int($0.rounded()) : nil }
    }

    /// Segundos con hasta tres decimales, sin depender del idioma («12.5», «90»).
    static func seconds(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
