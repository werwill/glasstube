import AppKit
import Observation
import PlaybackKit
import YouTubeSource

/// Opciones de la línea de comandos.
///
///     PlaybackDemo <videoId> [--renderer metal|opengl] [--max-height N] [--start S]
///                  [--seek-at A:B,…] [--switch-at T:ALTURA|T:+|T:-,…] [--fault-at T:FALLO,…] [--stop-at S]
///                  [--url-ttl S] [--potoken-ttl S] [--on-top] [--report ARCHIVO] [--live] [--live-engine avplayer|mpv]
///                  [--verbose]
///                  [--cover S | --hide S | --minimize S]
struct DemoOptions {
    var videoId = "aqz-KE-bpKQ" // Big Buck Bunny (público)
    var renderer = MPVRenderer.metal
    var maxHeight = 1080
    var start = 0.0
    var seeks: [(at: Double, to: Double)] = []
    var switches: [(at: Double, target: String)] = []
    var faults: [(at: Double, fault: String)] = []
    var stopAt: Double?
    var urlTTL: Double?
    var poTokenTTL: Double?
    var onTop = false
    var report: URL?
    var live = false
    /// Motor de los directos: AVPlayer (lo de hoy) o MPVEngine con el HLS por URL (lo que tendría Windows).
    var liveEngine = PlayerEngineKind.avPlayer
    var verbose = false
    /// Cada petición SABR en la bitácora (también con --verbose, que además trae los mensajes info de mpv).
    var logSabr = false
    var hwdec: String?
    /// Segundos de reloj tras los que la demo termina (p. ej. en un directo).
    var maxWall: Double?
    /// Cambios de tamaño de la ventana: T:ANCHOxALTO (puntos).
    var resizes: [(at: Double, size: CGSize)] = []
    /// Pulsaciones sintéticas a la ventana: T:TECLA con TECLA = space, left, right, up, -, = (prueban los botones).
    var keys: [(at: Double, key: String)] = []
    /// Capturas del cuadro (`screenshot-raw` de mpv) en cada acción del plan y cada 60 s.
    var shots: URL?
    /// Tapa la ventana con otra opaca desde el arranque durante S segundos (`--cover S`), o la oculta con la app
    /// (`--hide S`) o la minimiza (`--minimize S`): la ventana no se compone mientras tanto (prueba del video en negro).
    var cover: Double?
    /// Escribe ahí el número de la ventana (para `screencapture -l`).
    var windowFile: String?
    /// Prueba: tras cada `--resize-at`, propiedades de mpv que se fijan (`nombre=valor;nombre=valor`).
    var resizeProbe: String?
    /// La vista del video llena la ventana (sin fijarla en 16:9): un cambio de tamaño cambia también la proporción.
    var fill = false
    var hide: Double?
    var minimize: Double?

    init(arguments: [String]) {
        var args = arguments.dropFirst()[...]
        func value() -> String? { args.isEmpty ? nil : args.removeFirst() }
        func pairs(_ text: String?) -> [(Double, String)] {
            (text ?? "").split(separator: ",").compactMap { item in
                let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let at = Double(parts[0]) else { return nil }
                return (at, parts[1])
            }
        }
        while let arg = args.popFirst() {
            switch arg {
            case "--renderer": renderer = value().flatMap { $0 == "opengl" ? .openGL : .metal } ?? .metal
            case "--max-height": maxHeight = value().flatMap(Int.init) ?? maxHeight
            case "--start": start = value().flatMap(Double.init) ?? 0
            case "--seek-at": seeks = pairs(value()).compactMap { at, to in Double(to).map { (at, $0) } }
            case "--switch-at": switches = pairs(value())
            case "--fault-at": faults = pairs(value())
            case "--stop-at": stopAt = value().flatMap(Double.init)
            case "--url-ttl": urlTTL = value().flatMap(Double.init)
            case "--potoken-ttl": poTokenTTL = value().flatMap(Double.init)
            case "--on-top": onTop = true
            case "--report": report = value().map { URL(fileURLWithPath: $0) }
            case "--live": live = true
            case "--live-engine": live = true; liveEngine = value() == "mpv" ? .mpv : .avPlayer
            case "--hwdec": hwdec = value()
            case "--max-wall": maxWall = value().flatMap(Double.init)
            case "--keys-at": keys = pairs(value())
            case "--resize-at":
                resizes = pairs(value()).compactMap { at, size in
                    let parts = size.split(separator: "x").compactMap { Double($0) }
                    return parts.count == 2 ? (at, CGSize(width: parts[0], height: parts[1])) : nil
                }
            case "--shots": shots = value().map { URL(fileURLWithPath: $0) }
            case "--verbose", "-v": verbose = true; logSabr = true
            case "--log-sabr": logSabr = true
            case "--cover": cover = value().flatMap(Double.init)
            case "--window-file": windowFile = value()
            case "--resize-probe": resizeProbe = value()
            case "--fill": fill = true
            case "--hide": hide = value().flatMap(Double.init)
            case "--minimize": minimize = value().flatMap(Double.init)
            default:
                if !arg.hasPrefix("-") { videoId = arg }
            }
        }
    }
}

