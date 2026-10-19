import Foundation
import PlaybackKit
import YTKit

// Fuente SABR para `MPVEngine`: envuelve `SabrSession` de YTKit detrás de `StreamedMediaSource`. La sesión usa el
// cliente TV con su PoToken (WKWebView), que es lo que en la fase 0 dio `StreamProtectionStatus OK` sin el tope de
// 60 s. Todo lo de YouTube (player, `n`, PoToken, SABR/UMP) es de YTKit; aquí solo están el adaptador y las opciones.
// La app le pasa el mismo `ClientCatalog` y el mismo `PoTokenWebViewProvider` que usa su `YouTubeService`, para que
// catálogo y reproductor compartan un solo WKWebView de BotGuard.

public struct SabrSourceOptions: Sendable {
    /// Altura máxima del video de arranque (la calidad se puede cambiar después con `select(track:)`).
    public var maxHeight: Int? = 1080
    /// Preferencia de códecs de video ("vp9", "avc", "av1"). VP9 primero: en el M1 Pro, VP9 y H.264 se decodifican por
    /// hardware y AV1 no.
    public var videoCodecs = ["vp9", "avc", "av1"]
    /// Segundos por delante del reproductor que se piden (el servidor anuncia ~15).
    public var readahead: Double = 15
    /// Segundos sin datos tras los que una petición falla y se prueba otra CDN (mpv tiene ~15 s por delante).
    public var requestTimeout: Double = 8
    public var usePoToken = true
    /// Pruebas: vida de la URL y del PoToken en segundos desde que se obtienen, en lugar de 6 h y 12 h.
    public var urlLifetime: Double?
    public var poTokenLifetime: Double?
    /// Anota cada petición SABR (número, posición, HTTP, MB, tiempo, búfer) como nota del motor.
    public var logRequests = false
    /// Pruebas: las primeras N respuestas del player son un LOGIN_REQUIRED (el «confirma que no eres un bot»).
    public var simulatedLoginRequired = 0

    public init() {}
}

public final class SabrMediaSource: StreamedMediaSource, @unchecked Sendable {
    public let identifier: String
    public let options: SabrSourceOptions
    private let session: SabrSession
    private let provider: PoTokenWebViewProvider?
    /// El proveedor lo creó esta fuente (y lo cierra al soltarse); uno compartido lo cierra quien lo creó.
    private let ownsProvider: Bool
    private let lock = NSLock()
    private var note: (@Sendable (String) -> Void)?

    /// `catalog` y `poTokenProvider` son los de la app (los mismos de su `YouTubeService`); sin ellos, la fuente carga
    /// `clients.json` y crea su propio proveedor de PoToken. Con `account` (la sesión de la app), el player se pide con
    /// la cuenta cuando hay una iniciada, como SmartTube: sin cuenta, YouTube a veces responde LOGIN_REQUIRED
    /// («Inicia sesión para confirmar que no eres un bot»).
    @MainActor
    public init(videoId: String, options: SabrSourceOptions = SabrSourceOptions(), catalog: ClientCatalog? = nil,
                poTokenProvider: PoTokenWebViewProvider? = nil, account: AccountManager? = nil) throws {
        identifier = videoId
        self.options = options
        let catalog = try catalog ?? ClientCatalog.load()
        guard let client = catalog.profile("TV") else { throw SabrError("clients.json no trae el cliente TV") }
        var sabr = SabrOptions()
        sabr.retainSegments = false
        sabr.logRequests = false
        sabr.maxHeight = options.maxHeight
        sabr.codecOrder = options.videoCodecs.compactMap(Codec.init(rawValue:))
        sabr.readaheadMs = Int64(options.readahead * 1000)
        sabr.requestTimeout = options.requestTimeout
        sabr.usePoToken = options.usePoToken
        sabr.urlLifetime = options.urlLifetime
        sabr.poTokenLifetime = options.poTokenLifetime
        sabr.simulatedLoginRequired = options.simulatedLoginRequired
        if client.poToken != nil && options.usePoToken {
            provider = poTokenProvider ?? PoTokenWebViewProvider(catalog: catalog)
            ownsProvider = poTokenProvider == nil
        } else {
            provider = nil
            ownsProvider = false
        }
        session = SabrSession(videoId: videoId, client: client, options: sabr, poTokenSource: provider)
        session.account = account
        session.onEvent = { [weak self] message in self?.emit(message) }
        if options.logRequests {
            session.onRequest = { [weak self] log in self?.emit(Self.describe(log)) }
        }
    }

