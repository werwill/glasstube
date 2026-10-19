import AppKit
import Foundation
import Observation
import PlaybackKit
import YouTubeSource
import YTKit

/// Controles del reproductor que pueden tener el foco del teclado. El foco es propio (no el del sistema) para que
/// funcione igual sin "Navegación con teclado" activada: las flechas lo mueven como la cruceta de SmartTube.
enum PlayerControl: Hashable, CaseIterable {
    case back, subscribe, like, dislike, comments, info, more
    case skip
    case seekBar
    case previous, playPause, next, mute, speed, captions, quality, audio, pip, fullscreen

    /// Filas de arriba abajo (la de "saltar" solo cuenta si se ve).
    static let rows: [[PlayerControl]] = [
        [.back, .subscribe, .like, .dislike, .comments, .info, .more],
        [.skip],
        [.seekBar],
        [.previous, .playPause, .next, .mute, .speed, .captions, .quality, .audio, .pip, .fullscreen],
    ]
}

/// Menús emergentes de la cápsula (popovers del sistema).
enum PlayerPopover: Hashable {
    case quality, speed, captions, audio, more
}

/// «A continuación»: el siguiente video al terminar, con su cuenta atrás.
struct UpNext: Equatable {
    var item: MediaItem
    /// Sale de la cola (si no, de los sugeridos).
    var fromQueue: Bool
    var deadline: Date
}

/// Un video abierto: motor (`MPVEngine` por SABR, `AVEngine` en directos), metadatos (`next`), storyboard y
/// subtítulos (VISIONOS), SponsorBlock, historial local y "Ahora suena".
@Observable
final class PlayerModel {
    private(set) var item: MediaItem
    private(set) var engine: (any PlayerEngine)?
    private(set) var metadata: MediaItemMetadata?
    private(set) var extras: PlayerExtras?
    private(set) var segments: [SponsorSegment] = []
    private(set) var failure: String?
    /// YouTube no dio el video y pide iniciar sesión (LOGIN_REQUIRED: el «confirma que no eres un bot», un video
    /// privado o con restricción de edad). Si no hay cuenta, el aviso ofrece iniciar sesión.
    private(set) var failureNeedsSignIn = false
    /// La fuente SABR del video actual (para saber por qué falló la carga).
    private var sabrSource: SabrMediaSource?
    private(set) var captionTrack: CaptionTrack?
    private(set) var isFullScreen = false
    /// Aviso breve sobre el video (p. ej. "Se saltó el patrocinio").
    private(set) var toast: String?
    /// Con cuenta: "me gusta" y suscripción al canal (de `next`; se actualizan al tocar los botones).
    private(set) var likeStatus: LikeStatus?
    private(set) var isSubscribed: Bool?
    /// Panel lateral abierto (nil = cerrado) y el foco del teclado dentro de él (nil = en los controles).
    var panelTab: SidePanelTab? {
        didSet {
            if let panelTab { settings.sidePanelTab = panelTab.rawValue }
            panelDidChange()
        }
    }
    var panelFocus: PanelFocus?
    private(set) var comments: CommentsModel?
    private(set) var chat: LiveChatModel?
    /// Votos de Return YouTube Dislike (con el ajuste).
    private(set) var votes: VoteCounts?
    /// Al terminar: el siguiente video y su cuenta atrás.
    private(set) var upNext: UpNext?
    /// Ya se vio el primer cuadro de este video. Hasta entonces se muestra su miniatura con un indicador (antes el
    /// reproductor quedaba en negro, sin aviso, mientras SABR llegaba a la posición de reanudación).
    private(set) var hasStartedPlaying = false

