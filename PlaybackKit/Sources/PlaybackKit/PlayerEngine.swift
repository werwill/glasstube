import AppKit
import Foundation
import Observation

// Contrato del motor de reproducción. SmartTube envuelve ExoPlayer y monta encima sus controladores
// (SponsorBlock, VideoState, Suggestions…); aquí esos controladores viven sobre `PlayerEngine` y no saben si debajo
// hay libmpv (`MPVEngine`, videos normales, también por SABR) o AVPlayer (`AVEngine`, directos HLS).
//
// Reglas para quien construya encima:
// - Toda la API va en el actor principal. Las llamadas que esperan a la red o a mpv son `async`.
// - El estado actual está en `status` (Observable, para SwiftUI). Los cambios llegan además como `PlayerEvent` por
//   `events()`, un flujo nuevo por suscriptor (cada controlador tiene el suyo).
// - Los tiempos van en segundos de la línea de tiempo del video (no del archivo ni de la carga).

public enum PlayerEngineKind: String, Sendable {
    case mpv
    case avPlayer
}

public enum PlaybackState: Equatable, Sendable, CustomStringConvertible {
    case idle
    case loading
    case playing
    case paused
    /// Esperando datos (sin ellos no avanza aunque no esté en pausa).
    case buffering
    case ended
    case failed(PlayerError)

    public var description: String {
        switch self {
        case .idle: return "inactivo"
        case .loading: return "cargando"
        case .playing: return "reproduciendo"
        case .paused: return "en pausa"
        case .buffering: return "esperando datos"
        case .ended: return "terminado"
        case .failed(let error): return "error: \(error.message)"
        }
    }
}

public struct PlayerError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// false si la reproducción ya no puede seguir (hay que volver a cargar el video).
    public var recoverable: Bool

    public init(_ message: String, recoverable: Bool = false) {
        self.message = message
        self.recoverable = recoverable
    }

    public var description: String { message }
}

public enum MediaTrackKind: String, Sendable {
    case video, audio, subtitle
}

/// Una pista elegible: una calidad de video, un idioma de audio o unos subtítulos.
public struct MediaTrack: Identifiable, Hashable, Sendable, CustomStringConvertible {
    /// Estable mientras dure la carga; lo usa `select(track:)`.
    public var id: String
    public var kind: MediaTrackKind
    public var title: String
    public var language: String?
    public var codec: String?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var bitrate: Int?
    public var isHDR: Bool
    public var isSelected: Bool
    /// Subtítulos añadidos con `addSubtitle(url:…)` (en SmartTube, los de YouTube van aparte del video).
    public var isExternal: Bool

    public init(id: String, kind: MediaTrackKind, title: String, language: String? = nil, codec: String? = nil,
                width: Int? = nil, height: Int? = nil, fps: Double? = nil, bitrate: Int? = nil, isHDR: Bool = false,
                isSelected: Bool = false, isExternal: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.language = language
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.isHDR = isHDR
        self.isSelected = isSelected
        self.isExternal = isExternal
    }

    public var description: String { "\(kind.rawValue) \(id) \(title)\(isSelected ? " ✓" : "")" }
}

public struct BufferStatus: Equatable, Sendable {
    /// Segundos listos por delante de la posición.
    public var ahead: Double?
    /// Tramos donde se puede buscar sin volver a descargar.
    public var seekableRanges: [ClosedRange<Double>]
    /// Detenido esperando datos.
    public var isStalled: Bool

    public init(ahead: Double? = nil, seekableRanges: [ClosedRange<Double>] = [], isStalled: Bool = false) {
        self.ahead = ahead
        self.seekableRanges = seekableRanges
        self.isStalled = isStalled
    }
}

public enum SeekMode: Sendable {
    /// Al cuadro exacto (lo normal: SponsorBlock, posición guardada, flechas).
    case exact
    /// Al cuadro clave más cercano: más rápido, para arrastrar la barra.
    case keyframe
}

public enum PlayerEvent: Sendable {
    case state(PlaybackState)
    /// Unas 4 veces por segundo mientras avanza, y tras cada búsqueda.
    case time(position: Double, duration: Double?)
    case buffer(BufferStatus)
    case tracks([MediaTrack])
    /// La búsqueda terminó y la imagen ya está en `position`.
    case seekCompleted(position: Double)
    case error(PlayerError)
    /// Hechos para diagnóstico: renovaciones, cambios de CDN, recargas…
    case note(String)
}

