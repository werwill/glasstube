import AppKit
import Foundation
import Libmpv

/// Motor principal: libmpv (LGPL, Vendor/Libmpv.xcframework) con salida Metal (o OpenGL de respaldo),
/// `hwdec=auto-safe` y, para fuentes propias (SABR), dos flujos `glasstube://` por `mpv_stream_cb`.
///
/// Fuentes `.streamed`: los flujos no son buscables (SABR busca por tiempo y no da índice byte↔tiempo). Una búsqueda
/// dentro de la caché del demuxer es un `seek` normal de mpv; fuera de ella, o al cambiar de calidad, es otra carga
/// («generación» `g`): flujos nuevos `glasstube://<id>/{video,audio}?g=N` desde T. mpv arranca al inicio del segmento
/// que contiene T (S, hasta ~7 s antes); el motor espera en pausa, mostrando el último cuadro anterior a la carga,
/// a que la caché de mpv llegue a T, hace un seek exacto y reanuda (la «llegada»). Ver RESULTADOS.md del spike,
/// «SABR en libmpv» y «(e) Llegar a T tras un loadfile».
@MainActor
public final class MPVEngine: PlayerEngine {
    public struct Configuration: Sendable {
        public var renderer: MPVRenderer = .metal
        /// `auto-safe` con VideoToolbox delante. Con la salida Metal (Vulkan), `auto-safe` a secas prueba primero el
        /// decodificador Vulkan Video de FFmpeg, que MoltenVK no tiene (`VK_KHR_video_decode_queue`): falla, deja
        /// errores de referencias en los primeros paquetes y luego cae en VideoToolbox. Si VideoToolbox no puede (p. ej.
        /// AV1 en un M1), sigue la lista de `auto-safe`.
        public var hwdec = "videotoolbox,auto-safe"
        /// Tras una carga desde T, pausa hasta el seek exacto y retiene el último cuadro (como el spike por omisión).
        public var holdUntilExactSeek = true
        public var demuxerMaxBytes = "150MiB"
        /// Lo que se puede volver atrás sin recargar (los flujos SABR no son buscables).
        public var demuxerMaxBackBytes = "100MiB"
        /// Nivel de los mensajes de mpv que se reenvían como `.note` (warn, info, v…).
        public var mpvLogLevel = "warn"
        /// Opciones extra de mpv, antes de `mpv_initialize`.
        public var extraOptions: [(String, String)] = []

        public init() {}
    }

    public let kind = PlayerEngineKind.mpv
    public let status = PlayerStatus()
    public let configuration: Configuration
    public var videoView: NSView { surface }

    let mpv: MPVHandle
    let surface: MPVVideoSurface
    private let registry = MPVStreamRegistry()
    private let clock = PlaybackClock()
    private let timeGate = TimeGate()
    private let hub = EventHub()
    private var monitor: Task<Void, Never>?
    private var isShutDown = false

    // Carga actual
    private var item: PlaybackItem?
    private var source: (any StreamedMediaSource)?
    private var generationCounter = 0
    private var current: Generation?
    private var landing: Landing?
    /// Una carga, búsqueda por recarga o cambio de calidad en curso (no se aceptan otras a la vez).
    private var busy = false
    /// Lo que pidió el usuario (la llegada pausa por su cuenta).
    private var userPaused = false
    private var loading = false
    private var sourceFailure: String?
    /// Error que detuvo la reproducción (hasta el próximo `load`).
    private var failure: PlayerError?
    private var lastRestartAt: Date?
    /// Búsquedas de mpv que esperan su PLAYBACK_RESTART, por número de búsqueda.
    private var seekWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var seekCounter = 0
    /// Quienes esperan a que termine la llegada en curso.
    private var landingWaiters: [CheckedContinuation<Void, Never>] = []
    private var mpvPaused = false
    private var pausedForCache = false
    private var eofReached = false
    private var lastTimeEvent = Date.distantPast
    private var mpvTracks: [MediaTrack] = []
    /// Reproducción que no avanza teniendo datos (ver `StallWatchdog`).
    private var watchdog = StallWatchdog()
    private var resizeCheck: Task<Void, Never>?

    struct Generation {
        let id: Int
        let from: Double
        let streams: StreamPair
        let uris: [String]
        let task: Task<Void, Never>
    }

    /// Llegada a T tras una carga desde T (ver el comentario de la clase).
    struct Landing {
        let generation: Int
        let target: Double
        let issuedAt: Date
        let hold: Bool
        var seekAt: Date?
        var landedAt: Date?
    }