    var controlsVisible = true
    var focusedControl: PlayerControl?
    var popover: PlayerPopover? {
        didSet { if popover == nil { bumpControls() } else { hideTask?.cancel() } }
    }
    /// Tiempo bajo el puntero (o arrastrado) en la barra, y su x en el espacio "player", para la burbuja del storyboard.
    var scrubTime: Double?
    var scrubX: CGFloat = 0
    var scrubBarTop: CGFloat = 0
    var isDragging = false

    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored private var mpv: MPVEngine?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var lastSaved = Date.distantPast
    /// Último reporte de la posición al historial de YouTube (uno por minuto como máximo, más pausa y cierre).
    @ObservationIgnored private var lastSynced = Date.distantPast
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var skippedSegments: Set<String> = []
    @ObservationIgnored private var previousItems: [MediaItem] = []
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var nowPlaying = NowPlayingController()
    @ObservationIgnored private var startAt: Double?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var upNextTask: Task<Void, Never>?

    init(item: MediaItem, app: AppModel, startAt: Double?) {
        self.item = item
        self.app = app
        self.startAt = startAt
    }

    var settings: AppSettings { app.settings }
    var status: PlayerStatus? { engine?.status }
    /// Posición mostrada: el destino de una búsqueda en curso (fuera de lo descargado tarda en llegar) o la del motor.
    var position: Double { seekTarget ?? status?.position ?? 0 }
    /// Destino de la búsqueda en curso: J, L y las flechas seguidas se suman a él, no a la posición vieja.
    private(set) var seekTarget: Double?
    /// La búsqueda terminó en el motor pero su posición todavía no llegó al destino (fuera de lo descargado, SABR da 0
    /// un instante): el destino se sigue mostrando hasta que la posición llegue o pasen unos segundos (fase 4: el
    /// teléfono recibía «0 s» al adelantar lejos).
    @ObservationIgnored private var seekSettleTask: Task<Void, Never>?
    var duration: Double? { status?.duration ?? extras?.duration ?? item.durationSeconds.map(Double.init) }
    var isPlaying: Bool {
        switch status?.state {
        case .playing, .buffering: true
        default: false
        }
    }
    var isLoading: Bool {
        guard failure == nil else { return false }
        switch status?.state {
        case nil, .idle, .loading: return true
        default: return false
        }
    }

    /// Esperando datos (carga, llegada a una posición o búfer vacío): se muestra el indicador.
    var isWaiting: Bool {
        guard failure == nil else { return false }
        if isLoading { return true }
        if case .buffering? = status?.state { return true }
        return false
    }
    /// El título que se muestra: el de DeArrow si está activado y lo hay.
    var title: String { app.deArrow.title(videoId: item.videoId, fallback: originalTitle) }
    var originalTitle: String { metadata?.title ?? extras?.title ?? item.title }
    var author: String? { metadata?.author ?? item.author ?? extras?.author }
    var chapters: [Chapter] { metadata?.chapters ?? [] }
    var hasPrevious: Bool { !previousItems.isEmpty }
    var queue: PlayQueue { app.queue }
    /// El siguiente de la reproducción automática según YouTube (o el primer sugerido).
    var nextSuggestion: MediaItem? {
        metadata?.nextVideo ?? suggestedVideos.first
    }
    /// Lo que pone «Siguiente»: la cola y, si está vacía, el sugerido.
    var nextItem: MediaItem? { queue.next ?? nextSuggestion }
    /// Los sugeridos reproducibles (sin Shorts ni el video actual).
    var suggestedVideos: [MediaItem] {
        (metadata?.suggestions ?? []).flatMap(\.items).filter { $0.isPlayable && !$0.isShort && $0.videoId != item.videoId }.uniqued()
    }