    static func describe(_ log: SabrRequestLog) -> String {
        let ranges = [StreamFormat.Kind.video, .audio].compactMap { kind in
            log.buffered[kind].map { String(format: "%@ %.1f–%.1f", kind == .video ? "v" : "a", Double($0.lowerBound) / 1000, Double($0.upperBound) / 1000) }
        }.joined(separator: " ")
        var line = String(format: "SABR rn=%d t=%.1f s → HTTP %d, %.2f MB en %.2f s · +%d seg · búfer %@", log.rn, Double(log.playerTimeMs) / 1000,
                          log.status, Double(log.bytes) / 1_048_576, log.elapsed, log.newSegments, ranges)
        if let protection = log.protection { line += " · \(SabrSession.protectionName(protection))" }
        if let backoff = log.backoffMs { line += " · backoff \(backoff) ms" }
        if let host = log.host { line += " · @\(host)" }
        return line
    }

    deinit {
        if ownsProvider, let provider { Task { @MainActor in provider.close() } }
    }

    public var onNote: (@Sendable (String) -> Void)? {
        get { lock.withLock { note } }
        set { lock.withLock { note = newValue } }
    }

    private func emit(_ message: String) {
        onNote?(message)
    }

    public var title: String? { session.title }
    public var duration: Double? { session.durationMs.map { Double($0) / 1000 } }

    public var videoTracks: [MediaTrack] {
        let current = session.video?.format
        let order = options.videoCodecs.compactMap(Codec.init(rawValue:))
        let isHDR = current?.isHDR ?? false
        return session.formats
            .filter { $0.kind == .video && order.contains($0.codec) && $0.isHDR == isHDR }
            .sorted { a, b in
                if (a.height ?? 0) != (b.height ?? 0) { return (a.height ?? 0) > (b.height ?? 0) }
                if (a.fps ?? 0) != (b.fps ?? 0) { return (a.fps ?? 0) > (b.fps ?? 0) }
                return (order.firstIndex(of: a.codec) ?? 9) < (order.firstIndex(of: b.codec) ?? 9)
            }
            .map { Self.track($0, selected: $0.itag == current?.itag) }
    }

    public var audioTracks: [MediaTrack] {
        let current = session.audio?.format
        return session.formats
            .filter { $0.kind == .audio && !$0.isDRC }
            .sorted { $0.bitrate > $1.bitrate }
            .map { Self.track($0, selected: $0.itag == current?.itag) }
    }

    static func track(_ f: StreamFormat, selected: Bool) -> MediaTrack {
        switch f.kind {
        case .audio:
            let channels = f.audioChannels.map { $0 > 2 ? " \($0)ch" : "" } ?? ""
            return MediaTrack(id: "itag:\(f.itag)", kind: .audio, title: "\(f.codec.rawValue) \(f.bitrate / 1000)k\(channels)" + (f.audioTrack.map { " · \($0)" } ?? ""),
                              language: f.audioTrackId, codec: f.codec.rawValue, bitrate: f.bitrate, isSelected: selected)
        case .video, .muxed:
            let title = "\(f.height ?? 0)p\(f.fps.map { $0 > 30 ? "\($0)" : "" } ?? "")\(f.isHDR ? " HDR" : "") · \(f.codec.rawValue)"
            return MediaTrack(id: "itag:\(f.itag)", kind: .video, title: title, codec: f.codec.rawValue, width: f.width, height: f.height,
                              fps: f.fps.map(Double.init), bitrate: f.bitrate, isHDR: f.isHDR, isSelected: selected)
        }
    }

    public func prepare() async throws {
        try await session.prepare()
        emit("SABR \(identifier): video \(session.video?.format.map { "\($0.itag) \($0.codec.rawValue) \($0.label)" } ?? "-") · audio "
             + "\(session.audio?.format.map { "\($0.itag) \($0.codec.rawValue) \($0.label)" } ?? "-") · PoToken "
             + (session.poTokenKind.map { $0 == .tv ? "de TV" : "web" } ?? "no")
             + (session.playerSignedIn ? " · player con la cuenta" : " · player anónimo")
             + (session.playerAttempts > 1 ? " · 2.º intento (\(session.playerRecoveries.joined(separator: ", ")))" : ""))
    }

