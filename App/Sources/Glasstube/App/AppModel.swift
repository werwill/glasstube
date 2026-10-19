import AppKit
import Foundation
import Observation
import PlaybackKit
import YTKit

/// Secciones fijas de la barra lateral (el `SidebarService` de SmartTube).
enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home, subscriptions, history, playlists, shorts
    case music, gaming, news, live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Inicio"
        case .subscriptions: "Suscripciones"
        case .history: "Historial"
        case .playlists: "Playlists"
        case .shorts: "Shorts"
        case .music: "Música"
        case .gaming: "Gaming"
        case .news: "Noticias"
        case .live: "En vivo"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .subscriptions: "play.rectangle.on.rectangle"
        case .history: "clock.arrow.circlepath"
        case .playlists: "list.and.film"
        case .shorts: "play.square.stack"
        case .music: "music.note"
        case .gaming: "gamecontroller"
        case .news: "newspaper"
        case .live: "dot.radiowaves.left.and.right"
        }
    }

    var topic: Topic? {
        switch self {
        case .music: .music
        case .gaming: .gaming
        case .news: .news
        case .live: .live
        default: nil
        }
    }

    static let library: [SidebarItem] = [.home, .subscriptions, .history, .playlists, .shorts]
    static let explore: [SidebarItem] = [.music, .gaming, .news, .live]
}

/// Lo que muestra la columna de contenido.
enum Destination: Hashable {
    case section(SidebarItem)
    case search(String)
    case channel(id: String, title: String?)
    case playlist(id: String, title: String?)
    /// "Ver todo" de una fila: la fila con su continuación.
    case group(MediaGroup)

    var sidebarItem: SidebarItem? {
        if case .section(let item) = self { return item }
        return nil
    }
}

/// Historial de navegación con atrás y adelante (NavigationStack no tiene "adelante").
@Observable
final class Navigator {
    private(set) var current: Destination = .section(.home)
    private(set) var backStack: [Destination] = []
    private(set) var forwardStack: [Destination] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func go(_ destination: Destination) {
        guard destination != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = destination
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
    }
}

/// Cómo se ve el reproductor abierto: en la ventana, en el minirreproductor flotante (mpv) o en el PiP del sistema
/// (AVPlayer, directos).
enum PlayerPresentation: Equatable {
    case full, mini, pip
}

/// La lista desde la que se abrió un video (una playlist): el resto pasa a la cola.
struct PlayContext {
    var title: String?
    var items: [MediaItem]
}

/// Estado de la app: servicios compartidos, navegación, búsqueda y el reproductor abierto.
///
/// Un solo `PoTokenWebViewProvider` (un WKWebView de BotGuard) y un solo `ClientCatalog` para el catálogo
/// (`YouTubeService`) y el reproductor (`SabrMediaSource`).
@Observable
final class AppModel {
    let catalog: ClientCatalog
    let poToken: PoTokenWebViewProvider
    let service: YouTubeService
    let accounts: AccountModel
    let extras: PlayerExtrasService
    let sponsorBlock = SponsorBlockClient()
    let settings = AppSettings()
    let library = LocalLibrary()
    let navigator = Navigator()
    let queue = PlayQueue()
    let deArrow: DeArrowStore
    /// Control remoto desde el teléfono (Lounge) y Spotlight (fase 4).
    @ObservationIgnored private(set) var remote: RemoteControl!
    @ObservationIgnored let spotlight: SpotlightIndex
    /// Aviso de versiones nuevas publicadas en GitHub.
    let updates: UpdateChecker
    /// Volumen del reproductor (0…1); se conserva de un video al siguiente (el teléfono lo cambia aunque no haya video).
    @ObservationIgnored private(set) var volume: Double = 1

    /// El modelo de la app, para lo que llega de macOS al delegado (URL, Spotlight, Dock, Servicios).
    @ObservationIgnored nonisolated(unsafe) static weak var current: AppModel?