/// Estado de la demo: crea el motor, carga el video, ejecuta el plan de prueba y arma el reporte.
@MainActor
@Observable
final class DemoModel {
    let options: DemoOptions
    private(set) var engine: (any PlayerEngine)?
    private(set) var title = ""
    private(set) var lastNote = ""
    private(set) var failure: String?
    /// Posición mientras se arrastra la barra.
    var scrubbing: Double?
    private var source: SabrMediaSource?

    // Medición
    private let startedAt = Date()
    private var log: [String] = []
    private var stretches: [(from: Double, to: Double, wall: TimeInterval)] = []
    private var stretch: (from: Double, to: Double, since: Date)?
    private var lastPosition: Double?
    private var stalls = 0
    private var wasStalled = false
    private var hardwareSamples = 0
    private var softwareSamples = 0
    private var decoders: Set<String> = []
    private var actions: [String] = []
    private var pendingSeeks: [(at: Double, to: Double)]
    private var pendingSwitches: [(at: Double, target: String)]
    private var pendingFaults: [(at: Double, fault: String)]
    private var pendingResizes: [(at: Double, size: CGSize)]
    private var pendingKeys: [(at: Double, key: String)]
    private var lastKeyAt = Date.distantPast
    /// La ventana de la demo (para `--resize-at`).
    weak var window: NSWindow?
    private var busy = false
    private var finished = false

    init(options: DemoOptions) {
        self.options = options
        pendingSeeks = options.seeks
        pendingSwitches = options.switches
        pendingFaults = options.faults
        pendingResizes = options.resizes
        pendingKeys = options.keys
    }