    /// Una calidad por resolución y cuadros por segundo, con el códec preferido (la fuente da cada una en VP9, AVC y
    /// AV1). La elegida siempre aparece.
    var qualityOptions: [MediaTrack] {
        let tracks = status?.videoTracks ?? []
        let order = settings.codec.order
        var best: [String: MediaTrack] = [:]
        for track in tracks {
            let key = Format.quality(track)
            if let current = best[key], current.isSelected { continue }
            if track.isSelected { best[key] = track; continue }
            let rank = order.firstIndex(of: track.codec ?? "") ?? order.count
            let currentRank = best[key].map { order.firstIndex(of: $0.codec ?? "") ?? order.count } ?? Int.max
            if rank < currentRank { best[key] = track }
        }
        return best.values.sorted {
            let a = Format.qualityClass(width: $0.width, height: $0.height ?? 0), b = Format.qualityClass(width: $1.width, height: $1.height ?? 0)
            return a != b ? a > b : ($0.fps ?? 0) > ($1.fps ?? 0)
        }
    }

    func chapter(at time: Double) -> Chapter? {
        chapters.last { Double($0.startMs) / 1000 <= time }
    }

    /// Tramo de SponsorBlock que se puede saltar en la posición actual.
    var activeSegment: SponsorSegment? {
        guard settings.sponsorBlockEnabled else { return nil }
        let now = position
        return segments.first { now >= $0.start && now < $0.end - 0.5 }
    }

    // MARK: - Carga

    func start() {
        if Automation.shared.logsKeys { NSLog("Glasstube automation: reproductor abierto con «\(item.title)»") }
        installObservers()
        loadTask = Task { await load() }
    }

    /// Otro video en el mismo reproductor (siguiente, sugerido, o uno elegido desde fuera).
    func replace(with newItem: MediaItem, startAt: Double? = nil, remember: Bool = true) {
        saveProgress(force: true)
        if remember { previousItems.append(item) }
        item = newItem
        self.startAt = startAt
        lastSynced = .distantPast
        hasStartedPlaying = false
        likeStatus = nil
        isSubscribed = nil
        chat?.stop()
        chat = nil
        comments = nil
        votes = nil
        cancelUpNext()
        if panelFocus != nil { panelFocus = .tabs }
        metadata = nil
        extras = nil
        segments = []
        captionTrack = nil
        skippedSegments = []
        seekTarget = nil
        failure = nil
        failureNeedsSignIn = false
        sabrSource = nil
        popover = nil
        seekSettleTask?.cancel()
        seekSettleTask = nil
        loadTask?.cancel()
        loadTask = Task { await load() }
        bumpControls()
    }

