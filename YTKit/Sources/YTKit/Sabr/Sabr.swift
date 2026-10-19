import Foundation

// Cliente SABR (Server-side ABR de googlevideo): POST de `VideoPlaybackAbrRequest` (protobuf) a
// `serverAbrStreamingUrl` y respuesta en UMP. Port de la parte necesaria de SmartTube:
// `SabrManifest.createVideoPlaybackAbrRequest` (petición), `SabrStream` + `SabrProcessor` (partes UMP) y
// `ReloadPlaybackGate.kt` (token de recarga). A diferencia de SmartTube, que abre un SabrStream por pista,
// aquí una sola sesión pide audio y video a la vez (`enabled_track_types_bitfield = 0`), como yt-dlp.
// Dos modos: `run()` baja los primeros N segundos a memoria (comando `sabr`) y `stream(from:to:clock:)` entrega
// los bytes de cada pista en orden a un `SabrSink` conforme llegan, al ritmo del reproductor (comando `sabrplay`).
// En streaming la sesión además renueva la URL y el PoToken antes de que caduquen y, ante 403, errores de red o
// una CDN que no contesta, cambia de CDN (`SabrCDNSelector`) o vuelve a pedir el player en lugar de detenerse.

/// `FormatId` de `common.proto`.
public struct SabrFormatID: Hashable, Sendable, CustomStringConvertible {
    public var itag: Int
    public var lastModified: UInt64?
    public var xtags: String?

    init(format: StreamFormat) {
        itag = format.itag
        // FormatSelector.createFormatId: sin LMT se omite el campo (0/omitido es lo que usa googlevideo).
        lastModified = (format.lastModified ?? 0) > 0 ? format.lastModified : nil
        xtags = (format.xtags?.isEmpty ?? true) ? nil : format.xtags
    }

    init(_ fields: ProtoFields) {
        itag = Int(fields.int(1) ?? 0)
        lastModified = fields.uint(2)
        xtags = fields.string(3)
    }

    func encode(_ w: inout ProtoWriter) {
        w.int(1, itag)
        w.uint(2, lastModified)
        w.string(3, xtags)
    }

    public var description: String { "\(itag)" + (xtags.map { " [\($0)]" } ?? "") }
}

/// PoToken del cliente TV (ver `PoTokenWebViewProvider.mintTV`).
public protocol TVPoTokenSource: Sendable {
    func tvPoToken(tv: ClientProfile) async throws -> (result: PoTokenResult, livingRoomPoTokenId: String)
}

extension PoTokenWebViewProvider: TVPoTokenSource {
    nonisolated public func tvPoToken(tv: ClientProfile) async throws -> (result: PoTokenResult, livingRoomPoTokenId: String) {
        try await mintTV(tv: tv)
    }
}

/// Destino de los bytes en modo streaming: cada pista recibe su segmento de inicio y después los segmentos en
/// orden, conforme llegan. Se llama desde la tarea que corre `SabrSession.stream`.
public protocol SabrSink: AnyObject {
    func sabrAppend(_ data: Data, to kind: StreamFormat.Kind)
    /// La pista llegó a su último segmento.
    func sabrFinish(_ kind: StreamFormat.Kind)
}

/// Lo que la sesión necesita del reproductor: su posición. Un motor que ya lleva su propio reloj (el `PlaybackClock`
/// de PlaybackKit) lo entrega con un adaptador que cumple este protocolo.
public protocol SabrClock: AnyObject, Sendable {
    var positionMs: Int64? { get }
}

/// Posición del reproductor (el `time-pos` de mpv), que la sesión lee antes de cada petición.
public final class SabrPlaybackClock: SabrClock, @unchecked Sendable {
    private let lock = NSLock()
    private var position: Int64?

    public init() {}

    public var positionMs: Int64? {
        get { lock.withLock { position } }
        set { lock.withLock { position = newValue } }
    }
}

/// Una pista (formato) de la sesión: metadatos de `FORMAT_INITIALIZATION_METADATA` y segmentos recibidos.
public final class SabrTrack {
    public struct Segment: Sendable {
        public let sequence: Int
        public let startMs: Int64
        public let durationMs: Int64
        public let data: Data
    }

    public let format: StreamFormat?
    public var id: SabrFormatID
    /// Formato que el servidor inicializó sin pedirlo: se anuncia como "todo en búfer" para que no mande más.
    public let discard: Bool
    public var initialized = false
    public var mimeType: String?
    public var endSegmentNumber: Int64?
    public var endTimeMs: Int64?
    public var initSegment: Data?
    /// Segmentos recibidos. En streaming `data` va vacío: los bytes ya se entregaron al sink.
    public private(set) var segments: [Int: Segment] = [:]

    // Entrega en orden (modo streaming).
    var initDelivered = false
    /// Siguiente segmento que toca entregar; nil hasta el primero de la sesión de streaming.
    var nextDelivery: Int?
    /// Segmentos completos que llegaron antes de su turno.
    var held: [Int: Data] = [:]
    /// Bytes ya entregados de un segmento cuya respuesta se cortó: al volver a llegar se saltan.
    var resume: (sequence: Int, bytes: Int)?
    var finished = false
    public private(set) var deliveredBytes: Int64 = 0

    init(format: StreamFormat?, id: SabrFormatID, discard: Bool) {
        self.format = format
        self.id = id
        self.discard = discard
    }

    var kind: StreamFormat.Kind? { discard ? nil : format?.kind }

    /// Guarda el segmento; false si ya estaba.
    func add(_ segment: Segment) -> Bool {
        guard segments[segment.sequence] == nil else { return false }
        segments[segment.sequence] = segment
        return true
    }

    /// Nueva sesión de streaming (inicio o búsqueda): se olvida lo recibido, pero no el segmento de inicio.
    func resetForStreaming() {
        segments = [:]
        initDelivered = false
        nextDelivery = nil
        held = [:]
        resume = nil
        finished = false
        deliveredBytes = 0
    }

    func noteDelivered(_ count: Int) { deliveredBytes += Int64(count) }

    /// Tramo contiguo desde el primer segmento: lo que se escribe a disco y lo que se anuncia como `BufferedRange`.
    public var contiguous: [Segment] {
        guard let first = segments.keys.min() else { return [] }
        var out: [Segment] = []
        var sequence = first
        while let segment = segments[sequence] {
            out.append(segment)
            sequence += 1
        }
        return out
    }

    public var bufferedStartMs: Int64 { contiguous.first?.startMs ?? 0 }
    public var bufferedEndMs: Int64 { contiguous.last.map { $0.startMs + $0.durationMs } ?? 0 }
    public var bufferedMs: Int64 { bufferedEndMs - bufferedStartMs }
    public var bytes: Int { (initSegment?.count ?? 0) + contiguous.reduce(0) { $0 + $1.data.count } }

    public var isComplete: Bool {
        guard let end = endSegmentNumber, let last = contiguous.last else { return false }
        return Int64(last.sequence) >= end
    }

    /// El init de WebM declara el tamaño del elemento Segment del archivo completo; al concatenar solo una parte,
    /// ffmpeg avisa "File ended prematurely". Se reescribe como tamaño desconocido (todos los bits a 1), que es
    /// también lo correcto para un flujo en vivo hacia mpv. MP4 (ftyp+moov, luego moof+mdat) no necesita cambios.
    public static func streamableInit(_ data: Data) -> Data {
        let segmentID: [UInt8] = [0x18, 0x53, 0x80, 0x67]
        let bytes = [UInt8](data)
        guard bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]),
              let at = (0...max(0, bytes.count - 5)).first(where: { Array(bytes[$0..<$0 + 4]) == segmentID }) else { return data }
        let first = bytes[at + 4]
        guard first != 0, let length = (0..<8).first(where: { first & (0x80 >> $0) != 0 }).map({ $0 + 1 }),
              at + 4 + length <= bytes.count else { return data }
        var out = bytes
        out[at + 4] = UInt8((0xFF >> (length - 1)) & 0xFF) // marcador de longitud + bits de valor a 1
        for i in 1..<length { out[at + 4 + i] = 0xFF }
        return Data(out)
    }

    public var fileExtension: String {
        let mime = mimeType ?? format?.mimeType ?? ""
        if mime.hasPrefix("audio/mp4") { return "m4a" }
        if mime.contains("mp4") { return "mp4" }
        return "webm"
    }
}

public struct SabrOptions: Sendable {
    public enum PoTokenChoice: String, Sendable { case session, content }

