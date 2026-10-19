import Foundation

// Fuente de datos propia del motor: bytes de video y audio que llegan por la red en el orden en que se reproducen
// (SABR/UMP hoy) y que `MPVEngine` entrega a mpv por dos flujos `glasstube://` (`mpv_stream_cb`). La fuente no sabe
// de mpv: escribe en un `MediaStreamSink` y lee la posición del reproductor en un `PlaybackClock`.
//
// Ciclo de una carga (lo que el motor llama «generación»): el motor crea un `StreamPair`, llama a
// `stream(from:into:clock:)` en una tarea y abre los dos flujos en mpv. Una búsqueda fuera de lo descargado o un
// cambio de calidad cancelan esa tarea y empiezan otra generación desde la nueva posición. Entre generaciones (con la
// tarea anterior ya terminada) el motor puede llamar a `selectTrack(id:)`.

public enum StreamKind: String, Sendable {
    case video, audio
}

/// Destino de los bytes de una generación: segmento de inicio y luego los segmentos en orden, por pista.
public protocol MediaStreamSink: AnyObject, Sendable {
    func append(_ data: Data, to kind: StreamKind)
    /// La pista llegó a su último segmento.
    func finish(_ kind: StreamKind)
}

public protocol StreamedMediaSource: AnyObject, Sendable {
    /// Para las URIs `glasstube://<identifier>/…` (p. ej. el videoId).
    var identifier: String { get }
    var title: String? { get }
    var duration: Double? { get }
    /// Calidades de video que se pueden pedir y pistas de audio; `isSelected` marca las actuales.
    var videoTracks: [MediaTrack] { get }
    var audioTracks: [MediaTrack] { get }
    /// Hechos de la fuente (renovaciones, cambios de CDN, recuperaciones) para el registro del motor. Se llama desde
    /// la tarea de streaming.
    var onNote: (@Sendable (String) -> Void)? { get set }

    /// Prepara la reproducción (player, URL, PoToken…) sin bajar medios todavía.
    func prepare() async throws
    /// Cambia la pista para la siguiente generación. Solo con la tarea de streaming detenida.
    func selectTrack(id: String) throws
    /// Entrega a `sink` los bytes de ambas pistas desde `position` (s), al ritmo de `clock`, hasta el final o hasta
    /// que se cancele la tarea. Lanza si se rinde (el motor deja que mpv agote lo que tiene y avisa del error).
    func stream(from position: Double, into sink: MediaStreamSink, clock: PlaybackClock) async throws
}

/// Posición del reproductor que la fuente lee para decidir cuánto pedir. La escribe el hilo de eventos de mpv.
public final class PlaybackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var position: Int64?

    public init() {}

    public var positionMs: Int64? {
        get { lock.withLock { position } }
        set { lock.withLock { position = newValue } }
    }
}

/// Búfer bloqueante de una pista para un flujo de solo lectura de mpv (`mpv_stream_cb`): la fuente escribe el
/// segmento de inicio y los segmentos en orden; `read` bloquea en una variable de condición hasta que hay bytes, la
/// pista termina (0 = fin de archivo) o se cancela (-1). `read` corre en el hilo del demuxer de mpv, nunca en el
/// actor principal; `cancel` puede llamarse desde cualquier hilo y despierta al lector.
/// (De `SabrStreamBuffer` de glasstube-spike.)
public final class StreamBuffer: @unchecked Sendable {
    public let kind: StreamKind
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var head = 0       // primer trozo sin leer
    private var offset = 0     // bytes ya leídos de chunks[head]
    private var finished = false
    private var cancelled = false
    private var written: Int64 = 0
    private var consumed: Int64 = 0

    public init(kind: StreamKind) {
        self.kind = kind
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled else { return }
        chunks.append(data)
        written += Int64(data.count)
        condition.broadcast()
    }

    public func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        chunks = []
        head = 0
        offset = 0
        condition.broadcast()
        condition.unlock()
    }

    /// Copia hasta `capacity` bytes. Devuelve los bytes copiados, 0 al final de la pista o -1 si se canceló.
    public func read(into buffer: UnsafeMutableRawPointer, capacity: Int) -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        while head == chunks.count && !finished && !cancelled { condition.wait() }
        if cancelled { return -1 }
        if head == chunks.count { return 0 }
        var copied = 0
        while copied < capacity, head < chunks.count {
            let chunk = chunks[head]
            let count = min(capacity - copied, chunk.count - offset)
            chunk.withUnsafeBytes { bytes in
                (buffer + copied).copyMemory(from: bytes.baseAddress! + offset, byteCount: count)
            }
            copied += count
            offset += count
            if offset == chunk.count {
                chunks[head] = Data() // suelta la memoria del trozo leído
                head += 1
                offset = 0
            }
        }
        if head > 64 && head * 2 > chunks.count { // compacta de vez en cuando
            chunks.removeFirst(head)
            head = 0
        }
        consumed += Int64(copied)
        return Int64(copied)
    }

    /// Bytes escritos por la fuente, leídos por mpv y pendientes.
    public var counters: (written: Int64, read: Int64, pending: Int64) {
        condition.lock()
        defer { condition.unlock() }
        return (written, consumed, written - consumed)
    }
}

/// Los dos búferes (video y audio) de una generación.
public final class StreamPair: MediaStreamSink, @unchecked Sendable {
    public let video = StreamBuffer(kind: .video)
    public let audio = StreamBuffer(kind: .audio)

    public init() {}

    public func buffer(_ kind: StreamKind) -> StreamBuffer {
        kind == .video ? video : audio
    }

    public func append(_ data: Data, to kind: StreamKind) { buffer(kind).append(data) }
    public func finish(_ kind: StreamKind) { buffer(kind).finish() }

    public func cancel() {
        video.cancel()
        audio.cancel()
    }
}
