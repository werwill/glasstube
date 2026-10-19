import AppKit
import Observation
import PlaybackKit
import SystemConfiguration
import YTKit

/// Control remoto desde la app de YouTube del teléfono (fase 4; `RemoteController` y `RemoteControlSettingsPresenter`
/// de SmartTube) sobre `LoungeScreen` de YTKit: la Mac hace de «pantalla». Lo que manda el teléfono (elegir video,
/// reproducir, pausar, buscar, volumen, subtítulos, siguiente, la cruceta) se vuelve acciones de la app, y el estado del
/// reproductor vuelve al teléfono (`nowPlaying`, `onStateChange`, `onVolumeChanged`). El enlace vive mientras la app
/// está abierta.
@Observable
final class RemoteControl {
    /// La hoja «Vincular un teléfono».
    enum Pairing: Equatable {
        case requesting
        case code(LoungePairingCode)
        case failed(String)
    }

    private(set) var state: LoungeConnectionState = .stopped
    /// Teléfonos conectados ahora.
    private(set) var remotes: [LoungeRemote] = []
    /// nil = hoja cerrada.
    var pairing: Pairing?
    /// El teléfono que se conectó con la hoja abierta (la hoja lo confirma).
    private(set) var pairedRemote: LoungeRemote?

    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored let screen: LoungeScreen
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    /// La cola del teléfono (`setPlaylist`/`updatePlaylist`): siguiente y anterior la recorren.
    @ObservationIgnored private var remotePlaylist: LoungePlaylist?
    /// Último estado mandado (para no repetirlo en cada evento del motor).
    @ObservationIgnored private var lastReported: (videoId: String, state: LoungePlayerState)?
    @ObservationIgnored private var announced: [String: Date] = [:]

    init(app: AppModel) {
        self.app = app
        // `-GTRemotoEnMemoria`: pruebas con una pantalla nueva en cada arranque (no toca la vinculación guardada).
        let store: LoungeIdentityStore = UserDefaults.standard.bool(forKey: "GTRemotoEnMemoria")
            ? MemoryLoungeIdentityStore() : UserDefaultsLoungeIdentityStore(key: "remoteIdentity")
        screen = LoungeScreen(name: app.settings.remoteName, store: store)
    }

    var settings: AppSettings { app.settings }
    var isEnabled: Bool { settings.remoteEnabled }
    var isConnected: Bool { state == .connected }

    /// Nombre por omisión: «Glasstube en <nombre de la Mac>» (como SmartTube: «<dispositivo> (<app>)»).
    static var defaultName: String {
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
        return "Glasstube en \(computer)"
    }

    // MARK: - Encender y apagar

    /// Al abrir la app, si estaba activado.
    func startIfEnabled() {
        guard isEnabled else { return }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        settings.remoteEnabled = enabled
        if enabled { start() } else { stop() }
    }

    private func start() {
        if eventsTask == nil {
            eventsTask = Task { [weak self, screen] in
                for await event in await screen.events() {
                    self?.handle(event)
                }
            }
        }
        Task { [screen] in await screen.start() }
    }

    private func stop() {
        pairingTask?.cancel()
        pairing = nil
        remotePlaylist = nil
        Task { [screen] in await screen.stop() }
    }

    func rename(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.remoteName = clean.isEmpty ? Self.defaultName : clean
        Task { [screen, name = settings.remoteName] in await screen.setName(name) }
    }

    /// «Desvincular todos los dispositivos» (`resetData`): la pantalla cambia de id y los teléfonos vinculados dejan de
    /// verla. Si estaba activado, sigue activado con la identidad nueva.
    func unlinkAll() {
        remotePlaylist = nil
        remotes = []
        Task { [screen] in await screen.unlinkAll() }
        app.show(banner: "Se desvincularon todos los teléfonos. Para usar uno, vincúlalo otra vez.")
    }

    // MARK: - Vincular

    /// Abre la hoja con un código nuevo (enciende el control remoto si estaba apagado, como «Vincular» en SmartTube).
    func beginPairing() {
        if !isEnabled { setEnabled(true) }
        pairedRemote = nil
        requestCode()
    }