    /// Segundos de video y de audio que se quieren descargar.
    public var targetSeconds: Double = 12
    public var maxHeight: Int? = 1080
    public var codecOrder: [Codec] = [.vp9, .avc, .av1]
    public var audioCodecs: [Codec] = [.opus, .aac]
    public var videoItag: Int?
    public var audioItag: Int?
    /// Generar PoToken (WKWebView): el web para WEB/MWEB/…, el de TV (tv_config) para TV.
    public var usePoToken = true
    /// Token que va en `StreamerContext.po_token` y en `pot` de la URL SABR: el de sesión (visitorData) o el de contenido.
    public var streamPoToken: PoTokenChoice = .session
    public var potInURL = true
    public var solveN = true
    /// Tope de peticiones; nil = 40 o más según la duración pedida (el servidor manda ~5–10 s por petición).
    public var maxRequests: Int?
    public var maxReloads = 2
    /// Guarda en memoria los bytes de cada segmento (para `write(to:)`). En streaming se entregan y se sueltan.
    public var retainSegments = true
    /// Streaming: solo se pide más mientras lo que hay por delante del reproductor sea menor que esto.
    public var readaheadMs: Int64 = 15_000
    /// Imprime el detalle de cada petición (`describe`); en streaming se usa `SabrSession.onRequest`.
    public var logRequests = true
    /// Guarda cada respuesta UMP cruda (depuración).
    public var dumpDirectory: URL?
    /// Experimento: usa este `videoPlaybackUstreamerConfig` (bytes crudos) en lugar del del player, para ver
    /// cómo reacciona el servidor a una configuración vieja (p. ej. si pide RELOAD_PLAYER_RESPONSE).
    public var staleUstreamerConfig: Data?
    /// Streaming: la URL y el PoToken se renuevan este margen antes de caducar (como mucho un cuarto de su vida).
    public var renewalMargin: TimeInterval = 600
    /// Prueba: vida de la URL SABR en segundos desde que se obtiene, en lugar de su `expire` (6 h).
    public var urlLifetime: TimeInterval?
    /// Prueba: vida del PoToken en segundos desde que se mintea, en lugar de la del integrityToken (12 h).
    public var poTokenLifetime: TimeInterval?
    /// Tras un LOGIN_REQUIRED, pedir el player otra vez con visitante y PoToken nuevos (y la cuenta, si hay).
    public var recoverLoginRequired = true
    /// Prueba: las primeras N respuestas del player son un LOGIN_REQUIRED (el chequeo antibots), sin pedirlas.
    public var simulatedLoginRequired = 0
    /// Streaming: fallos seguidos de googlevideo (red, HTTP, UMP) tras los que la sesión se rinde.
    public var maxConsecutiveFailures = 8
    /// Segundos sin recibir nada (conexión, cabeceras o cuerpo) tras los que una petición SABR falla con
    /// `URLError.timedOut`. 30 s es lo que ya hacía URLSession y lo que usa `sabr`; `sabrplay` usa 8 s, porque mpv
    /// tiene ~15 s por delante y tras el tiempo de espera todavía hay que pedir a otra CDN.
    public var requestTimeout: TimeInterval = 30
    public init() {}
}

/// Fallos provocados para probar la recuperación (`sabrplay --fault-at`). Todos dan errores reales del servidor o
/// de la red: no se simula ninguna respuesta.
public enum SabrFault: String, Sendable, CaseIterable {
    /// `n` sin transformar en la URL: googlevideo responde HTTP 403.
    case forbidden = "403"
    /// Como `403`, pero cada player nuevo vuelve a traer el `n` sin transformar: el 403 no se va y la sesión agota
    /// sus intentos (`maxConsecutiveFailures`).
    case forbiddenPersistent = "403+"
    /// Como `403+` hasta que se mintea un PoToken nuevo, como si el que hay ya no valiera.
    case forbiddenUntilPoToken = "403pot"
    /// El host de la CDN actual pasa a uno que no existe (`.invalid`, sin DNS): error de conexión.
    case cdn
    /// Todos los hosts candidatos pasan a no existir: se agotan las CDN y hay que pedir el player.
    case net
    /// La CDN actual no contesta: su host pasa a 192.0.2.1 (TEST-NET-1, RFC 5737), donde nadie responde al SYN, y la
    /// petición espera hasta `requestTimeout`.
    case stall
}

/// `SabrCdnSelector` de SmartTube: la URL firmada anuncia en `mn` las redes de medios equivalentes, la actual y las
/// de respaldo; el host de la red i es `rr<i+1>---<mn[i]>.googlevideo.com`. Se avanza solo hacia adelante.
struct SabrCDNSelector {
    private(set) var hosts: [String] = []
    private(set) var index = 0

    init(url: String) {
        guard let components = URLComponents(string: url), let host = components.host else { return }
        hosts = [host]
        let suffix = ".googlevideo.com"
        guard host.hasSuffix(suffix), let dashes = host.range(of: "---"),
              let networks = components.value("mn")?.split(separator: ",").map(String.init) else { return }
        let network = String(host[dashes.upperBound..<host.index(host.endIndex, offsetBy: -suffix.count)])
        guard let current = networks.firstIndex(of: network) else { return }
        for i in networks.indices where i > current && networks[i].range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil {
            hosts.append("rr\(i + 1)---\(networks[i])\(suffix)")
        }
    }

    var current: String? { hosts.isEmpty ? nil : hosts[index] }
    var remaining: Int { max(0, hosts.count - index - 1) }

    mutating func advance() -> String? {
        guard index + 1 < hosts.count else { return nil }
        index += 1
        return hosts[index]
    }

    /// Prueba (`SabrFault`): el host actual (o todos) deja de existir.
    mutating func breakHosts(all: Bool) {
        for i in hosts.indices where all || i == index { hosts[i] = "rr\(i + 1)---sn-glasstube-falla\(i + 1).googlevideo.invalid" }
    }

    /// Prueba (`SabrFault.stall`): el host actual pasa a una IP donde nadie contesta.
    mutating func silenceCurrent() {
        if !hosts.isEmpty { hosts[index] = "192.0.2.1" }
    }
}

/// googlevideo respondió con un código distinto de 200.
public struct SabrHTTPError: Error, CustomStringConvertible {
    public let status: Int
    public let host: String?
    public let body: String
    public var description: String {
        "googlevideo HTTP \(status)\(host.map { " (\($0))" } ?? "")" + (body.isEmpty ? " sin cuerpo" : ": \(body.prefix(160))")
    }
}

/// Parte `SABR_ERROR` (p. ej. `sabr.malformed_config`): el servidor ya no acepta la configuración de la sesión.
public struct SabrServerError: Error, CustomStringConvertible {
    public let description: String
}

/// Resumen de una petición SABR.
public struct SabrRequestLog: Sendable {
    public var rn: Int
    public var playerTimeMs: Int64
    public var status: Int = 0
    public var bytes = 0
    public var elapsed: TimeInterval = 0
    public var parts: [String: Int] = [:]
    public var newSegments = 0
    public var protection: Int64?
    public var backoffMs: Int64?
    public var notes: [String] = []
    /// Tramo contiguo de cada pista al terminar la petición (ms).
    public var buffered: [StreamFormat.Kind: Range<Int64>] = [:]
    public var host: String?
}

public struct SabrError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Sesión SABR de un video: pide el player, prepara la URL (n, pot) y descarga los primeros segundos.
/// El player no dio el video (`playabilityStatus` distinto de OK): LOGIN_REQUIRED, UNPLAYABLE, ERROR…
public struct SabrUnplayableError: Error, CustomStringConvertible, Sendable {
    public let status: String
    public let reason: String?
    /// El player se pidió con la cuenta.
    public let signedIn: Bool

    /// YouTube pide iniciar sesión (el «confirma que no eres un bot», o la edad).
    public var needsSignIn: Bool { status == "LOGIN_REQUIRED" }
    public var description: String { "player: \(status)" + (reason.map { " \($0)" } ?? "") }
}

public final class SabrSession {
    public let videoId: String
    public let client: ClientProfile
    public let options: SabrOptions
    let poTokenSource: PoTokenSource?
    let innertube = Innertube()
    let scripts = PlayerScriptStore.shared
    let solver = ChallengeSolver.shared