    private func load() async {
        guard let videoId = item.videoId else { return }
        let item = item
        nowPlaying.attach(to: self)

        // Metadatos, storyboard/subtítulos, SponsorBlock, DeArrow y Return YouTube Dislike en paralelo con la carga.
        app.deArrow.request(videoId)
        Task { [weak self, service = app.service] in
            let metadata = try? await service.metadata(for: item)
            guard let self, self.item.id == item.id else { return }
            self.metadata = metadata
            self.likeStatus = metadata?.likeStatus
            self.isSubscribed = metadata?.isSubscribed
            if let metadata {
                self.enrich(with: metadata)
                self.comments = CommentsModel(videoId: videoId, token: metadata.commentsContinuation, sorts: metadata.commentSorts,
                                              service: service)
                if let token = metadata.liveChatContinuation {
                    self.chat = LiveChatModel(token: token, isReplay: metadata.isLiveChatReplay, service: service)
                }
                self.suggestedVideos.prefix(30).forEach { self.app.deArrow.request($0.videoId) }
                // Spotlight: el video con su título y canal ya completos (fase 4).
                if self.hasStartedPlaying || self.engine != nil { self.app.spotlight.index(video: self.item, duration: self.duration) }
                // La pestaña abierta puede no existir en este video (capítulos, chat).
                if let tab = self.panelTab, !self.availableTabs.contains(tab) { self.panelTab = .description }
                self.panelDidChange()
            }
            self.nowPlaying.update(self)
        }
        if settings.showDislikes, !item.isLive {
            Task { [weak self] in
                let votes = try? await DislikeClient.shared.votes(videoId: videoId)
                guard let self, self.item.id == item.id else { return }
                self.votes = votes
            }
        }
        Task { [weak self, extrasService = app.extras] in
            let extras = try? await extrasService.extras(videoId: videoId)
            guard let self, self.item.id == item.id else { return }
            self.extras = extras
            if self.settings.subtitlesByDefault { await self.enableCaptions() }
        }
        if settings.sponsorBlockEnabled {
            Task { [weak self, client = app.sponsorBlock] in
                let segments = await client.segments(videoId: videoId)
                guard let self, self.item.id == item.id else { return }
                self.segments = segments + Automation.shared.demoSegments(for: videoId)
            }
        } else {
            segments = Automation.shared.demoSegments(for: videoId)
        }

        let resume = startAt ?? resumePosition(for: videoId)
        do {
            if item.isLive {
                let live = try await YouTubeLive.hlsManifest(videoId: videoId, catalog: app.catalog)
                let engine = AVEngine()
                await use(engine)
                try await engine.load(PlaybackItem(id: videoId, title: item.title, source: .url(live.hlsURL), isLive: true))
            } else {
                let engine = try mpv ?? MPVEngine()
                mpv = engine
                await use(engine)
                var options = SabrSourceOptions()
                options.maxHeight = settings.maxHeight
                options.videoCodecs = settings.codec.order
                options.readahead = Double(settings.buffer.rawValue)
                options.simulatedLoginRequired = Automation.shared.simulatedBotChecks
                let source = try SabrMediaSource(videoId: videoId, options: options, catalog: app.catalog, poTokenProvider: app.poToken,
                                                 account: app.accounts.manager)
                sabrSource = source
                try await engine.load(PlaybackItem(id: videoId, title: item.title, source: .streamed(source), startPosition: resume))
            }
            guard !Task.isCancelled else { return }
            app.library.recordPlayback(of: item, position: resume, duration: duration)
            app.spotlight.index(video: self.item, duration: duration)
            nowPlaying.update(self)
            bumpControls()
            app.remote.playerDidLoad(self)
            Automation.shared.playerDidLoad(self)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            fail(error)
        }
    }

    /// El aviso de error. Si YouTube no dio el video, su motivo (ya viene en el idioma de la app) en lugar del texto
    /// técnico del motor ("la fuente de datos se detuvo: player: LOGIN_REQUIRED …").
    private func fail(_ error: Error) {
        if let unplayable = sabrSource?.unplayable {
            failure = unplayable.reason ?? "YouTube no dio este video (\(unplayable.status))."
            failureNeedsSignIn = unplayable.needsSignIn
        } else {
            failure = (error as? PlayerError)?.message ?? "\(error)"
            failureNeedsSignIn = false
        }
        controlsVisible = true
    }

    /// Completa el elemento con los metadatos (un video abierto por id o desde el historial trae pocos datos), para
    /// que el historial y "Seguir viendo" lo muestren bien.
    private func enrich(with metadata: MediaItemMetadata) {
        if let title = metadata.title, item.title == item.videoId || item.renderer == "automation" { item.title = title }
        if item.author == nil { item.author = metadata.author }
        if item.channelId == nil { item.channelId = metadata.channelId }
        if item.authorThumbnails.isEmpty { item.authorThumbnails = metadata.authorThumbnails }
        if item.viewCountText == nil { item.viewCountText = metadata.shortViewCountText ?? metadata.viewCountText }
        if item.publishedText == nil { item.publishedText = metadata.relativeDate ?? metadata.publishedDate }
        if item.durationSeconds == nil, let duration { item.durationSeconds = Int(duration) }
    }