    /// El reproductor ocupa la ventana mientras no es nil (y `playerPresentation` es `.full`).
    var player: PlayerModel?
    private(set) var playerPresentation = PlayerPresentation.full
    @ObservationIgnored let miniPlayer = MiniPlayerController()
    /// Video para la hoja "Guardar en una playlist" (con cuenta).
    var playlistPicker: MediaItem?
    /// Aviso breve de una acción de cuenta ("Se agregó a Ver más tarde").
    private(set) var banner: String?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    var searchText = ""
    var suggestions: [String] = []
    /// Sube con "Recargar" (⌘R): las vistas que lo leen vuelven a pedir su página.
    private(set) var reloadToken = 0
    /// Pide el foco del campo de búsqueda (⌘K).
    private(set) var searchFocusRequest = 0
    /// Piden el foco de la barra lateral o del contenido (navegación con flechas entre las dos columnas).
    private(set) var sidebarFocusRequest = 0
    private(set) var contentFocusRequest = 0
    /// El último pedido de foco al contenido vino del teclado (se muestra el anillo de foco desde ya).
    private(set) var contentFocusFromKeyboard = false
    /// El campo de búsqueda tiene el foco (el contenido no se lo quita al cargar).
    var searchFieldFocused = false

    init() {
        // `-GTVerbose`: el registro de red de YTKit (host, ruta, estado y tamaño; nunca tokens) en stderr.
        if UserDefaults.standard.bool(forKey: "GTVerbose") { Log.verbose = true }
        do {
            catalog = try ClientCatalog.load()
        } catch {
            fatalError("No se pudo leer clients.json de YTKit: \(error)")
        }
        poToken = PoTokenWebViewProvider(catalog: catalog)
        do {
            // Sesiones de YouTube en el Llavero (`mx.glasstube.cuentas`); el catálogo va con la cuenta elegida.
            // `-GTSinLlavero`: pruebas automáticas sin leer el Llavero (sin sesión y sin el aviso de permiso del sistema).
            // `-GTLlaveroLento N`: lo mismo, pero la lectura tarda N s (prueba del aviso del Llavero sin responder).
            let defaults = UserDefaults.standard
            let slowKeychain = defaults.double(forKey: "GTLlaveroLento")
            let session = try AccountManager(catalog: catalog, ephemeral: defaults.bool(forKey: "GTSinLlavero") || slowKeychain > 0,
                                             simulatedReadDelay: slowKeychain)
            accounts = AccountModel(manager: session)
            service = try YouTubeService(catalog: catalog, poTokenSource: poToken, session: session)
        } catch {
            fatalError("No se pudo crear YouTubeService: \(error)")
        }
        extras = PlayerExtrasService(catalog: catalog)
        deArrow = DeArrowStore(settings: settings)
        spotlight = SpotlightIndex(settings: settings)
        updates = UpdateChecker(settings: settings)
        settings.applyAppearance()
        accounts.start()
        remote = RemoteControl(app: self)
        Self.current = self
        Automation.shared.attach(to: self)
    }