    /// Evento de teclado por `NSApp.sendEvent`, el mismo camino que una tecla real: los atajos de los botones de SwiftUI
    /// (`keyboardShortcut`) lo reciben como equivalente de teclado.
    private func press(_ key: String) {
        guard let window else { return }
        let table: [String: (String, UInt16)] = [
            "space": (" ", 49), "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123),
            "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
            "-": ("-", 27), "=": ("=", 24),
        ]
        guard let (characters, code) = table[key] else { return record("tecla desconocida: \(key)") }
        let flags: NSEvent.ModifierFlags = ["left", "right", "up"].contains(key) ? [.function, .numericPad] : []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            NSApp.sendEvent(event)
        }
    }

    var status: PlayerStatus? { engine?.status }

    func start() async {
        do {
            if options.live {
                let live = try await YouTubeLive.hlsManifest(videoId: options.videoId)
                title = live.title ?? options.videoId
                let item = PlaybackItem(id: options.videoId, title: title, source: .url(live.hlsURL), isLive: live.isLive)
                let directo = "directo: \(live.isLive ? "sí" : "no")"
                if options.liveEngine == .mpv {
                    // El manifiesto maestro tal cual: mpv elige la variante de más bitrate (hls-bitrate) y las demás
                    // quedan como pistas de video para el cambio de calidad.
                    let engine = try MPVEngine(configuration: mpvConfiguration())
                    self.engine = engine
                    listen(engine)
                    record("MPVEngine (\(options.renderer.rawValue)): HLS \(live.hlsURL.host ?? "?") (\(directo))")
                    try await engine.load(item)
                } else {
                    let engine = AVEngine()
                    self.engine = engine
                    listen(engine)
                    record("AVEngine: HLS \(live.hlsURL.host ?? "?") (\(directo))")
                    try await engine.load(item)
                }
            } else {
                let engine = try MPVEngine(configuration: mpvConfiguration())
                self.engine = engine
                listen(engine)
                var sabr = SabrSourceOptions()
                sabr.maxHeight = options.maxHeight
                sabr.urlLifetime = options.urlTTL
                sabr.poTokenLifetime = options.poTokenTTL
                sabr.logRequests = options.logSabr
                let source = try SabrMediaSource(videoId: options.videoId, options: sabr)
                self.source = source
                record("MPVEngine (\(options.renderer.rawValue)), fuente SABR \(options.videoId)")
                try await engine.load(PlaybackItem(id: options.videoId, source: .streamed(source), startPosition: options.start))
                title = source.title ?? options.videoId
            }
        } catch {
            failure = "\(error)"
            record("FALLA al cargar: \(error)")
            finish("no cargó")
            return
        }
        Task { await monitor() }
    }

    private func mpvConfiguration() -> MPVEngine.Configuration {
        var configuration = MPVEngine.Configuration()
        configuration.renderer = options.renderer
        if let hwdec = options.hwdec { configuration.hwdec = hwdec }
        if options.verbose { configuration.mpvLogLevel = "info" }
        return configuration
    }

    private func listen(_ engine: any PlayerEngine) {
        let events = engine.events()
        Task {
            for await event in events {
                switch event {
                case .note(let message):
                    lastNote = message
                    record(message)
                case .error(let error):
                    record("error: \(error.message)\(error.recoverable ? " (recuperable)" : "")")
                case .state(let state):
                    record("estado: \(state)")
                case .seekCompleted(let position):
                    record(String(format: "búsqueda terminada en %.2f s", position))
                case .tracks, .time, .buffer:
                    break
                }
            }
        }
    }

    // MARK: - Controles

    func togglePause() { engine?.togglePause() }

    func seek(by delta: Double) {
        guard let engine, !busy else { return }
        busy = true
        Task {
            await engine.seek(by: delta)
            busy = false
        }
    }

    func seek(to seconds: Double) {
        guard let engine, !busy else { return }
        busy = true
        Task {
            await engine.seek(to: seconds, mode: .exact)
            busy = false
        }
    }

    func select(_ track: MediaTrack) {
        guard let engine, !busy else { return }
        busy = true
        Task {
            do {
                try await engine.select(track: track)
            } catch {
                record("cambio de pista falló: \(error)")
            }
            busy = false
        }
    }

    /// Un escalón de altura arriba (+1) o abajo (-1), con el mismo códec si lo hay; o la mayor altura ≤ `height`.
    func qualityTrack(step: Int? = nil, height: Int? = nil) -> MediaTrack? {
        guard let tracks = engine?.status.videoTracks, let current = tracks.first(where: \.isSelected) else { return nil }
        let sameCodec = tracks.filter { $0.codec == current.codec }
        let pool = sameCodec.count > 1 ? sameCodec : tracks
        let currentHeight = current.height ?? 0
        if let height {
            return pool.filter { ($0.height ?? 0) <= height }.max { ($0.height ?? 0, $0.fps ?? 0) < ($1.height ?? 0, $1.fps ?? 0) }
        }
        let heights = Set(pool.compactMap(\.height)).sorted()
        guard let step, let next = step > 0 ? heights.first(where: { $0 > currentHeight }) : heights.last(where: { $0 < currentHeight }) else { return nil }
        return pool.filter { $0.height == next }.max { ($0.fps ?? 0) < ($1.fps ?? 0) }
    }

    // MARK: - Plan de prueba y medición

    /// Guarda el cuadro actual como JPEG (lo que dibuja la VO de mpv; no es una captura de la pantalla).
    private func shot(_ label: String, window: Bool = false) async {
        guard let dir = options.shots, let engine = engine as? MPVEngine else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let position = engine.status.position
        guard let image = await engine.currentFrame(window: window) else {
            record("captura \(label): mpv no dio cuadro")
            return
        }
        let url = dir.appendingPathComponent(String(format: "%@-%06.1f-%@.jpg", options.videoId, position, label))
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: url)
        record("captura \(label): \(url.lastPathComponent) (\(image.width)x\(image.height))")
    }

    private func monitor() async {
        var lastStatus = Date.distantPast
        var lastShot = Date()
        while !finished {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let status = engine?.status else { continue }
            sample(status)
            if Date().timeIntervalSince(lastStatus) >= 10 {
                lastStatus = Date()
                record(String(format: "▶ %.1f / %@ s · %@ · %@ · por delante %@ s · caídos %d/%d",
                              status.position, status.duration.map { String(format: "%.0f", $0) } ?? "-", "\(status.state)",
                              status.videoDescription ?? "-", status.buffer.ahead.map { String(format: "%.1f", $0) } ?? "-",
                              status.droppedFrames, status.decoderDroppedFrames))
            }
            if case .failed(let error) = status.state {
                failure = error.message
                finish("error: \(error.message)")
                return
            }
            if status.state == .ended {
                finish("fin del video")
                return
            }
            if let maxWall = options.maxWall, Date().timeIntervalSince(startedAt) >= maxWall {
                finish(String(format: "%.0f s de reloj", maxWall))
                return
            }
            // Las teclas también con pausa (la barra espaciadora la quita).
            // En pausa la posición no avanza: la barra espaciadora siguiente sale a los 3 s.
            if let next = pendingKeys.first,
               status.position >= next.at || (next.key == "space" && status.state == .paused && Date().timeIntervalSince(lastKeyAt) >= 3) {
                pendingKeys.removeFirst()
                lastKeyAt = Date()
                actions.append(String(format: "tecla %@ en %.1f s (%@)", next.key, status.position, "\(status.state)"))
                record("plan: " + actions.last!)
                press(next.key)
                let index = actions.count - 1
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let status = engine?.status else { return }
                    actions[index] += String(format: " → a los 1,5 s: %@, %.1f s, %@", "\(status.state)", status.position,
                                             status.selectedVideoTrack?.title ?? "-")
                    record("plan: " + actions[index])
                }
            }
            guard !busy, status.state == .playing else { continue }
            let position = status.position
            if Date().timeIntervalSince(lastShot) >= 60 {
                lastShot = Date()
                await shot("periodica")
            }
            if let next = pendingResizes.first, position >= next.at, let window {
                pendingResizes.removeFirst()
                var frame = window.frame
                let content = window.contentRect(forFrameRect: frame)
                frame.size.width += next.size.width - content.width
                frame.size.height += next.size.height - content.height
                window.setFrame(frame, display: true, animate: false)
                actions.append(String(format: "ventana a %.0fx%.0f en %.1f s", next.size.width, next.size.height, position))
                record(actions.last!)
                Task {
                    if let probe = options.resizeProbe, let engine = engine as? MPVEngine {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        for pair in probe.split(separator: ";") {
                            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                            guard parts.count == 2 else { continue }
                            await engine.setMPVProperty(parts[0], parts[1])
                            record("prueba: \(parts[0]) = \(parts[1])")
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await shot("tras-redimensionar", window: true)
                }
            }
            if let next = pendingFaults.first, position >= next.at {
                pendingFaults.removeFirst()
                let ok = source?.injectFault(next.fault) ?? false
                actions.append(String(format: "fallo %@ en %.1f s%@", next.fault, position, ok ? "" : " (desconocido)"))
                record(actions.last!)
            }
            if let next = pendingSeeks.first, position >= next.at {
                pendingSeeks.removeFirst()
                let before = Date()
                actions.append(String(format: "búsqueda %.1f → %.1f s", position, next.to))
                record("plan: " + actions.last!)
                await shot("antes-busqueda")
                busy = true
                await engine?.seek(to: next.to, mode: .exact)
                busy = false
                Task { await shot("despues-busqueda") }
                let landed = engine?.status.position ?? 0
                actions[actions.count - 1] += String(format: ": en %.2f s tras %.2f s", landed, Date().timeIntervalSince(before))
                record("plan: " + actions.last!)
            } else if let next = pendingSwitches.first, position >= next.at {
                pendingSwitches.removeFirst()
                let target: MediaTrack?
                switch next.target {
                case "+": target = qualityTrack(step: 1)
                case "-": target = qualityTrack(step: -1)
                default: target = qualityTrack(height: Int(next.target.replacingOccurrences(of: "p", with: "")) ?? 720)
                }
                guard let target else {
                    record("plan: no hay calidad para \(next.target)")
                    continue
                }
                let from = engine?.status.selectedVideoTrack?.title ?? "-"
                let before = Date()
                actions.append(String(format: "calidad en %.1f s: %@ → %@", position, from, target.title))
                record("plan: " + actions.last!)
                await shot("antes-calidad")
                busy = true
                do {
                    try await engine?.select(track: target)
                } catch {
                    record("plan: cambio de calidad falló: \(error)")
                }
                busy = false
                let index = actions.count - 1
                let pedido = target.height
                Task {
                    // mpv tarda un momento en informar la resolución nueva.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let shown = engine?.status.videoDescription ?? "-"
                    let ok = pedido.map { shown.contains("x\($0)") } ?? false
                    actions[index] += String(format: ": reanudó tras %.2f s; el motor muestra %@ (%@)", Date().timeIntervalSince(before) - 2, shown,
                                             ok ? "la altura pedida" : "NO es la altura pedida")
                    record("plan: " + actions[index])
                    await shot("despues-calidad")
                }
            } else if pendingSeeks.isEmpty, pendingSwitches.isEmpty, pendingFaults.isEmpty, let stopAt = options.stopAt, position >= stopAt {
                finish(String(format: "se llegó a %.0f s", stopAt))
                return
            }
        }
    }

    /// Tramos de reproducción continua: la posición avanza en estado `playing`, sin saltos.
    private func sample(_ status: PlayerStatus) {
        let stalled = status.state == .buffering && status.buffer.isStalled
        if stalled && !wasStalled { stalls += 1 }
        wasStalled = stalled
        if status.state == .playing {
            if let hw = status.hardwareDecoder { hardwareSamples += 1; decoders.insert(hw) } else { softwareSamples += 1 }
        }
        guard status.state == .playing else {
            closeStretch()
            return
        }
        let position = status.position
        if var current = stretch, let last = lastPosition, position >= last - 0.05, position - last < 3 {
            current.to = position
            stretch = current
        } else {
            closeStretch()
            stretch = (position, position, Date())
        }
        lastPosition = position
    }

    private func closeStretch() {
        if let s = stretch, s.to - s.from >= 0.5 { stretches.append((s.from, s.to, Date().timeIntervalSince(s.since))) }
        stretch = nil
        lastPosition = nil
    }

    func record(_ message: String) {
        let line = String(format: "[+%6.1f s] ", Date().timeIntervalSince(startedAt)) + message
        log.append(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private var mpvExtra: String?

    private func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        Task {
            if let engine = engine as? MPVEngine {
                var parts: [String] = []
                for name in ["current-ao", "hwdec-current", "vo-delayed-frame-count", "frame-drop-count", "decoder-frame-drop-count", "current-vo", "gpu-api", "display-fps", "estimated-display-fps", "vsync-jitter", "video-sync"] {
                    parts.append("\(name) \(await engine.mpvProperty(name) ?? "-")")
                }
                mpvExtra = parts.joined(separator: " · ")
            }
            writeReport(reason)
        }
    }

    private func writeReport(_ reason: String) {
        closeStretch()
        record("fin: \(reason)")
        let status = engine?.status
        var lines = ["", "PlaybackDemo — \(title) (\(options.videoId))"]
        lines.append("Motor: \(engine.map { $0.kind.rawValue } ?? "-")\(engine is AVEngine ? "" : ", salida \(options.renderer.rawValue)")")
        lines.append("Video: \(status?.videoDescription ?? "-") · decodificadores vistos: \(decoders.sorted().joined(separator: ", ")) · muestras reproduciendo con hardware \(hardwareSamples), sin hardware \(softwareSamples)")
        lines.append("Cuadros descartados (último archivo): VO \(status?.droppedFrames ?? 0), decodificador \(status?.decoderDroppedFrames ?? 0)")
        if let source { lines.append("SABR: " + source.lifeSummary) }
        if let extra = mpvExtra { lines.append("mpv: " + extra) }
        lines.append("Tramos continuos (posición, duración en reloj):")
        for s in stretches { lines.append(String(format: "  %.1f → %.1f s (%.1f s de video en %.1f s)", s.from, s.to, s.to - s.from, s.wall)) }
        lines.append("Acciones:")
        lines += actions.map { "  " + $0 }
        let longest = stretches.map { $0.to - $0.from }.max() ?? 0
        lines.append(String(format: "Tramo continuo más largo: %.1f s · pausas por falta de datos: %d · fin: %@", longest, stalls, reason))
        if let failure { lines.append("FALLA: \(failure)") }
        lines.append("Bitácora:")
        lines += log.map { "  " + $0 }
        let report = lines.joined(separator: "\n")
        print(report)
        if let url = options.report { try? report.write(to: url, atomically: true, encoding: .utf8) }
        Task {
            await engine?.shutdown()
            exit(failure == nil ? 0 : 2)
        }
    }
}