    /// Donde se quedó: la posición de esta Mac o, si no la hay, la del historial de YouTube (la tarjeta del historial
    /// de la cuenta trae `startTimeSeconds` y el porcentaje visto).
    private func resumePosition(for videoId: String) -> Double {
        guard settings.resumePlayback else { return 0 }
        if let saved = app.library.savedPosition(for: videoId), let fraction = saved.fraction {
            return fraction > 0.02 && fraction < 0.95 ? max(0, saved.position - 2) : 0
        }
        if let start = item.startTimeSeconds, let percent = item.percentWatched, percent > 2, percent < 95 {
            return max(0, Double(start) - 2)
        }
        return 0
    }

    /// Cambia de motor si hace falta (mpv ↔ AVPlayer) y escucha sus eventos.
    private func use(_ newEngine: any PlayerEngine) async {
        if let engine, engine !== newEngine {
            eventsTask?.cancel()
            if engine === mpv { await engine.stop() } else { await engine.shutdown() }
        }
        guard engine !== newEngine else { return }
        engine = newEngine
        // El volumen que se puso antes (en otro video o desde el teléfono).
        if app.volume < 1 { newEngine.setVolume(app.volume) }
        let events = newEngine.events()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: PlayerEvent) {
        switch event {
        case .time(let position, _):
            settleSeek()
            saveProgress()
            checkSegments(at: position)
            nowPlaying.updateElapsed(self)
        case .state(let state):
            if Automation.shared.logsKeys { NSLog("Glasstube automation: estado \(state) en \(String(format: "%.1f", status?.position ?? -1)) s") }
            nowPlaying.update(self)
            app.remote.playerStateDidChange(self)
            switch state {
            case .paused:
                saveProgress(force: true)
                bumpControls()
            case .ended:
                saveProgress(force: true)
                controlsVisible = true
                scheduleUpNext()
            case .failed(let error):
                fail(error)
            case .playing:
                hasStartedPlaying = true
                bumpControls()
            default:
                break
            }
        case .error(let error) where !error.recoverable:
            fail(error)
        case .note(let note) where Automation.shared.logsNotes:
            NSLog("Glasstube automation: motor: \(note)")
        default:
            break
        }
    }

    private func saveProgress(force: Bool = false) {
        guard engine != nil, force || Date().timeIntervalSince(lastSaved) > 5, position > 1 else { return }
        lastSaved = Date()
        app.library.recordPlayback(of: item, position: position, duration: duration)
        syncHistory(force: force)
    }

    /// Reporta la posición al historial de la cuenta de YouTube (`updateHistoryPosition`): cada minuto, al pausar, al
    /// terminar y al cerrar. Sin sesión, en directos o con el ajuste apagado no hace nada.
    private func syncHistory(force: Bool) {
        guard app.accounts.isSignedIn, settings.syncWatchHistory, !item.isLive, let videoId = item.videoId,
              !syncing, force || Date().timeIntervalSince(lastSynced) > 60 else { return }
        syncing = true
        lastSynced = Date()
        let position = position
        Task { [weak self, service = app.service] in
            do {
                try await service.updateHistoryPosition(videoId: videoId, positionSeconds: position)
                if Automation.shared.logsKeys { NSLog("Glasstube automation: historial de YouTube en %.0f s", position) }
            } catch {
                NSLog("Glasstube: no se pudo guardar la posición en YouTube: \(error)")
            }
            self?.syncing = false
        }
    }

    // MARK: - Cuenta

    /// Me gusta (otra vez: lo quita). Optimista: el botón cambia de inmediato y vuelve si YouTube falla.
    func toggleLike() { setLike(likeStatus == .like ? .indifferent : .like) }

    func toggleDislike() { setLike(likeStatus == .dislike ? .indifferent : .dislike) }