    func requestCode() {
        pairing = .requesting
        pairingTask?.cancel()
        pairingTask = Task { [weak self, screen] in
            if let demo = Automation.shared.demoPairingCode {
                // Capturas: un código de prueba, sin pedirlo a YouTube.
                try? await Task.sleep(for: .milliseconds(300))
                self?.pairing = .code(LoungePairingCode(digits: demo))
                return
            }
            do {
                let code = try await screen.pairingCode()
                guard !Task.isCancelled, self?.pairing != nil else { return }
                self?.pairing = .code(code)
            } catch {
                guard !Task.isCancelled, self?.pairing != nil else { return }
                self?.pairing = .failed(Self.describe(error))
            }
        }
    }

    func closePairing() {
        pairingTask?.cancel()
        pairing = nil
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let url as URLError where url.code == .notConnectedToInternet: "No hay conexión a internet."
        case let url as URLError: url.localizedDescription
        case let http as LoungeHTTPError: "YouTube respondió HTTP \(http.status)."
        default: "\(error)"
        }
    }

    /// Nombre de un teléfono para mostrar (en las capturas con `-GTAnonimo`, uno de prueba).
    func displayName(_ remote: LoungeRemote) -> String {
        guard Automation.shared.masksAccount else { return remote.name }
        return "Teléfono de prueba \((remotes.firstIndex(of: remote) ?? 0) + 1)"
    }

    // MARK: - Eventos

    private func handle(_ event: LoungeEvent) {
        switch event {
        case .state(let newState):
            state = newState
            log("estado \(newState)")
        case .remotes(let list):
            remotes = list
            log("teléfonos conectados: \(list.count)")
        case .command(let command):
            handle(command)
        }
    }

    private func handle(_ command: LoungeCommand) {
        if case .noop = command { return }
        log("← \(command.name)")
        switch command {
        case .setPlaylist(let playlist):
            remotePlaylist = playlist
            guard let videoId = playlist.currentVideoId else { return }
            open(videoId: videoId, at: playlist.currentTime)
        case .updatePlaylist(let playlist):
            // El teléfono cambió la cola (agregó o quitó videos).
            if var current = remotePlaylist {
                current.videoIds = playlist.videoIds
                current.listId = playlist.listId ?? current.listId
                if let index = playlist.currentIndex { current.currentIndex = index }
                remotePlaylist = current
            } else {
                remotePlaylist = playlist
            }
            reportPreviousNext()
        case .play:
            if let player = app.player {
                let wasPlaying = player.isPlaying
                player.play()
                if wasPlaying { reportState(player) }
            } else if let videoId = remotePlaylist?.currentVideoId {
                open(videoId: videoId, at: nil)
            }
        case .pause:
            if let player = app.player {
                let wasPlaying = player.isPlaying
                player.pause()
                // Ya estaba en pausa: igual se confirma, para que el teléfono no quede con otro estado.
                if !wasPlaying { reportState(player) }
            }
        case .next:
            if !playRemoteQueue(step: 1) { app.player?.playNext() }
        case .previous:
            if !playRemoteQueue(step: -1) { app.player?.playPrevious() }
        case .seekTo(let time):
            app.player?.seek(to: time)
        case .setVolume(let volume, let delta):
            let current = Int((app.currentVolume * 100).rounded())
            let target = max(0, min(100, delta.map { current + $0 } ?? volume ?? current))
            app.setVolume(Double(target) / 100)
            // Con video, el reproductor ya lo reporta al cambiar el volumen.
            if app.player == nil { screenSend([.volumeChanged(volume: target, muted: false)]) }
        case .stopVideo:
            remotePlaylist = nil
            app.closePlayer()
        case .setSubtitlesTrack(let subtitles):
            if let player = app.player {
                player.selectCaption(languageCode: subtitles.isOff ? nil : subtitles.languageCode)
            }
        case .dpad(let key):
            press(key)
        case .getNowPlaying:
            reportNowPlaying()
        case .getVolume:
            reportVolume()
        case .getSubtitlesTrack:
            reportSubtitles()
        case .remoteConnected(let remote):
            announceConnected(remote)
            reportVolume()
        case .remoteDisconnected, .loungeStatus, .voiceCommand, .noop, .other:
            break
        }
    }

    /// Abre el video que manda el teléfono (o, si ya es el que suena, solo busca la posición) y trae la app al frente:
    /// el teléfono «transmitió» a esta pantalla.
    private func open(videoId: String, at time: Double?) {
        bringToFront()
        if let player = app.player, player.item.videoId == videoId {
            if let time, abs(time - player.position) > 2 { player.seek(to: time) }
            player.play()
            app.expandPlayer()
            reportNowPlaying()
            return
        }
        var item = MediaItem(kind: .video, title: videoId, renderer: "remote")
        item.videoId = videoId
        // Con 0 (empieza en el teléfono) sigue donde lo dejó esta Mac, como al abrirlo aquí.
        app.play(item, startAt: time.flatMap { $0 > 1 ? $0 : nil })
    }

    /// Siguiente o anterior en la cola del teléfono, si el video actual está en ella.
    private func playRemoteQueue(step: Int) -> Bool {
        guard var playlist = remotePlaylist, !playlist.videoIds.isEmpty else { return false }
        let current = app.player?.item.videoId.flatMap { playlist.videoIds.firstIndex(of: $0) } ?? playlist.currentIndex ?? 0
        let target = current + step
        guard playlist.videoIds.indices.contains(target) else { return false }
        playlist.currentIndex = target
        playlist.videoId = playlist.videoIds[target]
        remotePlaylist = playlist
        open(videoId: playlist.videoIds[target], at: nil)
        return true
    }

    private func announceConnected(_ remote: LoungeRemote) {
        if pairing != nil { pairedRemote = remote }
        // El teléfono repite `remoteConnected` al volver a la app: un aviso por minuto como mucho.
        if let last = announced[remote.id], Date().timeIntervalSince(last) < 60 { return }
        announced[remote.id] = Date()
        app.show(banner: "«\(displayName(remote))» se conectó: ya puedes controlar Glasstube desde el teléfono", seconds: 5)
    }

    /// La cruceta del teléfono como las flechas, Retorno y Esc del teclado (la navegación de la app ya funciona así).
    private func press(_ key: LoungeKey) {
        let name = switch key {
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .enter: "return"
        case .back: "escape"
        }
        let wasActive = NSApp.isActive
        bringToFront()
        Task {
            // Recién activada, la ventana tarda un momento en ser la principal.
            if !wasActive { try? await Task.sleep(for: .milliseconds(250)) }
            KeyInjector.press(name, in: app.mainWindow)
        }
    }

    private func bringToFront() {
        NSApp.activate()
        app.mainWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Reportes al teléfono

    /// Hay a quién avisar: el canal está abierto y hay un teléfono conectado (como `isRemoteDisabled` de SmartTube).
    private var shouldReport: Bool { isConnected && !remotes.isEmpty }

    private func screenSend(_ reports: [LoungeReport]) {
        guard isConnected else { return }
        log("→ \(reports.map(Self.reportName).joined(separator: ", "))")
        Task { [screen] in await screen.send(reports) }
    }

    private static func reportName(_ report: LoungeReport) -> String {
        switch report {
        case .nowPlaying(let playing): playing.map { "nowPlaying \($0.state)" } ?? "nowPlaying (nada)"
        case .stateChange(let state, let time, _): "onStateChange \(state) \(Int(time)) s"
        case .volumeChanged(let volume, _): "onVolumeChanged \(volume)"
        case .subtitlesTrackChanged(_, let language, _): "onSubtitlesTrackChanged \(language ?? "apagados")"
        case .hasPreviousNextChanged(let previous, let next): "onHasPreviousNextChanged \(previous)/\(next)"
        }
    }

    static func loungeState(_ state: PlaybackState?) -> LoungePlayerState {
        switch state {
        case .playing: .playing
        case .paused, .failed: .paused
        case .ended: .ended
        case .buffering, .loading, .idle, nil: .buffering
        }
    }

    private func nowPlaying(_ player: PlayerModel) -> LoungeNowPlaying? {
        guard let videoId = player.item.videoId else { return nil }
        let index = remotePlaylist?.videoIds.firstIndex(of: videoId)
        let fromPhone = index != nil || remotePlaylist?.currentVideoId == videoId
        var duration = player.duration
        if player.item.isLive { duration = max(player.position, duration ?? 0) }
        return LoungeNowPlaying(videoId: videoId, currentTime: player.position, duration: duration,
                                state: Self.loungeState(player.status?.state),
                                listId: fromPhone ? remotePlaylist?.listId : nil,
                                currentIndex: fromPhone ? (index ?? remotePlaylist?.currentIndex) : nil,
                                ctt: fromPhone ? remotePlaylist?.ctt : nil)
    }

    func reportNowPlaying() {
        guard isConnected else { return }
        guard let player = app.player, let playing = nowPlaying(player) else {
            lastReported = nil
            screenSend([.nowPlaying(nil)])
            return
        }
        lastReported = (playing.videoId, playing.state)
        screenSend([.nowPlaying(playing), previousNext(player)])
    }

    private func previousNext(_ player: PlayerModel) -> LoungeReport {
        let index = remotePlaylist.flatMap { list in player.item.videoId.flatMap { list.videoIds.firstIndex(of: $0) } }
        let count = remotePlaylist?.videoIds.count ?? 0
        return .hasPreviousNextChanged(hasPrevious: player.hasPrevious || (index ?? 0) > 0,
                                       hasNext: player.nextItem != nil || (index.map { $0 < count - 1 } ?? false))
    }

    private func reportPreviousNext() {
        guard shouldReport, let player = app.player else { return }
        screenSend([previousNext(player)])
    }

    private func reportVolume() {
        guard isConnected else { return }
        screenSend([.volumeChanged(volume: Int((app.currentVolume * 100).rounded()), muted: app.player?.status?.isMuted ?? false)])
    }

    private func reportSubtitles() {
        guard isConnected, let player = app.player, let videoId = player.item.videoId else { return }
        let track = player.captionTrack
        screenSend([.subtitlesTrackChanged(videoId: videoId, languageCode: track?.languageCode,
                                           vssId: track.map { ($0.isAutomatic ? "a." : ".") + $0.languageCode })])
    }

    // Lo que llama el reproductor.

    /// Video cargado: el teléfono muestra cuál y desde dónde.
    func playerDidLoad(_ player: PlayerModel) {
        guard shouldReport else { return }
        reportNowPlaying()
    }

    /// Cambió el estado del motor (reproduciendo, pausa, cargando, terminado).
    func playerStateDidChange(_ player: PlayerModel) {
        guard shouldReport, let videoId = player.item.videoId else { return }
        let state = Self.loungeState(player.status?.state)
        if let lastReported, lastReported.videoId == videoId, lastReported.state == state { return }
        if lastReported?.videoId != videoId {
            reportNowPlaying()
            return
        }
        lastReported = (videoId, state)
        screenSend([.stateChange(state: state, currentTime: player.position, duration: player.duration)])
    }

    /// El estado actual tal cual (aunque no haya cambiado).
    private func reportState(_ player: PlayerModel) {
        guard shouldReport, let videoId = player.item.videoId else { return }
        let state = Self.loungeState(player.status?.state)
        lastReported = (videoId, state)
        screenSend([.stateChange(state: state, currentTime: player.position, duration: player.duration)])
    }

    /// Terminó una búsqueda: la posición nueva.
    func playerDidSeek(_ player: PlayerModel) {
        guard shouldReport, player.item.videoId != nil else { return }
        let state = Self.loungeState(player.status?.state)
        screenSend([.stateChange(state: state, currentTime: player.position, duration: player.duration)])
    }

    func volumeDidChange() {
        guard shouldReport else { return }
        reportVolume()
    }

    func captionsDidChange() {
        guard shouldReport else { return }
        reportSubtitles()
    }

    /// Se cerró el reproductor: en el teléfono ya no suena nada.
    func playerDidClose() {
        guard shouldReport else { return }
        lastReported = nil
        screenSend([.nowPlaying(nil)])
    }

    private func log(_ message: String) {
        if Automation.shared.logsRemote { NSLog("Glasstube remoto: \(message)") }
    }
}