    /// Por qué YouTube no dio el video (LOGIN_REQUIRED, UNPLAYABLE…), si la carga falló por eso.
    public var unplayable: SabrUnplayableError? { session.lastUnplayable }

    public func selectTrack(id: String) throws {
        guard id.hasPrefix("itag:"), let itag = Int(id.dropFirst(5)), let format = session.formats.first(where: { $0.itag == itag }) else {
            throw SabrError("pista desconocida: \(id)")
        }
        session.switchFormat(to: format)
    }

    public func stream(from position: Double, into sink: MediaStreamSink, clock: PlaybackClock) async throws {
        try await session.stream(from: Int64(position * 1000), to: SinkAdapter(sink), clock: ClockAdapter(clock))
    }

    /// Pruebas: provoca un fallo real antes de la próxima petición ("403", "403+", "403pot", "cdn", "net", "stall").
    public func injectFault(_ name: String) -> Bool {
        guard let fault = SabrFault(rawValue: name) else { return false }
        session.inject(fault)
        return true
    }

    /// Resumen de la vida de la sesión (renovaciones, CDN, recuperaciones).
    public var lifeSummary: String {
        "URL renovada \(session.urlRenewals) veces, PoToken renovado \(session.poTokenRenewals), cambios de CDN \(session.cdnSwitches), "
            + "player pedido tras errores \(session.errorReloads), recuperaciones \(session.recoveries), recargas del servidor \(session.reloads)"
            + " · URL caduca \(SabrSession.relative(session.urlExpiresAt))"
            + (session.poToken != nil ? ", PoToken caduca \(SabrSession.relative(session.poTokenExpiresAt))" : "")
    }

    /// El reloj del motor visto como el de la sesión.
    private final class ClockAdapter: SabrClock, @unchecked Sendable {
        let clock: PlaybackClock
        init(_ clock: PlaybackClock) { self.clock = clock }
        var positionMs: Int64? { clock.positionMs }
    }

    private final class SinkAdapter: SabrSink {
        let sink: MediaStreamSink
        init(_ sink: MediaStreamSink) { self.sink = sink }

        func sabrAppend(_ data: Data, to kind: StreamFormat.Kind) {
            switch kind {
            case .video: sink.append(data, to: .video)
            case .audio: sink.append(data, to: .audio)
            case .muxed: break
            }
        }

        func sabrFinish(_ kind: StreamFormat.Kind) {
            switch kind {
            case .video: sink.finish(.video)
            case .audio: sink.finish(.audio)
            case .muxed: break
            }
        }
    }
}

/// Directos: el manifiesto HLS que da el cliente VISIONOS (sin desafíos), para `AVEngine`.
public enum YouTubeLive {
    public struct Info: Sendable {
        public let hlsURL: URL
        public let title: String?
        public let isLive: Bool
    }

    public static func hlsManifest(videoId: String, catalog: ClientCatalog? = nil) async throws -> Info {
        let catalog = try catalog ?? ClientCatalog.load()
        guard let client = catalog.profile("VISIONOS") else { throw SabrError("clients.json no trae VISIONOS") }
        var request = Innertube.PlayerRequest(videoId: videoId, client: client)
        request.visitorData = try? await PlayerScriptStore.shared.appInfo().visitorData
        let reply = try await Innertube().player(request)
        guard reply.status == 200 else { throw SabrError("player HTTP \(reply.status)") }
        let response = try JSONDecoder().decode(PlayerResponse.self, from: reply.data)
        guard response.playabilityStatus?.status == "OK" else {
            throw SabrError("player: \(response.playabilityStatus?.status ?? "?") \(response.playabilityStatus?.reason ?? "")")
        }
        guard let manifest = response.streamingData?.hlsManifestUrl, let url = URL(string: manifest) else {
            throw SabrError("VISIONOS no trajo manifiesto HLS (¿es un directo?)")
        }
        return Info(hlsURL: url, title: response.videoDetails?.title, isLive: response.videoDetails?.isLive ?? false)
    }
}