    // Resultado / diagnóstico
    public private(set) var title: String?
    public private(set) var requests: [SabrRequestLog] = []
    public private(set) var reloads = 0
    public private(set) var poToken: PoTokenResult?
    public private(set) var poTokenKind: ClientProfile.PoTokenKind?
    private var livingRoomPoTokenId: String?
    public private(set) var nTransform: (from: String, to: String)?
    public private(set) var playerVariant: ClientProfile.PlayerVariant?
    public private(set) var sabrURLHost: String?
    public private(set) var ustreamerConfigBytes = 0
    /// Formatos adaptativos del player y cuántos traen URL o firma cifrada (0 = solo SABR).
    public private(set) var adaptiveCount = 0
    public private(set) var adaptiveWithURL = 0
    public private(set) var lastProtection: Int64?
    public private(set) var snackbars: [String] = []
    /// `NextRequestPolicy` de la primera respuesta: readahead objetivo (audio, video) y mínimo (audio, video) en ms.
    public private(set) var readahead: (targetAudio: Int64?, targetVideo: Int64?, minAudio: Int64?, minVideo: Int64?)
    public private(set) var video: SabrTrack?
    public private(set) var audio: SabrTrack?
    public private(set) var durationMs: Int64?
    /// Formatos de video y audio del último player (para cambiar de calidad). La tarea de streaming los reescribe al
    /// renovar y el reproductor los lee al pulsar una tecla: van con candado.
    public var formats: [StreamFormat] { formatsLock.withLock { latestFormats } }
    private var latestFormats: [StreamFormat] = []
    private let formatsLock = NSLock()
    /// Caducidad de la URL SABR (`expire`, o `--url-ttl`) y del PoToken (integrityToken, o `--potoken-ttl`).
    public private(set) var urlObtainedAt: Date?
    public private(set) var urlExpiresAt: Date?
    public private(set) var poTokenObtainedAt: Date?
    public private(set) var poTokenExpiresAt: Date?
    /// Contadores de la vida de la sesión en streaming.
    public private(set) var urlRenewals = 0
    public private(set) var poTokenRenewals = 0
    public private(set) var cdnSwitches = 0
    public private(set) var errorReloads = 0
    /// PoToken minteados tras un 403 (no por caducidad).
    public private(set) var errorPoTokens = 0
    public private(set) var recoveries = 0
    /// Cuenta con la que se pide el player cuando hay sesión (ver `playablePlayer`); nil = siempre anónimo.
    public var account: AccountManager?
    /// Intentos del último player (1, o 2 tras un LOGIN_REQUIRED), qué recuperación se usó y si fue con la cuenta.
    public private(set) var playerAttempts = 0
    public private(set) var playerRecoveries: [String] = []
    public private(set) var playerSignedIn = false
    /// Por qué el último player no dio el video (nil si lo dio).
    public private(set) var lastUnplayable: SabrUnplayableError?
    /// Se llama al terminar cada petición (en la tarea de la sesión).
    public var onRequest: ((SabrRequestLog) -> Void)?
    /// Hechos de la sesión (renovaciones, cambios de CDN, recuperaciones), en la tarea de la sesión.
    public var onEvent: ((String) -> Void)?

    // Estado del protocolo
    private var url = ""
    private var cdn = SabrCDNSelector(url: "")
    /// Tras un fallo al renovar, no se reintenta antes de esto (se sigue con la URL vigente).
    private var nextRenewalAttempt = Date.distantPast
    private let faultLock = NSLock()
    private var pendingFaults: [SabrFault] = []
    /// Prueba: `403+` o `403pot` en curso; cada player nuevo vuelve a traer el `n` sin transformar.
    private var stickyFault: SabrFault?
    private var ustreamerConfig = Data()
    private var streamPoToken: Data?
    private var playbackCookie: Data?
    private var backoffMs: Int64 = 0
    private var contexts: [Int: Data] = [:]
    private var contextsToSend: Set<Int> = []
    private var tracks: [Int: SabrTrack] = [:]
    /// Formatos que se dejaron al cambiar de calidad (no se declaran al servidor).
    private var retired: [Int: SabrTrack] = [:]
    /// Segmentos de la respuesta en curso, por `header_id` (los ids valen solo dentro de una respuesta).
    private var partial: [UInt64: PartialSegment] = [:]
    private var requestNumber = 0
    private var playerTimeMs: Int64 = 0
    private var sink: SabrSink?
    private let transport = SabrTransport.shared

    /// Segmento a medio llegar. `live`: es el siguiente de su pista y sus bytes van al sink conforme llegan
    /// (saltando `skip` bytes ya entregados por una respuesta anterior que se cortó); `hold`: se junta en memoria
    /// hasta MEDIA_END; `drop`: repetido o de un formato descartado.
    private final class PartialSegment {
        enum Mode { case live(skip: Int), hold, drop }
        let itag: Int
        let isInit: Bool
        let sequence: Int
        let startMs: Int64
        let durationMs: Int64
        let mode: Mode
        var data = Data()
        var received = 0

        init(itag: Int, isInit: Bool, sequence: Int, startMs: Int64, durationMs: Int64, mode: Mode) {
            self.itag = itag
            self.isInit = isInit
            self.sequence = sequence
            self.startMs = startMs
            self.durationMs = durationMs
            self.mode = mode
        }
    }

    public init(videoId: String, client: ClientProfile, options: SabrOptions, poTokenSource: PoTokenSource?) {
        self.videoId = videoId
        self.client = client
        self.options = options
        self.poTokenSource = poTokenSource
    }

    var activeTracks: [SabrTrack] { [video, audio].compactMap { $0 } }

    var done: Bool {
        activeTracks.allSatisfy { $0.isComplete || Double($0.bufferedMs) >= options.targetSeconds * 1000 }
    }

    // MARK: - Bucle principal

    public func run() async throws {
        try await loadPlayer(reloadToken: nil)
        var emptyStreak = 0
        let maxRequests = options.maxRequests ?? max(40, Int(options.targetSeconds / 3) + 10)
        while !done {
            guard requests.count < maxRequests else { throw SabrError("se alcanzó el máximo de \(maxRequests) peticiones") }
            if backoffMs > 0 {
                Log.info("  backoff del servidor: \(backoffMs) ms")
                try await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                backoffMs = 0
            }
            let outcome = try await request()
            switch outcome {
            case .reload(let token):
                reloads += 1
                guard reloads <= options.maxReloads else { throw SabrError("el servidor pidió recargar el player \(reloads) veces") }
                Log.info("  RELOAD_PLAYER_RESPONSE: se vuelve a pedir el player con el token de recarga (\(token?.count ?? 0) car.)")
                try await loadPlayer(reloadToken: token)
                continue
            case .redirect:
                continue
            case .media(let newSegments):
                if newSegments == 0 {
                    emptyStreak += 1
                    if emptyStreak >= 3 {
                        let protection = lastProtection.map { " (StreamProtectionStatus \(Self.protectionName($0)))" } ?? ""
                        throw SabrError("3 respuestas seguidas sin segmentos nuevos\(protection)")
                    }
                } else {
                    emptyStreak = 0
                }
            }
            // Simula que el reproductor avanzó hasta el final de lo que tiene la pista más atrasada.
            let pending = activeTracks.filter { !$0.isComplete }
            if let minEnd = pending.map(\.bufferedEndMs).min() { playerTimeMs = minEnd }
        }
    }

    /// Pide el player (y el PoToken) sin bajar nada todavía.
    public func prepare() async throws {
        try await loadPlayer(reloadToken: nil)
    }

    // MARK: - Streaming (fuente de datos de mpv)