    /// Ya corre el bucle de la app: se busca una versión nueva si toca y el control remoto se conecta si estaba activado
    /// (como SmartTube, un poco después del arranque para no competir con la primera página).
    func didFinishLaunching() {
        updates.checkIfDue()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            remote.startIfEnabled()
        }
    }

    /// Volumen actual: el último que se puso (el estado del motor lo confirma un instante después, y reportarlo daba al
    /// teléfono el valor viejo antes del nuevo).
    var currentVolume: Double { volume }

    /// Cambia el volumen del reproductor (y el de los videos siguientes).
    func setVolume(_ value: Double) {
        volume = max(0, min(1, value))
        player?.setVolume(volume)
    }

    /// Lo recuerda para el próximo video (lo llama el reproductor al mover el control de volumen).
    func rememberVolume(_ value: Double) {
        volume = max(0, min(1, value))
    }

    func reload() { reloadToken += 1 }

    /// Acción de cuenta en segundo plano con aviso al terminar (o el error).
    func accountAction(_ success: String?, _ work: @escaping (YouTubeService) async throws -> Void) {
        let service = service
        Task {
            do {
                try await work(service)
                if let success { show(banner: success) }
            } catch {
                show(banner: "YouTube no aceptó el cambio: \(AccountModel.describe(error))")
            }
        }
    }

    func show(banner text: String, seconds: Double = 2.5) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func focusSidebar() { sidebarFocusRequest += 1 }

    /// Pide el foco del contenido. `fromKeyboard`: lo pidió una tecla (→ desde la barra lateral, Retorno al buscar), así
    /// que el anillo de foco se ve de inmediato; al cargar una página, el foco entra sin anillo hasta la primera tecla.
    func focusContent(fromKeyboard: Bool = false) {
        contentFocusFromKeyboard = fromKeyboard
        contentFocusRequest += 1
    }

    func focusSearch() {
        if player != nil { closePlayer() }
        searchFocusRequest += 1
    }

    func search(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Un enlace de YouTube pegado en la búsqueda se abre en lugar de buscarse.
        if text.contains("://") || text.contains("youtu"), let link = YouTubeLink.parse(text), link != .search(text) {
            searchText = ""
            open(link, from: "búsqueda")
            return
        }
        searchText = text
        navigator.go(.search(text))
    }

    func open(_ item: MediaItem, context: PlayContext? = nil) {
        switch item.kind {
        case .video:
            play(item, context: context)
        case .channel:
            if let channelId = item.channelId { navigator.go(.channel(id: channelId, title: item.title)) }
        case .playlist, .mix:
            if let playlistId = item.playlistId {
                if item.kind == .mix, item.videoId != nil {
                    play(item)
                } else {
                    navigator.go(.playlist(id: playlistId, title: item.title))
                }
            }
        }
    }

    func openChannel(of item: MediaItem) {
        guard let channelId = item.channelId else { return }
        if player != nil { closePlayer() }
        navigator.go(.channel(id: channelId, title: item.author))
    }

    /// Abre un video en el reproductor (si estaba en el minirreproductor, vuelve a la ventana). Desde una playlist
    /// (`context`), el resto de la lista pasa a la cola.
    func play(_ item: MediaItem, startAt: Double? = nil, context: PlayContext? = nil) {
        guard item.videoId != nil else { return }
        if let context { queue.load(playlist: context.items, after: item, title: context.title) }
        queue.remove(item)
        if let player {
            if playerPresentation != .full { expandPlayer() }
            player.replace(with: item, startAt: startAt)
            return
        }
        let player = PlayerModel(item: item, app: self, startAt: startAt)
        self.player = player
        player.start()
    }

    /// «Reproducir a continuación» (`next`) o «Agregar a la cola». Sin nada abierto, empieza a reproducir.
    func enqueue(_ item: MediaItem, next: Bool) {
        guard item.isPlayable else { return }
        guard player != nil else {
            play(item)
            return
        }
        if next { queue.playNext(item) } else { queue.append(item) }
        let title = deArrow.title(for: item)
        let message = next ? "A continuación: \(title)" : "Se agregó a la cola (\(queue.items.count))"
        if playerPresentation == .full, let player { player.showToast(message) } else { show(banner: message) }
    }

    func closePlayer() {
        guard let player else { return }
        miniPlayer.close()
        playerPresentation = .full
        self.player = nil
        player.close()
        remote.playerDidClose()
        focusContent()
    }

    // MARK: - Minirreproductor y PiP

    /// Pasa el video a una ventana pequeña siempre visible (mpv) o, en un directo con AVPlayer, al PiP del sistema. La
    /// ventana principal vuelve a la navegación mientras tanto.
    func enterMiniPlayer() {
        guard let player, playerPresentation == .full else { return }
        if player.isFullScreen { player.toggleFullScreen() }
        player.popover = nil
        if let engine = player.engine as? AVEngine, miniPlayer.startPictureInPicture(engine: engine, app: self) {
            playerPresentation = .pip
        } else {
            playerPresentation = .mini
            miniPlayer.show(player: player, app: self)
        }
        focusContent()
    }

    /// Vuelve del minirreproductor (o del PiP) al reproductor de la ventana.
    func expandPlayer() {
        guard player != nil, playerPresentation != .full else { return }
        miniPlayer.close()
        playerPresentation = .full
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Glasstube" }?.makeKeyAndOrderFront(nil)
    }

    func toggleMiniPlayer() {
        if playerPresentation == .full { enterMiniPlayer() } else { expandPlayer() }
    }

    /// Para compartir: el enlace público de YouTube del elemento.
    static func webURL(for item: MediaItem) -> URL? {
        switch item.kind {
        case .video:
            item.videoId.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") }
        case .channel:
            item.channelId.flatMap { URL(string: "https://www.youtube.com/channel/\($0)") }
        case .playlist, .mix:
            item.playlistId.flatMap { URL(string: "https://www.youtube.com/playlist?list=\($0)") }
        }
    }
}