    private func setLike(_ status: LikeStatus) {
        guard requireAccount("dar me gusta"), let videoId = item.videoId else { return }
        let previous = likeStatus
        likeStatus = status
        Task { [weak self, service = app.service] in
            do {
                switch (previous, status) {
                case (_, .like): try await service.setLike(videoId: videoId)
                case (_, .dislike): try await service.setDislike(videoId: videoId)
                case (.dislike?, .indifferent): try await service.removeDislike(videoId: videoId)
                default: try await service.removeLike(videoId: videoId)
                }
                self?.showToast(status == .like ? "Te gusta este video" : status == .dislike ? "No te gusta este video" : "Se quitó la valoración")
            } catch {
                guard let self, self.item.videoId == videoId else { return }
                self.likeStatus = previous
                self.showToast("YouTube no aceptó la valoración: \(AccountModel.describe(error))")
            }
        }
    }

    func toggleSubscribe() {
        guard requireAccount("suscribirte"), let channelId = item.channelId ?? metadata?.channelId else { return }
        let subscribe = !(isSubscribed ?? false)
        isSubscribed = subscribe
        let params = metadata?.subscribeParams
        let channel = author ?? "el canal"
        Task { [weak self, service = app.service] in
            do {
                if subscribe {
                    try await service.subscribe(channelId: channelId, params: params)
                } else {
                    try await service.unsubscribe(channelId: channelId)
                }
                self?.showToast(subscribe ? "Te suscribiste a \(channel)" : "Cancelaste la suscripción a \(channel)")
            } catch {
                self?.isSubscribed = !subscribe
                self?.showToast("YouTube no aceptó el cambio: \(AccountModel.describe(error))")
            }
        }
    }

    /// Sin sesión, avisa y ofrece iniciarla.
    private func requireAccount(_ what: String) -> Bool {
        guard app.accounts.isSignedIn else {
            showToast("Inicia sesión para \(what)")
            return false
        }
        return true
    }

    private func checkSegments(at position: Double) {
        guard settings.sponsorBlockEnabled, settings.sponsorBlockAutoSkip,
              let segment = segments.first(where: { position >= $0.start && position < $0.end - 0.5 }),
              !skippedSegments.contains(segment.id) else { return }
        skippedSegments.insert(segment.id)
        skip(segment)
    }

    // MARK: - Acciones

    func togglePause() {
        engine?.togglePause()
        bumpControls()
    }

    /// Reproducir y pausar sin alternar (teclas multimedia de «Reproducir»/«Pausa» y el teléfono).
    func play() {
        if case .ended? = status?.state { seek(to: 0) }
        if !isPlaying { engine?.play() }
        bumpControls()
    }

    func pause() {
        if isPlaying { engine?.pause() }
        bumpControls()
    }

    func seek(to seconds: Double) {
        guard let engine else { return }
        let target = min(max(0, seconds), (duration ?? .greatestFiniteMagnitude) - 0.5)
        seekTarget = target
        seekSettleTask?.cancel()
        seekSettleTask = nil
        Task {
            await engine.seek(to: target, mode: .exact)
            guard seekTarget == target else { return }
            settleSeek(after: target)
            app.remote.playerDidSeek(self)
        }
        bumpControls()
    }