    /// Entrega a `sink` el segmento de inicio y luego los segmentos de cada pista desde `startMs`, en orden y
    /// conforme llegan, y solo pide más mientras lo que hay por delante de `clock` sea menor que `readaheadMs`
    /// (en pausa no pide). Termina cuando las dos pistas llegan al final (`sabrFinish`) o al cancelar la tarea.
    /// Una búsqueda fuera de lo que ya tiene el reproductor es otra llamada con otro `startMs` y otro sink, en la
    /// misma sesión: se reutilizan el player, la URL, el PoToken y los segmentos de inicio.
    public func stream(from startMs: Int64, to sink: SabrSink, clock: SabrClock) async throws {
        if url.isEmpty { try await loadPlayer(reloadToken: nil) }
        self.sink = sink
        defer { self.sink = nil }
        for track in tracks.values { track.resetForStreaming() }
        partial = [:]
        playerTimeMs = startMs
        for track in activeTracks { deliverPending(track) }

        var emptyStreak = 0
        var streak = FailureStreak()
        while true {
            try Task.checkCancellation()
            let pending = activeTracks.filter { !$0.finished }
            if pending.isEmpty { return }
            applyFaults()
            // También con el búfer lleno o en pausa: la URL y el PoToken se renuevan antes de caducar.
            await renewIfNeeded()
            let position = playbackPosition(clock: clock, startMs: startMs)
            let ahead = pending.map { $0.contiguous.isEmpty ? 0 : $0.bufferedEndMs - position }.min() ?? 0
            if ahead >= options.readaheadMs {
                try await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            if backoffMs > 0 {
                Log.info("  backoff del servidor: \(backoffMs) ms")
                try await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                backoffMs = 0
            }
            playerTimeMs = position
            let outcome: Outcome
            let requestStart = Date()
            do {
                outcome = try await request()
                if streak.count > 0, let since = streak.since {
                    recoveries += 1
                    event(String(format: "recuperado: rn=%d HTTP 200 en %@ tras %d fallo(s) y %.1f s sin datos nuevos", requestNumber - 1,
                                 cdn.current ?? "?", streak.count, Date().timeIntervalSince(since)))
                }
                streak = FailureStreak()
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                if streak.since == nil { streak.since = requestStart } // sin datos nuevos desde que empezó la petición
                try await recover(from: error, streak: &streak)
                continue
            }
            switch outcome {
            case .reload(let token):
                reloads += 1
                guard reloads <= options.maxReloads else { throw SabrError("el servidor pidió recargar el player \(reloads) veces") }
                Log.info("  RELOAD_PLAYER_RESPONSE: se vuelve a pedir el player con el token de recarga (\(token?.count ?? 0) car.)")
                try await loadPlayer(reloadToken: token)
            case .redirect:
                break
            case .media(let newSegments):
                if newSegments > 0 {
                    emptyStreak = 0
                    continue
                }
                emptyStreak += 1
                guard emptyStreak < 20 else {
                    let protection = lastProtection.map { " (StreamProtectionStatus \(Self.protectionName($0)))" } ?? ""
                    throw SabrError("20 respuestas seguidas sin segmentos nuevos\(protection)")
                }
                try await Task.sleep(nanoseconds: UInt64(min(emptyStreak, 4)) * 500_000_000)
            }
        }
    }

    /// `time-pos` del reproductor acotado a lo que ya hay en búfer. Antes de que mpv arranque (o si todavía llega
    /// un valor del archivo anterior a una búsqueda) vale el inicio pedido.
    private func playbackPosition(clock: SabrClock, startMs: Int64) -> Int64 {
        let ranges = activeTracks.filter { !$0.contiguous.isEmpty }.map { ($0.bufferedStartMs, $0.bufferedEndMs) }
        guard let position = clock.positionMs, let low = ranges.map(\.0).min(), let high = ranges.map(\.1).max() else { return startMs }
        return min(max(position, low), high)
    }

    // MARK: - Cambio de calidad

    /// Cambia la pista de video (o de audio) por otro formato del player. Se llama entre dos `stream(from:…)`, con la
    /// sesión de streaming anterior ya cancelada: la siguiente pide el formato nuevo desde la posición que se le dé
    /// (el servidor manda su FORMAT_INITIALIZATION_METADATA y su segmento de inicio). El formato anterior deja de
    /// declararse: no va en `selected_format_ids` ni en `buffered_ranges`. Declararlo "todo en búfer", como un formato
    /// no pedido, no sirve: es del mismo tipo que el nuevo y el servidor deja de mandar video (respuestas vacías con
    /// backoff de 2 s). Su segmento de inicio se guarda por si se vuelve a él.
    public func switchFormat(to format: StreamFormat) {
        guard format.kind != .muxed, let old = format.kind == .video ? video : audio, old.id.itag != format.itag else { return }
        tracks[old.id.itag] = nil
        retired[old.id.itag] = old
        let previous = retired.removeValue(forKey: format.itag)
        let track = SabrTrack(format: format, id: previous?.id ?? SabrFormatID(format: format), discard: false)
        // Sin declararlo inicializado: el servidor vuelve a mandar su FORMAT_INITIALIZATION_METADATA (y el segmento
        // de inicio, que se descarta si ya se tenía).
        track.initSegment = previous?.initSegment
        tracks[format.itag] = track
        if format.kind == .video { video = track } else { audio = track }
    }

    // MARK: - Vida de la URL y del PoToken, y recuperación ante errores

    /// Prueba: provoca un fallo antes de la próxima petición (se puede llamar desde cualquier hilo).
    public func inject(_ fault: SabrFault) {
        faultLock.withLock { pendingFaults.append(fault) }
    }

    private func applyFaults() {
        let faults = faultLock.withLock { () -> [SabrFault] in
            defer { pendingFaults = [] }
            return pendingFaults
        }
        for fault in faults {
            switch fault {
            case .forbidden:
                breakN("prueba 403")
            case .forbiddenPersistent, .forbiddenUntilPoToken:
                stickyFault = fault
                breakN("prueba \(fault.rawValue)" + (fault == .forbiddenPersistent ? " (y en cada player nuevo)" : " (y en cada player nuevo hasta que haya PoToken nuevo)"))
            case .cdn, .net, .stall:
                guard var components = URLComponents(string: url) else { continue }
                if fault == .stall { cdn.silenceCurrent() } else { cdn.breakHosts(all: fault == .net) }
                components.host = cdn.current
                url = components.url!.absoluteString
                let what = fault == .net ? "ningún host candidato existe" : fault == .cdn ? "la CDN actual deja de existir" : "la CDN actual no contesta"
                event("prueba \(fault.rawValue): \(what) → \(cdn.hosts.joined(separator: ", "))")
            }
        }
    }

    /// Prueba: vuelve a poner en la URL el `n` sin transformar del player vigente; googlevideo responde 403.
    private func breakN(_ label: String) {
        guard var components = URLComponents(string: url), let raw = nTransform?.from else {
            event("\(label): la URL no trae n; no se aplica")
            return
        }
        components.set("n", raw)
        url = components.url!.absoluteString
        event("\(label): n sin transformar en la URL (\(raw.prefix(12))…)")
    }

    /// Cuándo renovar algo que caduca en `expires` y se obtuvo en `obtained`: `renewalMargin` antes, y como mucho un
    /// cuarto de su vida antes (para que las vidas cortas de prueba no se renueven en cada petición).
    private func renewalDate(expires: Date?, obtained: Date?) -> Date? {
        guard let expires, let obtained else { return nil }
        let lifetime = expires.timeIntervalSince(obtained)
        return expires.addingTimeInterval(-min(options.renewalMargin, max(0, lifetime / 4)))
    }

    /// Si la URL o el PoToken están por caducar, se pide el player de nuevo (con un PoToken nuevo si toca) y se sigue
    /// con los mismos segmentos: mpv lee de lo que ya hay por delante (unos 15 s) mientras tanto. Si falla, se sigue
    /// con la URL vigente y se reintenta en 30 s.
    private func renewIfNeeded() async {
        let now = Date()
        guard now >= nextRenewalAttempt else { return }
        let urlDue = renewalDate(expires: urlExpiresAt, obtained: urlObtainedAt).map { now >= $0 } ?? false
        let poTokenDue = poToken != nil && (renewalDate(expires: poTokenExpiresAt, obtained: poTokenObtainedAt).map { now >= $0 } ?? false)
        guard urlDue || poTokenDue else { return }
        let why = [urlDue ? "la URL caduca " + Self.relative(urlExpiresAt) : nil,
                   poTokenDue ? "el PoToken caduca " + Self.relative(poTokenExpiresAt) : nil].compactMap { $0 }.joined(separator: " y ")
        do {
            try await reloadPlayer(why, mintPoToken: poTokenDue)
            urlRenewals += 1 // cada player nuevo trae URL nueva, también al renovar solo el PoToken
            if poTokenDue { poTokenRenewals += 1 }
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            nextRenewalAttempt = now.addingTimeInterval(30)
            event("renovación falló (\(Self.short(error))); se sigue con la URL vigente y se reintenta en 30 s")
        }
    }

    /// Pide el player otra vez (URL, `n`, config y CDN nuevos; con `mintPoToken`, también PoToken nuevo) y sigue con
    /// los segmentos, la cookie y el número de petición de la sesión.
    private func reloadPlayer(_ why: String, mintPoToken mint: Bool) async throws {
        let start = Date()
        let oldURL = URLComponents(string: url)
        let oldConfig = ustreamerConfig
        let oldToken = poToken?.playerPoToken
        if mint { try await mintPoToken() }
        try await loadPlayer(reloadToken: nil)
        let newURL = URLComponents(string: url)
        let expire = { (c: URLComponents?) in c?.value("expire") ?? "?" }
        var changes = ["expire \(expire(oldURL)) → \(expire(newURL))"]
        changes.append(oldURL?.value("sig") == newURL?.value("sig") ? "misma firma" : "firma nueva")
        changes.append(oldURL?.value("n") == newURL?.value("n") ? "mismo n" : "n nuevo")
        changes.append(oldConfig == ustreamerConfig ? "mismo config" : "config nuevo (\(ustreamerConfig.count) B)")
        if poToken != nil { changes.append(poToken?.playerPoToken == oldToken ? "mismo PoToken" : "PoToken nuevo") }
        changes.append("host \(cdn.current ?? "?")" + (cdn.remaining > 0 ? " (+\(cdn.remaining) CDN de respaldo)" : ""))
        event(String(format: "player pedido de nuevo (%@) en %.1f s: %@; caduca %@", why, Date().timeIntervalSince(start),
                     changes.joined(separator: ", "), Self.relative(urlExpiresAt)))
    }

    private enum FailureKind { case forbidden, transient, fatal }

    private static func classify(_ error: Error) -> FailureKind {
        switch error {
        case let error as SabrHTTPError: return [401, 403, 410].contains(error.status) ? .forbidden : .transient
        case is SabrServerError: return .forbidden // config o sesión que el servidor ya no acepta: player nuevo
        case let error as URLError: return error.code == .cancelled ? .fatal : .transient
        case is SabrError: return .transient // UMP incoherente o cortado: se reintenta
        default: return .fatal
        }
    }

    /// Fallos seguidos de googlevideo en una sesión de streaming; se reinicia con la primera respuesta 200.
    private struct FailureStreak {
        var count = 0
        var forbidden = 0
        var since: Date?
        /// Cuántos de cada tipo ("HTTP 403", "URLError -1001", …), en orden de aparición.
        var reasons: [(String, Int)] = []
        var players = 0
        var poTokens = 0

        mutating func note(_ reason: String) {
            if let i = reasons.firstIndex(where: { $0.0 == reason }) { reasons[i].1 += 1 } else { reasons.append((reason, 1)) }
        }
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case let error as SabrHTTPError: return "HTTP \(error.status)"
        case let error as URLError: return "URLError \(error.code.rawValue)"
        case is SabrServerError: return "SABR_ERROR"
        default: return "\(type(of: error))"
        }
    }