    public init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        mpv = try MPVHandle()
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        surface = configuration.renderer == .metal ? MPVMetalView(frame: frame) : MPVOpenGLView(frame: frame)
        try setUp()
    }

    private func setUp() throws {
        let options: [(String, String)] = surface.mpvOptions() + [
            ("hwdec", configuration.hwdec),
            // Flujos sin seek_fn: la única forma de volver atrás sin recargar es la caché del demuxer.
            ("cache", "yes"),
            ("demuxer-seekable-cache", "yes"),
            ("demuxer-max-bytes", configuration.demuxerMaxBytes),
            ("demuxer-max-back-bytes", configuration.demuxerMaxBackBytes),
            // Los segmentos SABR traen marcas de tiempo absolutas: time-pos es la posición en el video.
            ("rebase-start-time", "no"),
            ("idle", "yes"),
            // Al final se queda en el último cuadro (eof-reached) en lugar de descargar el archivo.
            ("keep-open", "yes"),
            ("ytdl", "no"),
            ("load-scripts", "no"),
            // Tampoco los scripts internos de mpv (Lua: estadísticas, consola, selector, menús…): la interfaz es de la app,
            // y con hardened runtime (versiones notarizadas) el LuaJIT de libmpv ejecuta memoria sin firmar al cargarlos
            // y macOS mata el proceso («Code Signature Invalid»). Sin ellos no se crea ningún estado de Lua.
            ("load-stats-overlay", "no"),
            ("load-console", "no"),
            ("load-auto-profiles", "no"),
            ("load-select", "no"),
            ("load-commands", "no"),
            ("load-positioning", "no"),
            ("load-context-menu", "no"),
            ("config", "no"),
            ("terminal", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("audio-client-name", "Glasstube"),
        ] + configuration.extraOptions
        for (name, value) in options { try mpv.setOption(name, value) }
        try mpv.initialize()
        mpv.requestLog(configuration.mpvLogLevel)
        let observed: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG), ("speed", MPV_FORMAT_DOUBLE),
            ("volume", MPV_FORMAT_DOUBLE), ("mute", MPV_FORMAT_FLAG), ("hwdec-current", MPV_FORMAT_STRING),
            ("video-format", MPV_FORMAT_STRING), ("width", MPV_FORMAT_INT64), ("height", MPV_FORMAT_INT64),
            ("container-fps", MPV_FORMAT_DOUBLE), ("track-list", MPV_FORMAT_NODE), ("frame-drop-count", MPV_FORMAT_INT64),
            ("decoder-frame-drop-count", MPV_FORMAT_INT64), ("demuxer-cache-duration", MPV_FORMAT_DOUBLE),
        ]
        for (name, format) in observed { mpv.observe(name, format) }
        mpv.startEventLoop(Self.eventHandler(engine: self, clock: clock, timeGate: timeGate))
        try mpv.addStreamProtocol("glasstube", registry: registry)
        try surface.attach(to: mpv)
        (surface as? MPVMetalView)?.onDrawableSizeChange = { [weak self] size in self?.surfaceResized(size) }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                let fast = self?.landing.map { $0.landedAt == nil } ?? false
                try? await Task.sleep(nanoseconds: fast ? 50_000_000 : 250_000_000)
                await self?.tick()
            }
        }
    }

    public func events() -> AsyncStream<PlayerEvent> { hub.stream() }

    // MARK: - API

    public func load(_ item: PlaybackItem) async throws {
        guard !isShutDown else { throw PlayerError("el motor ya se cerró") }
        busy = true
        defer { busy = false }
        // Desde ya se ignoran los `time-pos` del archivo anterior (si no, el estado nuevo salía un momento con su posición).
        timeGate.beginLoad()
        await stopStreaming()
        self.item = item
        source = nil
        sourceFailure = nil
        failure = nil
        eofReached = false
        loading = true
        userPaused = false
        watchdog.reset()
        status.duration = nil
        status.position = item.startPosition
        status.videoTracks = []
        status.audioTracks = []
        status.subtitleTracks = []
        updateState()
        do {
            try await mpv.run { mpv in
                try mpv.setProperty("force-media-title", item.title ?? item.id)
                try mpv.setProperty("pause", "no")
            }
            switch item.source {
            case .url(let url, let audio, let headers):
                try await loadURL(url, audio: audio, headers: headers, start: item.startPosition)
            case .streamed(let source):
                self.source = source
                source.onNote = { [weak self] message in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.note(message) } }
                }
                try await source.prepare()
                if status.duration == nil { status.duration = source.duration }
                publishTracks()
                try await startGeneration(at: item.startPosition, reason: "inicio", hold: item.startPosition > 0)
            }
        } catch {
            loading = false
            let failure = PlayerError("\(error)")
            report(failure)
            throw failure
        }
    }

    public func play() {
        userPaused = false
        if eofReached {
            Task { await seek(to: 0, mode: .exact) }
        }
        // Durante una llegada con pausa, la quita la propia llegada.
        if !(landing.map { $0.hold && $0.landedAt == nil } ?? false) { mpv.setPropertyAsync("pause", "no") }
        updateState()
    }

    public func pause() {
        userPaused = true
        mpv.setPropertyAsync("pause", "yes")
        updateState()
    }

    public func togglePause() {
        if userPaused || status.state == .paused { play() } else { pause() }
    }

    /// Una búsqueda o un cambio de pista que llega durante otra carga espera su turno (hasta 15 s) en lugar de perderse:
    /// los controladores (SponsorBlock, VideoState) cuentan con que se haga.
    private func waitUntilIdle() async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while busy && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        return !busy
    }

    public func seek(to seconds: Double, mode: SeekMode) async {
        guard item != nil, await waitUntilIdle(), item != nil else { return }
        let duration = status.duration ?? .infinity
        let target = max(0, min(seconds, duration.isFinite ? duration - 0.5 : seconds))
        if source != nil {
            let ranges = await cacheRanges()
            if ranges.contains(where: { target >= $0.lowerBound && target < $0.upperBound - 1 }) {
                await mpvSeek(target, mode: mode)
            } else {
                note(String(format: "búsqueda a %.1f s fuera de la caché de mpv [%@] → carga nueva", target,
                            ranges.map { String(format: "%.1f–%.1f", $0.lowerBound, $0.upperBound) }.joined(separator: ", ")))
                busy = true
                defer { busy = false }
                do {
                    try await startGeneration(at: target, reason: "búsqueda", hold: configuration.holdUntilExactSeek)
                    await waitForLanding()
                } catch {
                    report(PlayerError("búsqueda: \(error)", recoverable: true))
                }
            }
        } else {
            await mpvSeek(target, mode: mode)
        }
    }

    public func setRate(_ rate: Double) {
        mpv.setPropertyAsync("speed", String(rate))
    }

    public func setVolume(_ volume: Double) {
        mpv.setPropertyAsync("volume", String(max(0, min(1, volume)) * 100))
    }

    public func setMuted(_ muted: Bool) {
        mpv.setPropertyAsync("mute", muted ? "yes" : "no")
    }

    public func select(track: MediaTrack) async throws {
        if let source, track.kind != .subtitle {
            // Calidad (o pista de audio) de la fuente: otra generación en la posición actual con la pista nueva.
            let currentID = (track.kind == .video ? status.videoTracks : status.audioTracks).first(where: \.isSelected)?.id
            guard track.id != currentID else { return }
            guard await waitUntilIdle() else { throw PlayerError("hay otra carga en curso", recoverable: true) }
            busy = true
            defer { busy = false }
            let position = status.position
            note(String(format: "cambio de pista en %.1f s: %@ → %@", position, currentID ?? "-", track.title))
            try await startGeneration(at: position, reason: "pista \(track.title)", hold: configuration.holdUntilExactSeek) {
                try source.selectTrack(id: track.id)
            }
            publishTracks()
            await waitForLanding()
            return
        }
        // Pistas propias de mpv (archivo o URL, y subtítulos).
        guard let id = track.id.split(separator: ":").last.map(String.init) else { return }
        let property = track.kind == .video ? "vid" : track.kind == .audio ? "aid" : "sid"
        try await mpv.run { try $0.setProperty(property, id) }
    }

    /// El cuadro actual tal como lo dibuja la VO (`screenshot-raw`; con gpu-next funciona también con VideoToolbox).
    /// `window`: escalado a la vista, con lo que haya encima del video (subtítulos); si no, a la resolución del video.
    public func currentFrame(window: Bool = false) async -> CGImage? {
        try? await mpv.run { mpv in
            MPVMetalView.image(from: try mpv.commandNode(["screenshot-raw", window ? "window" : "video", "bgra"]))
        }
    }

    /// Escritura directa de una propiedad de mpv (diagnóstico y pruebas).
    public func setMPVProperty(_ name: String, _ value: String) async {
        try? await mpv.run { try $0.setProperty(name, value) }
    }

    /// Lectura directa de una propiedad de mpv (diagnóstico: `current-ao`, `vo-delayed-frame-count`…).
    public func mpvProperty(_ name: String) async -> String? {
        try? await mpv.run { $0.string(name) }
    }

    public func disableSubtitles() {
        mpv.setPropertyAsync("sid", "no")
    }

    public func addSubtitle(url: URL, language: String?, title: String?) async throws {
        var args = ["sub-add", url.absoluteString, "select"]
        args.append(title ?? language ?? url.lastPathComponent)
        if let language { args.append(language) }
        let command = args
        try await mpv.run { try $0.command(command) }
    }

    public func stop() async {
        await stopStreaming()
        item = nil
        source = nil
        try? await mpv.run { try $0.command(["stop"]) }
        loading = false
        failure = nil
        updateState()
    }

    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        monitor?.cancel()
        await stopStreaming()
        surface.detach()
        let mpv = self.mpv
        let registry = self.registry
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                mpv.shutdown()
                registry.releaseMPVReference()
                done.resume()
            }
        }
        resumeSeekWaiters()
        resumeLandingWaiters()
        hub.finish()
    }

    // MARK: - Cargas

    private func loadURL(_ url: URL, audio: URL?, headers: [String: String], start: Double) async throws {
        timeGate.beginLoad()
        clock.positionMs = nil
        let headerList = headers.map { "\($0.key): \($0.value)" }
        try await mpv.run { mpv in
            try mpv.setStringList("http-header-fields", headerList)
            try mpv.setStringList("audio-files", audio.map { [$0.absoluteString] } ?? [])
            try mpv.setProperty("start", start > 0 ? String(format: "%.3f", start) : "none")
            try mpv.command(["loadfile", url.absoluteString, "replace"])
        }
        note("carga \(url.host ?? url.lastPathComponent)\(audio != nil ? " + audio aparte" : "")")
    }

    /// Flujos nuevos `glasstube://<id>/{video,audio}?g=N`, la tarea de streaming de la fuente desde `seconds` y
    /// `loadfile`. Antes se cancela la generación anterior; `prepare` corre con ella ya detenida (cambio de pista).
    /// No se pasa `start=T`: con un flujo no buscable mpv responde "Cannot seek in this stream" y arranca igual en el
    /// primer segmento, que la fuente ya eligió por T; el ajuste fino es la llegada (`followLanding`).
    private func startGeneration(at seconds: Double, reason: String, hold: Bool, prepare: (() throws -> Void)? = nil) async throws {
        guard let source else { return }
        let holding = hold && seconds > 0
        if holding {
            // La imagen se queda en el cuadro de ahora hasta llegar a T.
            await surface.beginHold(mpv: mpv)
            if let metal = surface as? MPVMetalView, let size = metal.holdImageSize {
                note(String(format: "retención: el cuadro actual (%.0fx%.0f) queda en pantalla hasta llegar a T", size.width, size.height))
            }
            try? await mpv.run { try $0.setProperty("pause", "yes") }
        }
        let old = current
        current = nil
        if let old {
            old.task.cancel()
            await old.task.value
        }
        // Si la fuente no acepta el cambio, la carga sigue igual (con la pista anterior) y luego se informa.
        var prepareError: Error?
        do { try prepare?() } catch { prepareError = error }
        timeGate.beginLoad()
        clock.positionMs = nil
        sourceFailure = nil
        eofReached = false
        watchdog.reset()
        generationCounter += 1
        let id = generationCounter
        let streams = StreamPair()
        let videoURI = "glasstube://\(source.identifier)/video?g=\(id)"
        let audioURI = "glasstube://\(source.identifier)/audio?g=\(id)"
        registry.register(videoURI, streams.video)
        registry.register(audioURI, streams.audio)
        let task = Self.startStreaming(source: source, from: seconds, streams: streams, clock: clock, generation: id, engine: self)
        current = Generation(id: id, from: seconds, streams: streams, uris: [videoURI, audioURI], task: task)
        resumeLandingWaiters()
        landing = seconds > 0 ? Landing(generation: id, target: seconds, issuedAt: Date(), hold: holding) : nil
        note(String(format: "carga g%d (%@) desde %.1f s%@", id, reason, seconds, holding ? ", en pausa hasta el seek exacto" : ""))
        let userPaused = self.userPaused
        try await mpv.run { mpv in
            if !holding && !userPaused { try mpv.setProperty("pause", "no") }
            try mpv.setProperty("start", "none")
            try mpv.setStringList("http-header-fields", [])
            // audio-files es una lista de rutas separada por ':' y partiría la URI: se pasa como lista (NODE).
            try mpv.setStringList("audio-files", [audioURI])
            try mpv.command(["loadfile", videoURI, "replace"])
        }
        old?.uris.forEach(registry.remove) // por si mpv no llegó a abrirlas
        updateState()
        if let prepareError { throw prepareError }
    }

    private func stopStreaming() async {
        resumeLandingWaiters()
        landing = nil
        if let current {
            current.task.cancel()
            current.streams.cancel()
            await current.task.value
            current.uris.forEach(registry.remove)
        }
        current = nil
        surface.endHold()
    }

    nonisolated private static func startStreaming(source: any StreamedMediaSource, from seconds: Double, streams: StreamPair,
                                                   clock: PlaybackClock, generation: Int, engine: MPVEngine) -> Task<Void, Never> {
        Task.detached {
            do {
                try await source.stream(from: seconds, into: streams, clock: clock)
                await engine.note("g\(generation): las dos pistas llegaron al final")
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                // mpv sigue con lo que tiene en búfer; al acabarse, eof-reached y se informa el error.
                streams.video.finish()
                streams.audio.finish()
                await engine.sourceStopped(generation: generation, error: error)
            }
        }
    }

    private func sourceStopped(generation: Int, error: Error) {
        guard current?.id == generation else { return }
        sourceFailure = "\(error)"
        note("g\(generation): la fuente se detuvo (\(error)); mpv sigue con lo que tiene")
    }

    // MARK: - Búsqueda y llegada

    /// `seek` de mpv dentro de lo que tiene; vuelve con el PLAYBACK_RESTART (o a los 5 s).
    private func mpvSeek(_ target: Double, mode: SeekMode) async {
        let flags = mode == .exact ? "absolute+exact" : "absolute+keyframes"
        seekCounter += 1
        let id = seekCounter
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            seekWaiters[id] = continuation
            Task {
                do {
                    try await mpv.run { try $0.command(["seek", String(format: "%.3f", target), flags]) }
                } catch {
                    note("seek falló: \(error)")
                    seekWaiters.removeValue(forKey: id)?.resume()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                seekWaiters.removeValue(forKey: id)?.resume()
            }
        }
        eofReached = false
        hub.send(.seekCompleted(position: status.position))
    }

    private func resumeSeekWaiters() {
        let waiters = seekWaiters.values
        seekWaiters = [:]
        waiters.forEach { $0.resume() }
    }

    private func waitForLanding() async {
        guard landing.map({ $0.landedAt == nil }) ?? false else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            landingWaiters.append(continuation)
        }
    }

    private func resumeLandingWaiters() {
        let waiters = landingWaiters
        landingWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// En cuanto la caché de mpv llega a T, seek exacto (antes, mpv lo rechaza: «Cannot seek in this stream»). Con
    /// retención, mpv espera en pausa en S; al terminar el seek (PLAYBACK_RESTART en T) se muestra la imagen y se reanuda.
    private func followLanding() async {
        guard var l = landing, l.landedAt == nil, timeGate.acceptsTime, let position = timeGate.position else { return }
        let generation = l.generation
        defer { if landing?.generation == generation { landing = l } }
        if l.seekAt == nil {
            if !l.hold, position >= l.target - 0.5 { // ya a menos de 0,5 s de T: sin seek
                l.landedAt = Date()
            } else {
                let ranges = await cacheRanges()
                guard landing?.generation == generation else { return }
                let ready = ranges.contains { l.target >= $0.lowerBound && l.target < $0.upperBound }
                guard ready || Date().timeIntervalSince(l.issuedAt) > 10 else { return }
                l.seekAt = Date()
                landing = l
                let target = l.target
                try? await mpv.run { try $0.command(["seek", String(format: "%.3f", target), "absolute+exact"]) }
                return
            }
        }
        if l.landedAt == nil, let seekAt = l.seekAt {
            if let restart = lastRestartAt, restart > seekAt, position >= l.target - 0.25 {
                l.landedAt = restart
            } else if l.hold ? Date().timeIntervalSince(seekAt) > 3 : position >= l.target + 0.5 {
                l.landedAt = Date() // mpv no hizo el seek: se sigue desde donde esté
                note("la llegada a \(String(format: "%.1f", l.target)) s no terminó con el seek exacto; se reanuda igual")
            }
        }
        guard let landed = l.landedAt else { return }
        surface.endHold()
        if l.hold, !userPaused { try? await mpv.run { try $0.setProperty("pause", "no") } }
        note(String(format: "g%d en %.1f s a los %.2f s de la carga", l.generation, l.target, landed.timeIntervalSince(l.issuedAt)))
        resumeLandingWaiters()
        hub.send(.seekCompleted(position: l.target))
        updateState()
    }

    // MARK: - Tamaño de la salida

    /// La capa cambió de tamaño (ventana, pantalla completa, panel lateral de la app). Se espera a que se asiente.
    private func surfaceResized(_ size: CGSize) {
        guard item != nil else { return }
        resizeCheck?.cancel()
        resizeCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncOutputSize(size)
        }
    }

    /// El contexto `moltenvk` de MPVKit solo lee `drawableSize` cuando la VO se reconfigura (su `control` no informa
    /// cambios de tamaño). Si la capa cambia de tamaño con un video en curso, MoltenVK rehace la swapchain con el
    /// tamaño nuevo pero mpv sigue calculando el rectángulo del video para el anterior: la imagen sale recortada o
    /// corrida. Se compara lo que mpv cree (`osd-width`/`osd-height`) con la capa y, si no coincide, se fuerza una
    /// reconfiguración de la VO cambiando la proporción un 0,05 % un instante y volviéndola a la del video.
    private func syncOutputSize(_ size: CGSize) async {
        guard item != nil, !isShutDown else { return }
        func mpvSize() async -> CGSize? {
            guard let values = try? await mpv.run({ [$0.string("osd-width"), $0.string("osd-height")] }),
                  let w = values[0].flatMap(Double.init), let h = values[1].flatMap(Double.init), w > 0, h > 0 else { return nil }
            return CGSize(width: w, height: h)
        }
        // Sin VO todavía (antes del primer cuadro): mpv leerá el tamaño al configurarla.
        guard let before = await mpvSize() else { return }
        let matches = { (other: CGSize) in abs(other.width - size.width) < 2 && abs(other.height - size.height) < 2 }
        guard !matches(before) else {
            note(String(format: "capa %.0fx%.0f; mpv ya la usa", size.width, size.height))
            return
        }
        let aspect = (try? await mpv.run { $0.string("video-params/aspect") }).flatMap { $0.flatMap(Double.init) } ?? 16.0 / 9.0
        // Dos cambios separados: si llegan juntos, mpv solo ve el último y no reconfigura.
        try? await mpv.run { try $0.setProperty("video-aspect-override", String(format: "%.6f", aspect * 1.0005)) }
        try? await Task.sleep(nanoseconds: 120_000_000)
        try? await mpv.run { try $0.setProperty("video-aspect-override", "no") }
        try? await Task.sleep(nanoseconds: 250_000_000)
        let after = await mpvSize()
        note(String(format: "capa %.0fx%.0f; mpv seguía en %.0fx%.0f → VO reconfigurada: %@", size.width, size.height,
                    before.width, before.height, after.map { matches($0) ? "ahora coincide" : String(format: "aún %.0fx%.0f", $0.width, $0.height) } ?? "sin dato"))
    }

    /// `seekable-ranges` de `demuxer-cache-state`.
    private func cacheRanges() async -> [ClosedRange<Double>] {
        guard let state = try? await mpv.run({ $0.node("demuxer-cache-state") }), let ranges = state["seekable-ranges"]?.array else { return [] }
        return ranges.compactMap { range in
            guard let start = range["start"]?.double, let end = range["end"]?.double, end >= start else { return nil }
            return start...end
        }
    }

    // MARK: - Monitor y eventos

    private func tick() async {
        await followLanding()
        if status.state == .playing || status.state == .buffering || status.state == .paused {
            let ranges = await cacheRanges()
            let ahead = ranges.first(where: { $0.contains(status.position) }).map { $0.upperBound - status.position }
            let buffer = BufferStatus(ahead: ahead, seekableRanges: ranges, isStalled: pausedForCache)
            if buffer != status.buffer {
                status.buffer = buffer
                hub.send(.buffer(buffer))
            }
            await watchProgress(ranges: ranges)
        }
    }

    /// Si mpv tiene datos y debería avanzar pero `time-pos` no se mueve, deja el estado en la bitácora y hace un seek
    /// exacto en la misma posición (rehace el cuadro y la sincronía). Ver `StallWatchdog`.
    private func watchProgress(ranges: [ClosedRange<Double>]) async {
        let position = timeGate.acceptsTime ? timeGate.position : nil
        let landingDone = landing.map { $0.landedAt != nil } ?? true
        let expects = item != nil && failure == nil && !loading && !busy && !userPaused && !mpvPaused && !pausedForCache
            && !eofReached && landingDone
        let reference = position ?? ranges.first?.lowerBound
        let ahead = reference.flatMap { point in ranges.first(where: { $0.contains(point) }).map { $0.upperBound - point } }
        guard watchdog.check(position: position, expectsProgress: expects, ahead: ahead) else { return }
        let target = reference ?? 0
        let window = surface.window
        let visible = window.map { $0.occlusionState.contains(.visible) ? "visible" : "no visible" } ?? "sin ventana"
        let drawable = (surface as? MPVMetalView).map { String(format: ", capa %.0fx%.0f", $0.metalLayer.drawableSize.width, $0.metalLayer.drawableSize.height) } ?? ""
        let vo = try? await mpv.run { mpv in
            ["vo-configured", "vo-delayed-frame-count", "frame-drop-count", "estimated-vf-fps"].map { "\($0) \(mpv.string($0) ?? "-")" }
        }
        note(String(format: "sin avance desde hace %.0f s con %.1f s en caché (ventana %@%@; %@): seek exacto en %.2f s (empujón %d de %d)",
                    watchdog.threshold, ahead ?? 0, visible, drawable, (vo ?? []).joined(separator: ", "), target,
                    watchdog.nudges, watchdog.maxNudges))
        Task { await mpvSeek(target, mode: .exact) }
    }

    nonisolated private static func eventHandler(engine: MPVEngine, clock: PlaybackClock, timeGate: TimeGate) -> @Sendable (MPVEvent) -> Void {
        { [weak engine] event in
            // time-pos llega en cada cuadro: el reloj de la fuente se actualiza aquí, sin pasar por el actor principal.
            if case .property("time-pos", let value) = event {
                guard timeGate.acceptsTime, let seconds = value.double else { return }
                timeGate.position = seconds
                clock.positionMs = Int64(seconds * 1000)
                guard timeGate.shouldPublishTime() else { return }
            }
            if case .fileLoaded = event { timeGate.fileLoaded() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { engine?.handle(event) }
            }
        }
    }

    private func handle(_ event: MPVEvent) {
        switch event {
        case .property(let name, let value):
            handleProperty(name, value)
        case .log(let prefix, let level, let text):
            note("[mpv/\(prefix)] \(level): \(text)")
        case .fileLoaded:
            loading = false
            updateState()
        case .playbackRestart:
            lastRestartAt = Date()
            loading = false
            if landing == nil || landing?.landedAt != nil { resumeSeekWaiters() }
            if let position = timeGate.position { status.position = position }
            updateState()
            Task { await followLanding() }
        case .endFile(let reason, let error):
            if reason == MPV_END_FILE_REASON_ERROR {
                report(PlayerError("mpv no pudo reproducir: \(MPVHandle.errorString(error))"))
            }
        case .shutdown:
            break
        default:
            break
        }
    }

    private func handleProperty(_ name: String, _ value: MPVNode) {
        switch name {
        case "time-pos":
            guard let position = value.double else { return }
            // Mientras se llega a T (carga desde T), mpv reproduce desde el principio del segmento (o informa 0): la
            // posición pública sigue siendo T. Antes salía 0:00 durante la llegada, y con la imagen aún en negro eso era
            // el «video en negro en 0:00» que vio la app al reanudar.
            if let landing, landing.landedAt == nil {
                status.position = landing.target
            } else {
                status.position = position
            }
            if Date().timeIntervalSince(lastTimeEvent) >= 0.25 {
                lastTimeEvent = Date()
                hub.send(.time(position: status.position, duration: status.duration))
            }
        case "duration":
            // En flujos SABR la duración del contenedor no es fiable: manda la de la fuente.
            if source == nil, let duration = value.double { status.duration = duration }
        case "pause":
            mpvPaused = value.flag ?? false
            updateState()
        case "paused-for-cache":
            pausedForCache = value.flag ?? false
            updateState()
        case "eof-reached":
            eofReached = value.flag ?? false
            if eofReached, let sourceFailure {
                report(PlayerError("la fuente de datos se detuvo: \(sourceFailure)"))
            } else {
                updateState()
            }
        case "speed":
            status.rate = value.double ?? 1
        case "volume":
            status.volume = (value.double ?? 100) / 100
        case "mute":
            status.isMuted = value.flag ?? false
        case "hwdec-current":
            let hw = value.string
            status.hardwareDecoder = hw == nil || hw == "no" ? nil : hw
            describeVideo()
        case "video-format", "width", "height", "container-fps":
            describeVideo()
        case "frame-drop-count":
            status.droppedFrames = Int(value.int ?? 0)
        case "decoder-frame-drop-count":
            status.decoderDroppedFrames = Int(value.int ?? 0)
        case "track-list":
            mpvTracks = Self.tracks(from: value)
            publishTracks()
        default:
            break
        }
    }

    private func describeVideo() {
        Task {
            let info = try? await mpv.run { mpv in
                [mpv.string("video-format"), mpv.string("width"), mpv.string("height"), mpv.string("container-fps"), mpv.string("hwdec-current")]
            }
            guard let info, let format = info[0] else { return }
            var text = "\(format) \(info[1] ?? "?")x\(info[2] ?? "?")"
            if let fps = info[3].flatMap(Double.init) { text += String(format: "@%.0f", fps) }
            text += " · " + (info[4].map { $0 == "no" ? "software" : $0 } ?? "software")
            status.videoDescription = text
        }
    }

    private func publishTracks() {
        let subtitles = mpvTracks.filter { $0.kind == .subtitle }
        if let source {
            status.videoTracks = source.videoTracks
            status.audioTracks = source.audioTracks
        } else {
            status.videoTracks = mpvTracks.filter { $0.kind == .video }
            status.audioTracks = mpvTracks.filter { $0.kind == .audio }
        }
        status.subtitleTracks = subtitles
        hub.send(.tracks(status.videoTracks + status.audioTracks + status.subtitleTracks))
    }

    nonisolated static func tracks(from node: MPVNode) -> [MediaTrack] {
        (node.array ?? []).compactMap { track in
            guard let type = track["type"]?.string, let id = track["id"]?.int else { return nil }
            let kind: MediaTrackKind
            switch type {
            case "video": kind = .video
            case "audio": kind = .audio
            case "sub": kind = .subtitle
            default: return nil
            }
            let codec = track["codec"]?.string
            let width = track["demux-w"]?.int.map(Int.init)
            let height = track["demux-h"]?.int.map(Int.init)
            let language = track["lang"]?.string
            var title = track["title"]?.string ?? language ?? "\(type) \(id)"
            if kind == .video, let height { title = "\(height)p" + (codec.map { " \($0)" } ?? "") }
            return MediaTrack(id: "mpv:\(type):\(id)", kind: kind, title: title, language: language, codec: codec,
                              width: width, height: height, fps: track["demux-fps"]?.double,
                              bitrate: track["demux-bitrate"]?.int.map(Int.init), isSelected: track["selected"]?.flag ?? false,
                              isExternal: track["external"]?.flag ?? false)
        }
    }

    private func updateState() {
        let state: PlaybackState
        if let failure {
            state = .failed(failure)
        } else if item == nil {
            state = .idle
        } else if loading {
            state = .loading
        } else if eofReached {
            state = .ended
        } else if userPaused {
            state = .paused
        } else if busy || pausedForCache || (landing.map { $0.landedAt == nil } ?? false) {
            state = .buffering
        } else if mpvPaused {
            state = .paused
        } else {
            state = .playing
        }
        if state != status.state {
            status.state = state
            hub.send(.state(state))
        }
    }

    private func report(_ error: PlayerError) {
        note("error: \(error.message)")
        hub.send(.error(error))
        if !error.recoverable {
            failure = error
            updateState()
        }
    }

    func note(_ message: String) {
        hub.send(.note(message))
    }
}

/// Posición de mpv vista desde el hilo de eventos. Antes de cada `loadfile` se ignoran los `time-pos` que aún lleguen
/// del archivo anterior, hasta FILE_LOADED.
final class TimeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var accepts = false
    private var current: Double?
    private var lastPublished = Date.distantPast

    func beginLoad() { lock.withLock { accepts = false; current = nil } }
    func fileLoaded() { lock.withLock { accepts = true } }
    var acceptsTime: Bool { lock.withLock { accepts } }

    var position: Double? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// A lo más 10 veces por segundo hacia el actor principal.
    func shouldPublishTime() -> Bool {
        lock.withLock {
            guard Date().timeIntervalSince(lastPublished) >= 0.1 else { return false }
            lastPublished = Date()
            return true
        }
    }
}