/// Qué reproducir.
public enum MediaSource: Sendable {
    /// URLs que el motor abre por sí mismo: un archivo, un HLS o video y audio por separado (DASH con URL directa).
    case url(URL, audio: URL? = nil, headers: [String: String] = [:])
    /// Bytes que entrega una fuente propia (SABR) por flujos `glasstube://` (`mpv_stream_cb`). Solo `MPVEngine`.
    case streamed(any StreamedMediaSource)
}

public struct PlaybackItem: Sendable {
    public var id: String
    public var title: String?
    public var source: MediaSource
    /// Posición de arranque (p. ej. la guardada por VideoState).
    public var startPosition: Double
    public var isLive: Bool

    public init(id: String, title: String? = nil, source: MediaSource, startPosition: Double = 0, isLive: Bool = false) {
        self.id = id
        self.title = title
        self.source = source
        self.startPosition = startPosition
        self.isLive = isLive
    }
}

/// Estado actual del motor, para SwiftUI. Lo escribe el motor en el actor principal.
@MainActor
@Observable
public final class PlayerStatus {
    public internal(set) var state: PlaybackState = .idle
    public internal(set) var position: Double = 0
    public internal(set) var duration: Double?
    public internal(set) var rate: Double = 1
    /// 0…1.
    public internal(set) var volume: Double = 1
    public internal(set) var isMuted = false
    public internal(set) var buffer = BufferStatus()
    public internal(set) var videoTracks: [MediaTrack] = []
    public internal(set) var audioTracks: [MediaTrack] = []
    public internal(set) var subtitleTracks: [MediaTrack] = []
    /// Lo que se decodifica ahora, p. ej. "vp9 1920x1080 · videotoolbox".
    public internal(set) var videoDescription: String?
    /// Decodificador por hardware en uso ("videotoolbox") o nil si es por software.
    public internal(set) var hardwareDecoder: String?
    /// Cuadros descartados por la salida de video y por el decodificador desde que empezó el archivo.
    public internal(set) var droppedFrames: Int = 0
    public internal(set) var decoderDroppedFrames: Int = 0

    public init() {}

    public var selectedVideoTrack: MediaTrack? { videoTracks.first(where: \.isSelected) }
}

@MainActor
public protocol PlayerEngine: AnyObject {
    var kind: PlayerEngineKind { get }
    var status: PlayerStatus { get }
    /// Superficie de video. Es siempre la misma vista: se puede insertar antes de `load`.
    var videoView: NSView { get }

    /// Un flujo nuevo de eventos para cada suscriptor; termina con `shutdown()`.
    func events() -> AsyncStream<PlayerEvent>

    /// Carga y empieza a reproducir (en `item.startPosition`). Reemplaza lo que hubiera.
    func load(_ item: PlaybackItem) async throws
    func play()
    func pause()
    func togglePause()
    /// Busca y vuelve cuando la imagen ya está en la posición (o al fallar).
    func seek(to seconds: Double, mode: SeekMode) async
    func setRate(_ rate: Double)
    /// 0…1.
    func setVolume(_ volume: Double)
    func setMuted(_ muted: Bool)
    /// Elige una pista de `status.videoTracks`, `audioTracks` o `subtitleTracks`. En video es el cambio de calidad.
    func select(track: MediaTrack) async throws
    func disableSubtitles()
    /// Añade subtítulos externos (WebVTT/SRT por URL) y los activa.
    func addSubtitle(url: URL, language: String?, title: String?) async throws
    /// Detiene y suelta el video actual; el motor sigue listo para otro `load`.
    func stop() async
    /// Libera el motor; no se puede volver a usar.
    func shutdown() async
}

extension PlayerEngine {
    public func seek(by delta: Double) async {
        await seek(to: max(0, status.position + delta), mode: .exact)
    }
}

/// Reparte eventos a varios suscriptores (`AsyncStream` admite uno solo por flujo).
@MainActor
final class EventHub {
    private var continuations: [UUID: AsyncStream<PlayerEvent>.Continuation] = [:]

    func stream() -> AsyncStream<PlayerEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PlayerEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        continuations[id] = continuation
        return stream
    }

    func send(_ event: PlayerEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    func finish() {
        for continuation in continuations.values { continuation.finish() }
        continuations = [:]
    }
}