    /// Ante un fallo de googlevideo, en lugar de detenerse: 403 (o SABR_ERROR) → player nuevo, al segundo seguido
    /// también PoToken nuevo (una vez por racha) y desde el tercero con una espera creciente; sin respuesta en `requestTimeout` → la siguiente CDN de `mn` (otro
    /// tiempo de espera en el mismo host no cabe en lo que mpv tiene por delante); otro error de red o HTTP 5xx → un
    /// reintento, luego la siguiente CDN y, sin más CDN, player nuevo. Al llegar a `maxConsecutiveFailures` fallos
    /// seguidos lanza un `SabrError` con el resumen de la racha.
    private func recover(from error: Error, streak: inout FailureStreak) async throws {
        streak.count += 1
        streak.note(Self.reason(error))
        let kind = Self.classify(error)
        guard kind != .fatal else {
            event("fallo \(streak.count): \(Self.short(error)) → se detiene")
            throw error
        }
        guard streak.count < options.maxConsecutiveFailures else {
            let reasons = streak.reasons.map { "\($0.1)× \($0.0)" }.joined(separator: ", ")
            let count = { (n: Int, one: String, many: String) in "\(n) \(n == 1 ? one : many)" }
            let message = String(format: "googlevideo falló %d veces seguidas en %.1f s (%@), con %@ y %@ por el camino; el último: %@",
                                 streak.count, Date().timeIntervalSince(streak.since ?? Date()), reasons,
                                 count(streak.players, "player nuevo", "players nuevos"), count(streak.poTokens, "PoToken nuevo", "PoToken nuevos"),
                                 Self.short(error))
            event("fallo \(streak.count) de \(options.maxConsecutiveFailures) → la sesión se detiene: \(message)")
            throw SabrError(message)
        }
        let what = "fallo \(streak.count) en \(cdn.current ?? "?"): \(Self.short(error))"
        let timedOut = (error as? URLError)?.code == .timedOut
        switch kind {
        case .forbidden:
            streak.forbidden += 1
            let mint = streak.forbidden >= 2 && streak.poTokens == 0 && poToken != nil
            // Desde el tercero seguido, 1 y luego 2 s antes de pedir el player: los 8 intentos duran ~13 s, algo menos que
            // el búfer (~15 s), en lugar de pedir el player varias veces por segundo (sin espera: 8 en 3,2 s; con
            // tope de 3 s: 16 s, y mpv se quedaba sin datos antes del error).
            let wait = streak.forbidden >= 3 ? min(streak.forbidden - 2, 2) : 0
            event("\(what) → \(wait > 0 ? "en \(wait) s " : "")player nuevo\(mint ? " y PoToken nuevo" : "")")
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000) }
            if await reloadAfterError(mintPoToken: mint) {
                streak.players += 1
                if mint { streak.poTokens += 1 }
            }
        case .transient where streak.count == 1 && !timedOut:
            event("\(what) → reintento en el mismo host")
            try await Task.sleep(nanoseconds: 500_000_000)
        case .transient:
            if let host = cdn.advance(), var components = URLComponents(string: url) {
                components.host = host
                url = components.url!.absoluteString
                cdnSwitches += 1
                event("\(what) → otra CDN: \(host)")
            } else {
                event("\(what) → sin más CDN: player nuevo")
                if await reloadAfterError(mintPoToken: false) { streak.players += 1 }
            }
        case .fatal:
            break
        }
    }

    /// Player nuevo tras un error; si el propio player falla, se espera y el bucle vuelve a intentar (cuenta como fallo).
    private func reloadAfterError(mintPoToken mint: Bool) async -> Bool {
        do {
            try await reloadPlayer("tras un error", mintPoToken: mint)
            errorReloads += 1
            if mint { errorPoTokens += 1 }
            return true
        } catch {
            event("el player también falló: \(Self.short(error))")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return false
        }
    }

    /// URLError trae el diccionario entero en su descripción; basta el código y el texto.
    static func short(_ error: Error) -> String {
        if let error = error as? URLError { return "URLError \(error.code.rawValue) (\(error.localizedDescription))" }
        return "\(error)"
    }

    private func event(_ message: String) {
        if let onEvent { onEvent(message) } else { Log.info("  \(message)") }
    }

    public static func relative(_ date: Date?) -> String {
        guard let date else { return "?" }
        let seconds = Int(date.timeIntervalSinceNow.rounded())
        let magnitude = abs(seconds)
        let text = magnitude >= 3600 ? String(format: "%d h %02d min", magnitude / 3600, magnitude % 3600 / 60)
            : magnitude >= 60 ? String(format: "%d min %02d s", magnitude / 60, magnitude % 60) : "\(magnitude) s"
        return seconds >= 0 ? "en \(text)" : "hace \(text)"
    }

    /// Escribe init + segmentos contiguos de cada pista. Devuelve las rutas.
    public func write(to directory: URL) throws -> [(track: SabrTrack, url: URL)] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [(SabrTrack, URL)] = []
        for track in activeTracks {
            var data = track.initSegment.map(SabrTrack.streamableInit) ?? Data()
            for segment in track.contiguous { data.append(segment.data) }
            let kind = track === video ? "video" : "audio"
            let file = directory.appendingPathComponent("\(videoId).\(kind).\(track.id.itag).\(track.fileExtension)")
            try data.write(to: file)
            written.append((track, file))
        }
        return written
    }

    // MARK: - Player (y recarga)

    private func loadPlayer(reloadToken: String?) async throws {
        let (playerURL, variant) = try await scripts.playerURL(for: client)
        playerVariant = variant
        let sts = try await scripts.signatureTimestamp(for: playerURL)

        if options.usePoToken, poToken == nil { try await mintPoToken() }

        let response = try await playablePlayer(signatureTimestamp: sts, reloadToken: reloadToken)
        title = response.videoDetails?.title ?? title
        durationMs = response.videoDetails?.lengthSeconds.flatMap { Int64($0) }.map { $0 * 1000 } ?? durationMs
        guard let rawURL = response.streamingData?.serverAbrStreamingUrl else { throw SabrError("el player no trae serverAbrStreamingUrl") }
        guard let configString = response.videoPlaybackUstreamerConfig, let config = Data(base64URL: configString) else {
            throw SabrError("el player no trae videoPlaybackUstreamerConfig")
        }
        let firstLoad = url.isEmpty
        ustreamerConfig = config
        if firstLoad, reloadToken == nil, let stale = options.staleUstreamerConfig {
            ustreamerConfig = stale
            Log.info("  experimento: videoPlaybackUstreamerConfig viejo (\(stale.count) B) en lugar del recibido")
        }
        ustreamerConfigBytes = config.count

        let adaptive = response.streamingData?.adaptiveFormats ?? []
        adaptiveCount = adaptive.count
        adaptiveWithURL = adaptive.filter { $0.url != nil || ($0.signatureCipher ?? $0.cipher) != nil }.count

        // Formatos: en SABR no traen URL; solo itag, lastModified, xtags y metadatos.
        let formats = response.rawFormats().filter { $0.1 != .muxed }.map { StreamFormat(raw: $0.0, kind: $0.1) }
        formatsLock.withLock { latestFormats = formats }
        if video == nil || audio == nil {
            let chosenVideo = options.videoItag.flatMap { itag in formats.first { $0.itag == itag } }
                ?? TrackSelector.bestVideo(formats, maxHeight: options.maxHeight, codecOrder: options.codecOrder, requireURL: false)
                ?? TrackSelector.bestVideo(formats, maxHeight: options.maxHeight, codecOrder: Codec.allCases, allowHDR: true, requireURL: false)
            let chosenAudio = options.audioItag.flatMap { itag in formats.first { $0.itag == itag } }
                ?? TrackSelector.bestAudio(formats, codecOrder: options.audioCodecs, requireURL: false)
            guard let chosenVideo, let chosenAudio else { throw SabrError("no hay formatos de video y audio en la respuesta") }
            video = SabrTrack(format: chosenVideo, id: SabrFormatID(format: chosenVideo), discard: false)
            audio = SabrTrack(format: chosenAudio, id: SabrFormatID(format: chosenAudio), discard: false)
            tracks[chosenVideo.itag] = video
            tracks[chosenAudio.itag] = audio
        }

        // URL: n transformado (igual que VideoUrlHolder para sabrUrlHolder) y `pot` si hay PoToken.
        guard var components = URLComponents(string: rawURL) else { throw SabrError("URL SABR inválida") }
        if options.solveN, let n = components.value("n") {
            let code: @Sendable () async throws -> String = { [scripts] in try await scripts.code(for: playerURL) }
            let result = variant == .tcl
                ? try await solver.solveTCL(playerURL: playerURL, playerCode: code, n: [n])
                : try await solver.solve(playerURL: playerURL, playerCode: code, n: [n], sig: [])
            guard let newN = result.n[n] else { throw SabrError("no se pudo resolver n: \(result.nError ?? "?")") }
            components.set("n", newN)
            nTransform = (n, newN)
        }
        if let poToken {
            let token = options.streamPoToken == .session ? poToken.streamingPoToken : poToken.playerPoToken
            streamPoToken = Data(base64URL: token)
            if options.potInURL { components.set("pot", token) }
        }
        url = components.url!.absoluteString
        sabrURLHost = components.host
        cdn = SabrCDNSelector(url: url)
        let now = Date()
        urlObtainedAt = now
        let expire = components.value("expire").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            ?? response.streamingData?.expiresInSeconds.flatMap(TimeInterval.init).map { now.addingTimeInterval($0) }
        urlExpiresAt = options.urlLifetime.map { now.addingTimeInterval($0) } ?? expire
        nextRenewalAttempt = .distantPast
        if let stickyFault { breakN("prueba \(stickyFault.rawValue): el player nuevo también") }
        if firstLoad {
            Log.info("URL SABR: host \(components.host ?? "?"), expire \(components.value("expire") ?? "?") (caduca \(Self.relative(expire)))"
                + ", mn \(components.value("mn") ?? "-") → \(cdn.hosts.count) CDN"
                + (options.urlLifetime.map { String(format: " · prueba: se trata como si caducara a los %.0f s", $0) } ?? ""))
        }
    }

    /// El player, con la cuenta si hay sesión (como SmartTube con el cliente TV). YouTube responde LOGIN_REQUIRED
    /// («Inicia sesión para confirmar que no eres un bot») a peticiones anónimas cuando desconfía del visitante o de la
    /// IP, y también a un video con restricción de edad. Entonces se pide una vez más con visitante (/tv) y PoToken
    /// nuevos, y con la cuenta si la primera vez fue anónima porque todavía no se sabía de la sesión.
    private func playablePlayer(signatureTimestamp sts: Int?, reloadToken: String?) async throws -> PlayerResponse {
        playerRecoveries = []
        var headers = await accountHeaders()
        var response = try await requestPlayer(signatureTimestamp: sts, reloadToken: reloadToken, headers: headers)
        playerAttempts = 1
        if response.playabilityStatus?.status == "LOGIN_REQUIRED", options.recoverLoginRequired {
            event("player: \(Self.playability(response)) → visitante y PoToken nuevos" + (headers.isEmpty ? "" : ", con la cuenta"))
            await scripts.renewAppInfo()
            if options.usePoToken { try await mintPoToken() }
            if headers.isEmpty { headers = await accountHeaders() }
            // El token de recarga es de un solo uso: el segundo intento va sin él.
            response = try await requestPlayer(signatureTimestamp: sts, reloadToken: nil, headers: headers)
            playerAttempts += 1
            playerRecoveries.append(headers.isEmpty ? "visitante nuevo" : "visitante nuevo con la cuenta")
        }
        playerSignedIn = !headers.isEmpty
        guard response.playabilityStatus?.status == "OK" else {
            let error = SabrUnplayableError(status: response.playabilityStatus?.status ?? "?", reason: response.playabilityStatus?.reason,
                                            signedIn: playerSignedIn)
            lastUnplayable = error
            throw error
        }
        lastUnplayable = nil
        return response
    }

    private func requestPlayer(signatureTimestamp sts: Int?, reloadToken: String?, headers: [String: String]) async throws -> PlayerResponse {
        if simulatedLoginRequired < options.simulatedLoginRequired {
            simulatedLoginRequired += 1
            event("prueba: el player responde LOGIN_REQUIRED (\(simulatedLoginRequired) de \(options.simulatedLoginRequired))")
            return try JSONDecoder().decode(PlayerResponse.self, from: Data(Self.simulatedBotCheck.utf8))
        }
        var req = Innertube.PlayerRequest(videoId: videoId, client: client)
        req.signatureTimestamp = sts
        if let poToken {
            req.visitorData = poToken.visitorData
        } else {
            req.visitorData = try? await scripts.appInfo().visitorData
        }
        req.poToken = poToken?.playerPoToken
        req.livingRoomPoTokenId = livingRoomPoTokenId
        req.reloadPlaybackToken = reloadToken
        req.extraHeaders = headers
        let reply = try await innertube.player(req)
        guard reply.status == 200 else { throw SabrError("player HTTP \(reply.status): \(String(decoding: reply.data.prefix(200), as: UTF8.self))") }
        return try JSONDecoder().decode(PlayerResponse.self, from: reply.data)
    }

    /// Cabeceras de la cuenta, solo si ya se sabe que hay sesión (no se espera al Llavero) y el cliente es de TV (la
    /// sesión es de la app de TV). Si el access token no se puede renovar, el player va anónimo.
    func accountHeaders() async -> [String: String] {
        guard let account, account.knownSignedIn == true, client.id.hasPrefix("TV") else { return [:] }
        return (try? await account.authorizationHeaders()) ?? [:]
    }

    private var simulatedLoginRequired = 0
    static let simulatedBotCheck = #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Prueba: inicia sesión para confirmar que no eres un bot"}}"#

    static func playability(_ response: PlayerResponse) -> String {
        "\(response.playabilityStatus?.status ?? "?")" + (response.playabilityStatus?.reason.map { " (\($0))" } ?? "")
    }

    /// PoToken web (WEB/MWEB/…) o de TV (tv_config), según el cliente.
    private func mintPoToken() async throws {
        guard let poTokenSource else { return }
        if client.poToken == .web {
            let result = try await poTokenSource.poToken(videoId: videoId)
            poToken = result
            poTokenKind = .web
            Log.info(String(format: "PoToken web generado en %.1f s (sesión %d car., contenido %d car.)",
                            result.elapsed, result.streamingPoToken.count, result.playerPoToken.count))
        } else if client.poToken == .tv, let tvSource = poTokenSource as? TVPoTokenSource {
            let (result, id) = try await tvSource.tvPoToken(tv: client)
            poToken = result
            poTokenKind = .tv
            livingRoomPoTokenId = id
            Log.info(String(format: "PoToken de TV generado en %.1f s (%d car., livingRoomPoTokenId %@)",
                            result.elapsed, result.playerPoToken.count, id))
        } else {
            return
        }
        if stickyFault == .forbiddenUntilPoToken {
            stickyFault = nil
            event("prueba 403pot: hay PoToken nuevo; el player siguiente trae la URL bien")
        }
        let now = Date()
        poTokenObtainedAt = now
        // expiresAt ya lleva 10 min de margen (como SmartTube): la caducidad real es 10 min después.
        poTokenExpiresAt = options.poTokenLifetime.map { now.addingTimeInterval($0) } ?? poToken?.expiresAt.addingTimeInterval(600)
    }

    // MARK: - Una petición

    private enum Outcome { case media(Int), redirect, reload(String?) }

    private struct ResponseState {
        var newSegments = 0
        var redirect = false
        var reloadToken: String??
    }

    /// Una petición SABR. La respuesta se lee en flujo: cada parte UMP se procesa en cuanto llega completa, así
    /// que los bytes de `MEDIA` llegan al sink sin esperar al resto de la respuesta.
    private func request() async throws -> Outcome {
        var components = URLComponents(string: url)!
        components.set("rn", String(requestNumber))
        var log = SabrRequestLog(rn: requestNumber, playerTimeMs: playerTimeMs)
        log.host = components.host
        requestNumber += 1

        let body = buildRequest()
        let headers = [
            "Content-Type": "application/x-protobuf",
            "Accept": "application/vnd.yt-ump",
            "Accept-Encoding": "identity",
            "User-Agent": client.userAgent,
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/",
        ]
        let start = Date()
        partial = [:]
        let response = try await transport.post(components.url!, headers: headers, body: body, timeout: options.requestTimeout)
        log.status = response.status
        guard response.status == 200 else {
            let text = await response.text(limit: 300)
            finish(&log, start: start)
            throw SabrHTTPError(status: response.status, host: components.host, body: text)
        }

        var decoder = UMPDecoder()
        var state = ResponseState()
        var raw = options.dumpDirectory == nil ? nil : Data()
        do {
            for try await chunk in response.body {
                log.bytes += chunk.count
                raw?.append(chunk)
                for part in decoder.feed(chunk) { try handle(part, state: &state, log: &log) }
            }
            try Task.checkCancellation()
        } catch {
            interrupted()
            if error is CancellationError { throw error }
            log.newSegments = state.newSegments
            log.notes.append("respuesta cortada: \(error)")
            finish(&log, start: start)
            throw error
        }
        if decoder.pendingBytes > 0 { log.notes.append("\(decoder.pendingBytes) B sobrantes al final del UMP") }
        if !partial.isEmpty {
            log.notes.append("\(partial.count) segmentos sin MEDIA_END")
            interrupted()
        }
        if let dir = options.dumpDirectory, let raw {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? body.write(to: dir.appendingPathComponent("rn\(log.rn).request.bin"))
            try? raw.write(to: dir.appendingPathComponent("rn\(log.rn).response.ump"))
        }
        log.newSegments = state.newSegments
        finish(&log, start: start)
        if let reloadToken = state.reloadToken { return .reload(reloadToken) }
        if state.redirect, state.newSegments == 0 { return .redirect }
        return .media(state.newSegments)
    }

    private func finish(_ log: inout SabrRequestLog, start: Date) {
        log.elapsed = Date().timeIntervalSince(start)
        for track in activeTracks where !track.contiguous.isEmpty {
            if let kind = track.kind { log.buffered[kind] = track.bufferedStartMs..<track.bufferedEndMs }
        }
        requests.append(log)
        if options.logRequests { Log.info(Self.describe(log, tracks: activeTracks)) }
        onRequest?(log)
    }

    /// `VideoPlaybackAbrRequest` (video_playback_abr_request.proto), con los valores de
    /// `SabrManifest.createVideoPlaybackAbrRequest` pero pidiendo audio y video juntos.
    func buildRequest() -> Data {
        var w = ProtoWriter()
        let videoFormat = video?.format
        w.message(1) { s in // ClientAbrState
            s.int(16, videoFormat?.height)          // last_manual_selected_resolution
            s.int(21, videoFormat?.height)          // sticky_resolution
            s.bool(22, false)                       // client_viewport_is_flexible
            s.int(23, Int64(max(videoFormat?.bitrate ?? 0, 1_000_000) * 4)) // bandwidth_estimate
            s.int(28, playerTimeMs)                 // player_time_ms
            s.float(35, 1)                          // playback_rate
            s.int(40, 0)                            // enabled_track_types_bitfield: audio + video
            s.bool(46, false)                       // drc_enabled
            s.int(68, 0)                            // sabr_force_max_network_interruption_duration_ms
            s.string(69, audio?.format?.audioTrackId) // audio_track_id
        }
        let initialized = tracks.values.filter(\.initialized).sorted { $0.id.itag < $1.id.itag }
        for track in initialized { w.message(2) { track.id.encode(&$0) } } // selected_format_ids
        for track in initialized { // buffered_ranges
            if track.discard {
                w.message(3) { Self.encodeRange(&$0, id: track.id, startMs: 0, durationMs: Int64(Int32.max),
                                                startSegment: Int64(Int32.max), endSegment: Int64(Int32.max)) }
            } else if let first = track.contiguous.first, let last = track.contiguous.last {
                w.message(3) { Self.encodeRange(&$0, id: track.id, startMs: first.startMs, durationMs: track.bufferedMs,
                                                startSegment: Int64(first.sequence), endSegment: Int64(last.sequence)) }
            }
        }
        w.bytes(5, ustreamerConfig)                 // video_playback_ustreamer_config
        if let audio { w.message(16) { audio.id.encode(&$0) } } // preferred_audio_format_ids
        if let video { w.message(17) { video.id.encode(&$0) } } // preferred_video_format_ids
        w.message(19) { ctx in                      // streamer_context
            ctx.message(1) { info in                // client_info
                info.int(16, Int(client.clientNameId))
                info.string(17, client.clientVersion)
                let os = client.osName.map { ($0, client.osVersion) } ?? Self.osFromUserAgent(client.userAgent)
                info.string(18, os?.0)
                info.string(19, os?.1)
                info.string(12, client.deviceMake)
                info.string(13, client.deviceModel)
            }
            ctx.bytes(2, streamPoToken)
            ctx.bytes(3, playbackCookie)
            for (type, value) in contexts.sorted(by: { $0.key < $1.key }) where contextsToSend.contains(type) {
                ctx.message(5) { c in
                    c.int(1, type)
                    c.bytes(2, value)
                }
            }
            for type in contextsToSend.sorted() where contexts[type] == nil { ctx.int(6, type) }
        }
        return w.data
    }

    /// El cliente web real manda osName/osVersion del navegador (p. ej. "Windows"/"10.0"); clients.json no los tiene.
    static func osFromUserAgent(_ ua: String) -> (String, String?)? {
        if let version = ua.firstMatch(#"Windows NT ([\d.]+)"#) { return ("Windows", version) }
        if let version = ua.firstMatch(#"Mac OS X ([\d_]+)"#) { return ("Macintosh", version) }
        return nil
    }

    static func encodeRange(_ w: inout ProtoWriter, id: SabrFormatID, startMs: Int64, durationMs: Int64, startSegment: Int64, endSegment: Int64) {
        w.message(1) { id.encode(&$0) }
        w.int(2, startMs)
        w.int(3, durationMs)
        w.int(4, startSegment)
        w.int(5, endSegment)
        w.message(6) { tr in // TimeRange en milisegundos
            tr.int(1, startMs)
            tr.int(2, durationMs)
            tr.int(3, 1000)
        }
    }

    // MARK: - Partes UMP (SabrStream.parsePart + SabrProcessor)

    private func handle(_ part: UMPPart, state: inout ResponseState, log: inout SabrRequestLog) throws {
        log.parts[UMPPartID.name(part.type), default: 0] += 1
        switch UMPPartID(rawValue: part.type) {
        case .formatInitializationMetadata:
            let f = try ProtoFields(part.payload)
            guard let idFields = try f.message(2) else { return }
            let id = SabrFormatID(idFields)
            let track: SabrTrack
            if retired[id.itag] != nil {
                log.notes.append("formato \(id) dejado al cambiar de calidad: se ignora")
                return
            } else if let known = tracks[id.itag] {
                track = known
                track.id = id // el servidor manda su FormatId (con lmt/xtags) y es el que se devuelve
            } else {
                track = SabrTrack(format: nil, id: id, discard: true)
                tracks[id.itag] = track
                log.notes.append("formato \(id) no pedido: se marca como descartado")
            }
            track.initialized = true
            track.mimeType = f.string(5)
            track.endSegmentNumber = f.int(4)
            track.endTimeMs = f.int(3)

        case .mediaHeader:
            let f = try ProtoFields(part.payload)
            let headerId = f.uint(1) ?? 0
            let formatId = try f.message(13)
            let itag = Int(f.int(3) ?? formatId?.int(1) ?? -1)
            if let compression = f.int(7), compression != 0 { throw SabrError("MediaHeader comprimido (\(compression)), no soportado") }
            let timeRange = try f.message(15)
            let timescale = timeRange?.int(3) ?? 0
            let startMs = f.int(11) ?? timeRange.flatMap { tr in tr.int(1).map { timescale > 0 ? $0 * 1000 / timescale : 0 } } ?? 0
            let durationMs = f.int(12) ?? timeRange.flatMap { tr in tr.int(2).map { timescale > 0 ? $0 * 1000 / timescale : 0 } } ?? 0
            let isInit = f.bool(8) ?? false
            let sequence = Int(f.int(9) ?? -1)
            partial[headerId] = PartialSegment(itag: itag, isInit: isInit, sequence: sequence, startMs: startMs, durationMs: durationMs,
                                               mode: mode(itag: itag, isInit: isInit, sequence: sequence))

        case .media:
            guard let (headerId, offset) = UMPDecoder.readVarint(part.payload, at: part.payload.startIndex),
                  let segment = partial[headerId] else { throw SabrError("MEDIA de un header desconocido") }
            receive(segment, part.payload[offset...])

        case .mediaEnd:
            guard let (headerId, _) = UMPDecoder.readVarint(part.payload, at: part.payload.startIndex),
                  let segment = partial.removeValue(forKey: headerId) else { throw SabrError("MEDIA_END de un header desconocido") }
            if complete(segment) { state.newSegments += 1 }

        case .nextRequestPolicy:
            let f = try ProtoFields(part.payload)
            backoffMs = f.int(4) ?? 0
            if backoffMs > 0 { log.backoffMs = backoffMs }
            playbackCookie = f.bytes(7)
            if requests.isEmpty {
                readahead = (f.int(1), f.int(2), f.int(5), f.int(6))
                log.notes.append("NextRequestPolicy: readahead objetivo audio \(f.int(1).map(String.init) ?? "-") ms / video \(f.int(2).map(String.init) ?? "-") ms, mínimo \(f.int(5).map(String.init) ?? "-") / \(f.int(6).map(String.init) ?? "-") ms")
            }

        case .sabrRedirect:
            if let newURL = try ProtoFields(part.payload).string(1) {
                url = newURL
                cdn = SabrCDNSelector(url: newURL)
                state.redirect = true
                log.notes.append("SABR_REDIRECT → \(URLComponents(string: newURL)?.host ?? "?")")
            }

        case .sabrError:
            let f = try ProtoFields(part.payload)
            throw SabrServerError(description: "SABR_ERROR: tipo \(f.string(1) ?? "?"), acción \(f.int(2).map(String.init) ?? "-"), \(try f.message(3)?.description ?? "")")

        case .reloadPlayerResponse:
            let token = try ProtoFields(part.payload).message(1)?.string(1)
            state.reloadToken = .some(token)

        case .streamProtectionStatus:
            let status = try ProtoFields(part.payload).int(1)
            log.protection = status
            lastProtection = status

        case .sabrContextUpdate:
            let f = try ProtoFields(part.payload)
            guard let type = f.int(1).map(Int.init), let value = f.bytes(3) else { return }
            if f.int(5) == 2, contexts[type] != nil { return } // KEEP_EXISTING
            contexts[type] = value
            if f.bool(4) == true { contextsToSend.insert(type) }
            log.notes.append("SABR_CONTEXT_UPDATE tipo \(type) (\(value.count) B)")

        case .sabrContextSendingPolicy:
            let f = try ProtoFields(part.payload)
            for type in f.repeatedInts(1) { contextsToSend.insert(Int(type)) }
            for type in f.repeatedInts(2) { contextsToSend.remove(Int(type)) }
            for type in f.repeatedInts(3) { contexts.removeValue(forKey: Int(type)) }

        case .sabrSeek:
            let f = try ProtoFields(part.payload)
            if let time = f.int(1), let scale = f.int(2), scale > 0 {
                playerTimeMs = time * 1000 / scale
                log.notes.append("SABR_SEEK a \(playerTimeMs) ms")
            }

        case .snackbarMessage:
            let text = (try? ProtoFields(part.payload).description) ?? "?"
            snackbars.append(text)
            log.notes.append("SNACKBAR \(text.prefix(120))")

        default:
            break
        }
    }

    /// Qué hacer con un segmento según lo que ya tiene su pista (ver `PartialSegment`).
    private func mode(itag: Int, isInit: Bool, sequence: Int) -> PartialSegment.Mode {
        guard let track = tracks[itag], !track.discard else { return .drop }
        if isInit { return track.initSegment == nil ? .hold : .drop }
        if track.segments[sequence] != nil { return .drop }
        if partial.values.contains(where: { $0.itag == itag && $0.sequence == sequence && !$0.isInit }) { return .drop }
        guard sink != nil else { return .hold }
        if let next = track.nextDelivery, sequence < next { return .drop } // ya entregado antes en esta sesión
        guard track.initDelivered, track.nextDelivery == nil || track.nextDelivery == sequence else { return .hold }
        track.nextDelivery = sequence
        let skip = track.resume.map { $0.sequence == sequence ? $0.bytes : 0 } ?? 0
        return .live(skip: skip)
    }

    /// Trozo de `MEDIA`: si el segmento es el siguiente de su pista se entrega ya; si no, se junta.
    private func receive(_ segment: PartialSegment, _ bytes: Data) {
        let before = segment.received
        segment.received += bytes.count
        switch segment.mode {
        case .live(let skip):
            if options.retainSegments { segment.data.append(bytes) }
            let already = max(0, min(bytes.count, skip - before))
            guard already < bytes.count, let sink, let track = tracks[segment.itag], let kind = track.kind else { return }
            let fresh = Data(bytes.dropFirst(already))
            sink.sabrAppend(fresh, to: kind)
            track.noteDelivered(fresh.count)
        case .hold:
            segment.data.append(bytes)
        case .drop:
            break
        }
    }

    /// `MEDIA_END`: registra el segmento y entrega lo que ya toque. true si el segmento es nuevo.
    private func complete(_ segment: PartialSegment) -> Bool {
        guard let track = tracks[segment.itag], !track.discard else { return false }
        if segment.isInit {
            if case .hold = segment.mode, track.initSegment == nil { track.initSegment = segment.data }
            deliverPending(track)
            return false
        }
        if case .drop = segment.mode { return false }
        let data = options.retainSegments ? segment.data : Data()
        guard track.add(.init(sequence: segment.sequence, startMs: segment.startMs, durationMs: segment.durationMs, data: data)) else { return false }
        switch segment.mode {
        case .live:
            track.nextDelivery = segment.sequence + 1
            track.resume = nil
        case .hold:
            if sink != nil { track.held[segment.sequence] = segment.data }
        case .drop:
            break
        }
        deliverPending(track)
        return true
    }

    /// Entrega al sink el segmento de inicio (una vez por sesión de streaming) y los segmentos guardados que ya
    /// tocan; al pasar el último, cierra la pista.
    private func deliverPending(_ track: SabrTrack) {
        guard let sink, let kind = track.kind else { return }
        if !track.initDelivered {
            guard let initSegment = track.initSegment else { return }
            sink.sabrAppend(SabrTrack.streamableInit(initSegment), to: kind)
            track.initDelivered = true
        }
        if track.nextDelivery == nil { track.nextDelivery = track.held.keys.min() }
        while let next = track.nextDelivery, let data = track.held.removeValue(forKey: next) {
            sink.sabrAppend(data, to: kind)
            track.noteDelivered(data.count)
            track.nextDelivery = next + 1
        }
        if !track.finished, track.isComplete, let next = track.nextDelivery, let end = track.endSegmentNumber, Int64(next) > end {
            track.finished = true
            sink.sabrFinish(kind)
        }
    }

    /// La respuesta se cortó: lo entregado de cada segmento `live` se recuerda para no repetirlo cuando vuelva.
    private func interrupted() {
        for segment in partial.values {
            guard case .live(let skip) = segment.mode, let track = tracks[segment.itag] else { continue }
            track.resume = (segment.sequence, max(skip, segment.received))
        }
        partial = [:]
    }

    // MARK: - Registro

    public static func protectionName(_ status: Int64) -> String {
        switch status {
        case 1: return "OK"
        case 2: return "ATTESTATION_PENDING"
        case 3: return "ATTESTATION_REQUIRED"
        default: return "\(status)"
        }
    }

    static func describe(_ log: SabrRequestLog, tracks: [SabrTrack]) -> String {
        let parts = log.parts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        var s = String(format: "  rn=%d t=%.1fs → HTTP %d, %.0f KB en %.2f s · %d segmentos nuevos", log.rn, Double(log.playerTimeMs) / 1000,
                       log.status, Double(log.bytes) / 1024, log.elapsed, log.newSegments)
        if let protection = log.protection { s += " · protección \(protectionName(protection))" }
        if let backoff = log.backoffMs { s += " · backoff \(backoff) ms" }
        s += "\n      partes: \(parts)"
        s += "\n      búfer: " + tracks.map { t in
            String(format: "%d %@ %.1f s (%d seg.)", t.id.itag, t.format?.kind.rawValue ?? "?", Double(t.bufferedMs) / 1000, t.contiguous.count)
        }.joined(separator: " · ")
        for note in log.notes { s += "\n      \(note)" }
        return s
    }
}