    /// Suelta el destino de la búsqueda cuando la posición del motor ya está cerca (o a los 4 s).
    private func settleSeek(after finished: Double? = nil) {
        guard let target = seekTarget else { return }
        // Desde `.time` solo cuenta si esta búsqueda ya terminó en el motor (si no, `seekSettleTask` es nil).
        guard finished != nil || seekSettleTask != nil else { return }
        if let actual = status?.position, abs(actual - target) < 3 {
            seekTarget = nil
            seekSettleTask?.cancel()
            seekSettleTask = nil
        } else if seekSettleTask == nil {
            seekSettleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self, self.seekTarget == target else { return }
                self.seekTarget = nil
                self.seekSettleTask = nil
            }
        }
    }

    func seek(by delta: Double) { seek(to: position + delta) }

    func skip(_ segment: SponsorSegment) {
        seek(to: segment.end)
        showToast("Se saltó: \(segment.skipTitle.replacingOccurrences(of: "Saltar ", with: ""))")
    }

    func skipActiveSegment() {
        if let segment = activeSegment {
            skippedSegments.insert(segment.id)
            skip(segment)
        }
    }

    func setRate(_ rate: Double) {
        engine?.setRate(min(4, max(0.25, rate)))
        showToast("Velocidad \(Format.rate(min(4, max(0.25, rate))))")
    }

    static let rates: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    func changeRate(by step: Int) {
        let current = status?.rate ?? 1
        let index = Self.rates.firstIndex { $0 >= current - 0.001 } ?? 3
        setRate(Self.rates[min(Self.rates.count - 1, max(0, index + step))])
    }

    func toggleMute() {
        engine?.setMuted(!(status?.isMuted ?? false))
        Task {
            // El motor confirma el cambio en su estado un momento después.
            try? await Task.sleep(for: .milliseconds(150))
            app.remote.volumeDidChange()
        }
    }

    func setVolume(_ volume: Double) {
        engine?.setVolume(volume)
        if volume > 0, status?.isMuted == true { engine?.setMuted(false) }
        app.rememberVolume(volume)
        app.remote.volumeDidChange()
    }

    func select(_ track: MediaTrack) {
        guard let engine else { return }
        Task {
            do {
                try await engine.select(track: track)
            } catch {
                showToast("No se pudo cambiar: \(error)")
            }
        }
    }

    /// Subtítulos por idioma (el teléfono manda solo el código): los de ese idioma escritos a mano antes que los
    /// automáticos; nil los quita.
    func selectCaption(languageCode: String?) {
        guard let languageCode, !languageCode.isEmpty else {
            selectCaption(nil)
            return
        }
        let captions = extras?.captions ?? []
        let pick = captions.first { $0.languageCode == languageCode && !$0.isAutomatic }
            ?? captions.first { $0.languageCode == languageCode }
            ?? captions.first { $0.languageCode.hasPrefix(languageCode) }
        if let pick {
            selectCaption(pick)
            showToast("Subtítulos: \(pick.title)")
        } else {
            showToast("Este video no tiene subtítulos en ese idioma")
        }
    }

    func selectCaption(_ track: CaptionTrack?) {
        defer { app.remote.captionsDidChange() }
        guard let engine else { return }
        captionTrack = track
        guard let track, let url = track.vttURL else {
            engine.disableSubtitles()
            return
        }
        Task {
            do {
                try await engine.addSubtitle(url: url, language: track.languageCode, title: track.title)
            } catch {
                captionTrack = nil
                showToast("No se pudieron cargar los subtítulos")
            }
        }
    }

    /// C: activa los subtítulos del idioma preferido (o los primeros) o los quita.
    func toggleCaptions() {
        if captionTrack != nil {
            selectCaption(nil)
            showToast("Subtítulos desactivados")
        } else {
            Task { await enableCaptions(announce: true) }
        }
    }

    private func enableCaptions(announce: Bool = false) async {
        guard let captions = extras?.captions, !captions.isEmpty else {
            if announce { showToast("Este video no tiene subtítulos") }
            return
        }
        let language = settings.subtitleLanguage
        let pick = captions.first { $0.languageCode.hasPrefix(language) && !$0.isAutomatic }
            ?? captions.first { $0.languageCode.hasPrefix(language) }
            ?? captions.first { !$0.isAutomatic } ?? captions[0]
        selectCaption(pick)
        if announce { showToast("Subtítulos: \(pick.title)") }
    }

    /// «Siguiente» (botón, Shift+N, tecla multimedia): lo primero de la cola o, si no hay, el sugerido.
    func playNext() {
        cancelUpNext()
        if let queued = queue.popNext() {
            replace(with: queued)
        } else if let next = nextSuggestion {
            replace(with: next)
        }
    }

    // MARK: - A continuación

    /// Al terminar: la cola siempre; los sugeridos solo con la reproducción automática. Cuenta atrás con
    /// «Reproducir ahora» y «Cancelar», como la pantalla final de SmartTube.
    func scheduleUpNext() {
        cancelUpNext()
        let candidate: (MediaItem, Bool)? = queue.next.map { ($0, true) } ?? (settings.autoplayNext ? nextSuggestion.map { ($0, false) } : nil)
        guard let (next, fromQueue) = candidate else { return }
        app.deArrow.request(next.videoId)
        let seconds = max(0, settings.autoplayCountdown)
        upNext = UpNext(item: next, fromQueue: fromQueue, deadline: Date().addingTimeInterval(seconds))
        upNextTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.playUpNext()
        }
    }

    func playUpNext() {
        guard let upNext else { return }
        cancelUpNext()
        if upNext.fromQueue, queue.next?.id == upNext.item.id { _ = queue.popNext() }
        replace(with: upNext.item)
    }

    func cancelUpNext() {
        upNextTask?.cancel()
        upNextTask = nil
        upNext = nil
    }

    // MARK: - Panel lateral

    /// Pestañas que tienen contenido para este video.
    var availableTabs: [SidePanelTab] {
        SidePanelTab.allCases.filter { tab in
            switch tab {
            case .description, .suggestions: true
            case .chapters: !chapters.isEmpty
            case .comments: !item.isLive || comments?.isAvailable == true
            case .chat: chat != nil
            }
        }
    }

    /// Abre el panel en una pestaña (o lo cierra si ya estaba en ella). `keyboard`: el foco entra al panel.
    func togglePanel(_ tab: SidePanelTab? = nil, keyboard: Bool = false) {
        let target = tab ?? panelTab ?? SidePanelTab(rawValue: settings.sidePanelTab) ?? .description
        if panelTab == target, tab != nil || panelTab != nil {
            closePanel()
            return
        }
        popover = nil
        panelTab = availableTabs.contains(target) ? target : .description
        if keyboard {
            panelFocus = .tabs
            focusedControl = nil
        }
        bumpControls()
    }

    func closePanel() {
        panelTab = nil
        if panelFocus != nil {
            panelFocus = nil
            focusedControl = .comments
        }
        bumpControls()
    }

    /// Carga lo que necesita la pestaña a la vista (comentarios la primera vez; el chat solo mientras se ve).
    private func panelDidChange() {
        if panelTab == .comments { comments?.loadIfNeeded() }
        if panelTab == .chat { chat?.start() } else { chat?.stop() }
    }

    func playPrevious() {
        guard let previous = previousItems.popLast() else {
            seek(to: 0)
            return
        }
        replace(with: previous, remember: false)
    }

    func toggleFullScreen() {
        (window ?? NSApp.keyWindow)?.toggleFullScreen(nil)
    }

    func close() {
        saveProgress(force: true)
        cancelUpNext()
        chat?.stop()
        loadTask?.cancel()
        eventsTask?.cancel()
        hideTask?.cancel()
        nowPlaying.clear()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if isFullScreen { toggleFullScreen() }
        NSCursor.setHiddenUntilMouseMoves(false)
        let engine = engine
        self.engine = nil
        Task { await engine?.shutdown() }
    }

    // MARK: - Controles

    /// Muestra los controles y programa que se oculten (no si está en pausa, con un menú abierto o arrastrando).
    func bumpControls() {
        hideTask?.cancel()
        if !controlsVisible { controlsVisible = true }
        guard isPlaying, popover == nil, panelTab == nil, !isDragging, failure == nil, !Automation.shared.keepControls else { return }
        let timeout = settings.controlsTimeout
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.isPlaying, self.popover == nil, self.panelTab == nil, !self.isDragging else { return }
            self.hideControls()
        }
    }

    func hideControls() {
        hideTask?.cancel()
        controlsVisible = false
        focusedControl = nil
        scrubTime = nil
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isFullScreen = true }
        })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isFullScreen = false }
        })
    }
}
