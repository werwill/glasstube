import AppKit
import Foundation
import GameController
import Observation
import YTKit

/// Una sección del menú del modo TV (las de la barra lateral, como los encabezados del Leanback de SmartTube).
enum TVSection: Hashable, Identifiable {
    case item(SidebarItem)
    /// Un grupo de canales (fase 5a).
    case group(String)

    var id: String {
        switch self {
        case .item(let item): item.rawValue
        case .group(let id): "grupo:\(id)"
        }
    }
}

/// Una fila de tarjetas (una `MediaGroup` de YTKit, con su continuación para pedir más al llegar al final).
struct TVRow: Identifiable, Equatable {
    var id: String
    var title: String
    var group: MediaGroup

    var items: [MediaItem] { group.items }
}

/// Una página de filas: la de una sección o, al abrir un canal o una playlist, la suya encima.
struct TVPage: Equatable {
    enum State: Equatable {
        case loading
        case loaded
        case empty(String)
        case failed(String)
    }

    var title: String
    var rows: [TVRow] = []
    var state = State.loading
    /// La tarjeta elegida de cada fila (cada fila recuerda la suya, como en Leanback).
    var columns: [Int: Int] = [:]
    var row = 0

    func column(of row: Int) -> Int {
        guard rows.indices.contains(row) else { return 0 }
        return min(columns[row] ?? 0, max(0, rows[row].items.count - 1))
    }
}

/// Dónde está el foco: en el menú de secciones o en una tarjeta de la página de arriba.
enum TVFocus: Equatable {
    case menu
    case content
}

/// El modo TV (fase 5b): una interfaz a pantalla completa para ver desde el sillón en una Mac conectada a la tele, con
/// filas de tarjetas grandes como el Leanback de SmartTube. Se maneja solo con flechas, Retorno y Esc, que llegan igual
/// del teclado, de un control de juego (`TVGameControllers` los convierte en esas teclas) y de la cruceta del teléfono
/// (control remoto de la fase 4, por `KeyInjector`).
@Observable
final class TVMode {
    private(set) var sections: [TVSection] = []
    /// La sección elegida en el menú.
    private(set) var selected = 0
    private(set) var focus = TVFocus.menu
    /// La página de la sección y, encima, las de los canales o playlists que se abrieron.
    private(set) var pages: [TVPage] = []
    /// Para el anillo de foco de VoiceOver y las pruebas: lo que se movió por última vez.
    private(set) var moves = 0

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var moreTask: Task<Void, Never>?
    /// Si al entrar la ventana no estaba en pantalla completa (al salir vuelve como estaba).
    @ObservationIgnored var enteredFullScreen = false
    @ObservationIgnored let controllers = TVGameControllers()

    init(app: AppModel?) {
        self.app = app
        sections = Self.sections(groups: app?.groups.groups ?? [])
    }

    static func sections(groups: [ChannelGroup]) -> [TVSection] {
        [.item(.home), .item(.subscriptions), .item(.history), .item(.shorts)]
            + SidebarItem.explore.map { .item($0) }
            + groups.map { .group($0.id) }
    }

    var page: TVPage? { pages.last }
    var section: TVSection? { sections.indices.contains(selected) ? sections[selected] : nil }

    /// La tarjeta con el foco.
    var focusedItem: MediaItem? {
        guard focus == .content, let page, page.rows.indices.contains(page.row) else { return nil }
        let items = page.rows[page.row].items
        let column = page.column(of: page.row)
        return items.indices.contains(column) ? items[column] : nil
    }

    func title(of section: TVSection) -> String {
        switch section {
        case .item(let item): item.title
        case .group(let id): app?.groups.group(id)?.title ?? String(localized: "Grupo")
        }
    }

    func symbol(of section: TVSection) -> String {
        switch section {
        case .item(let item): item.symbol
        case .group: "folder"
        }
    }

    // MARK: - Teclas

    enum Key: Equatable {
        case up, down, left, right, enter, back
    }

    /// Lo que hace cada tecla. Devuelve `false` si no hizo nada (para que el sistema la trate).
    @discardableResult
    func handle(_ key: Key) -> Bool {
        moves += 1
        switch focus {
        case .menu: return handleInMenu(key)
        case .content: return handleInContent(key)
        }
    }

    private func handleInMenu(_ key: Key) -> Bool {
        switch key {
        case .up:
            guard selected > 0 else { return false }
            select(selected - 1)
        case .down:
            guard selected + 1 < sections.count else { return false }
            select(selected + 1)
        case .right, .enter:
            guard let page, !page.rows.isEmpty else { return false }
            focus = .content
        case .left:
            return false
        case .back:
            app?.exitTVMode()
        }
        return true
    }

    private func handleInContent(_ key: Key) -> Bool {
        guard let page else { return false }
        let top = pages.count - 1
        let column = page.column(of: page.row)
        switch key {
        case .left:
            if column > 0 {
                pages[top].columns[page.row] = column - 1
            } else if top == 0 {
                // ← en la primera tarjeta de la sección: al menú (en un canal abierto no hay menú al lado).
                focus = .menu
            } else {
                return false
            }
        case .right:
            guard page.rows.indices.contains(page.row), column + 1 < page.rows[page.row].items.count else { return false }
            pages[top].columns[page.row] = column + 1
            if column + 1 >= page.rows[page.row].items.count - 4 { loadMore(row: page.row, depth: pages.count) }
        case .up:
            guard page.row > 0 else { return false }
            pages[top].row -= 1
        case .down:
            guard page.row + 1 < page.rows.count else { return false }
            pages[top].row += 1
        case .enter:
            guard let item = focusedItem else { return false }
            open(item)
        case .back:
            if top == 0 {
                focus = .menu
            } else {
                // Cierra el canal o la playlist que se abrió.
                pages.removeLast()
            }
        }
        return true
    }

    // MARK: - Secciones y páginas

    func start() {
        // `GTTVSeccion nombre|índice`: la sección con la que arranca (capturas y pruebas).
        if let wanted = UserDefaults.standard.string(forKey: "GTTVSeccion"),
           let index = Int(wanted).flatMap({ sections.indices.contains($0) ? $0 : nil })
            ?? sections.firstIndex(where: { title(of: $0) == wanted }) {
            selected = index
        }
        select(selected, immediately: true)
    }

    /// Elige una sección del menú: su página se pide enseguida (con una pausa corta si se recorre el menú rápido).
    func select(_ index: Int, immediately: Bool = false) {
        guard sections.indices.contains(index) else { return }
        selected = index
        let section = sections[index]
        pages = [TVPage(title: title(of: section))]
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, let self else { return }
            let page = await self.load(section)
            guard !Task.isCancelled, self.selected == index, self.pages.count == 1 else { return }
            self.pages = [page]
            if Automation.shared.logsTV { NSLog("Glasstube modo TV: \(page.title): \(page.rows.map { "\($0.title) (\($0.items.count))" }.joined(separator: ", ")) \(page.state)") }
        }
    }

    /// Un clic en una sección del menú (con el ratón).
    func click(section index: Int) {
        select(index, immediately: true)
        focus = .menu
    }

    /// Un clic en una tarjeta: el foco va ahí y se abre.
    func click(row: Int, column: Int) {
        guard var page = pages.popLast(), page.rows.indices.contains(row) else { return }
        page.row = row
        page.columns[row] = column
        pages.append(page)
        focus = .content
        handle(.enter)
    }

    private func open(_ item: MediaItem) {
        guard let app else { return }
        switch item.kind {
        case .video:
            app.play(item)
        case .mix where item.videoId != nil:
            app.play(item)
        case .channel:
            guard let channelId = item.channelId else { return }
            push(title: item.title) { app in
                let channel = try await app.service.channel(channelId)
                return channel.content.groups
            }
        case .playlist, .mix:
            guard let playlistId = item.playlistId else { return }
            push(title: item.title) { app in
                try await app.service.playlist(playlistId).groups
            }
        }
    }

    /// Abre un canal o una playlist como otra página de filas encima (Esc la cierra).
    private func push(title: String, load: @escaping (AppModel) async throws -> [MediaGroup]) {
        guard let app else { return }
        pages.append(TVPage(title: title))
        let depth = pages.count
        Task { [weak self] in
            var page = TVPage(title: title)
            do {
                page.rows = Self.rows(app.library.visible, try await load(app))
                page.state = page.rows.isEmpty ? .empty(String(localized: "No hay videos aquí.")) : .loaded
            } catch {
                page.state = .failed(Self.describe(error))
            }
            guard let self, self.pages.count == depth else { return }
            self.pages[depth - 1] = page
        }
    }

    /// Más tarjetas de una fila al acercarse a su final (`continueGroup`).
    private func loadMore(row: Int, depth: Int) {
        guard moreTask == nil, let app, pages.count == depth, let page = pages.last, page.rows.indices.contains(row),
              page.rows[row].group.continuation != nil else { return }
        let group = page.rows[row].group
        moreTask = Task { [weak self] in
            defer { self?.moreTask = nil }
            guard let more = try? await app.service.continueGroup(group), let self, self.pages.count == depth,
                  self.pages[depth - 1].rows.indices.contains(row) else { return }
            self.pages[depth - 1].rows[row].group.items += app.library.visible(more.items)
            self.pages[depth - 1].rows[row].group.continuation = more.items.isEmpty ? nil : more.continuation
        }
    }

    private func load(_ section: TVSection) async -> TVPage {
        var page = TVPage(title: title(of: section))
        guard let app else { return page }
        do {
            let visible = app.library.visible
            switch section {
            case .item(.home):
                let home = try await app.service.home()
                let continuing = visible(app.library.continueWatching.map(\.item))
                var groups = home.groups.map { group in
                    var group = group
                    group.items = group.items.filter { app.settings.showShortsOnHome || !$0.isShort }
                    return group
                }
                if !continuing.isEmpty {
                    groups.insert(MediaGroup(kind: .history, title: String(localized: "Seguir viendo"), items: continuing, renderer: "glasstube"), at: 0)
                }
                page.rows = Self.rows(visible, groups)
            case .item(.subscriptions):
                if app.accounts.isSignedIn {
                    page.rows = Self.rows(visible, try await app.service.subscriptions().localizingFixedTitles.mergingUntitledRows(title: String(localized: "Más recientes")).groups)
                } else {
                    page.rows = await Self.feedRows(app, channelIds: app.groups.subscriptions.map(\.id))
                    if app.groups.subscriptions.isEmpty {
                        page.state = .empty(String(localized: "Sin cuenta, usa «Suscribirse» en la página de un canal: sus videos nuevos llegan aquí."))
                        return page
                    }
                }
            case .item(.history):
                let history = visible(app.library.history.map(\.item))
                let continuing = visible(app.library.continueWatching.map(\.item))
                var groups: [MediaGroup] = []
                if !continuing.isEmpty { groups.append(MediaGroup(kind: .history, title: String(localized: "Seguir viendo"), items: continuing, renderer: "glasstube")) }
                if !history.isEmpty { groups.append(MediaGroup(kind: .history, title: String(localized: "Visto en esta Mac"), items: history, renderer: "glasstube")) }
                page.rows = Self.rows(visible, groups)
                if groups.isEmpty {
                    page.state = .empty(String(localized: "Todavía no has visto nada en esta Mac."))
                    return page
                }
            case .item(.shorts):
                let shorts = try await app.service.shorts()
                page.rows = Self.rows(visible, shorts.groups.map { group in
                    var group = group
                    group.items = group.items.filter(\.isShort)
                    return group
                })
            case .item(let item):
                if let topic = item.topic {
                    page.rows = Self.rows(visible, try await app.service.topic(topic).groups)
                }
            case .group(let id):
                let channels = app.groups.group(id)?.channels.map(\.id) ?? []
                page.rows = await Self.feedRows(app, channelIds: channels)
                if channels.isEmpty {
                    page.state = .empty(String(localized: "Este grupo no tiene canales todavía."))
                    return page
                }
            }
            page.state = page.rows.isEmpty ? .empty(String(localized: "YouTube no devolvió videos para esta sección.")) : .loaded
        } catch where error.isCancellation {
        } catch {
            page.state = .failed(Self.describe(error))
        }
        return page
    }

    /// El feed RSS de unos canales (suscripciones de esta Mac o un grupo): videos y, aparte, Shorts.
    private static func feedRows(_ app: AppModel, channelIds: [String]) async -> [TVRow] {
        guard !channelIds.isEmpty else { return [] }
        let feed = await app.service.rssFeed(channelIds: channelIds, refresh: false)
        var items = app.library.visible(feed.items)
        // Capturas: solo los videos elegidos (`GTSoloVideos`), como en el feed de la ventana.
        if let only = Automation.shared.onlyVideos { items = items.filter { $0.videoId.map(only.contains) ?? false } }
        var groups = [MediaGroup(kind: .subscriptions, title: String(localized: "Lo más nuevo"), items: items.filter { !$0.isShort }, renderer: "rss")]
        groups.append(MediaGroup(kind: .shorts, title: String(localized: "Shorts"), items: items.filter(\.isShort), renderer: "rss"))
        return rows({ $0 }, groups)
    }

    /// Filas sin lo oculto ni lo bloqueado y sin filas vacías.
    static func rows(_ visible: ([MediaItem]) -> [MediaItem], _ groups: [MediaGroup]) -> [TVRow] {
        groups.enumerated().compactMap { index, group in
            var group = group
            group.items = visible(group.items)
            guard !group.items.isEmpty else { return nil }
            return TVRow(id: "\(index)-\(group.title ?? "")", title: group.title ?? (index == 0 ? String(localized: "Destacado") : String(localized: "Más videos")), group: group)
        }
    }

    private static func describe(_ error: Error) -> String {
        String(localized: "No se pudo cargar: \(error.localizedDescription)")
    }

    /// Lo que se ve en pantalla, para la automatización y las pruebas.
    var summary: String {
        let where_ = focus == .menu ? "menú «\(section.map(title(of:)) ?? "?")»" : "tarjeta «\(focusedItem?.title ?? "?")» (fila \(page?.row ?? 0), columna \(page.map { $0.column(of: $0.row) } ?? 0))"
        return "\(where_), páginas \(pages.count)"
    }

    // MARK: - Pruebas

    /// Páginas ya cargadas y dónde está el foco (pruebas sin red).
    func setPagesForTesting(_ pages: [TVPage], focus: TVFocus = .content) {
        loadTask?.cancel()
        self.pages = pages
        self.focus = focus
    }
}

// MARK: - Controles de juego

/// Los controles de juego (GameController) como las teclas del modo TV: la cruceta y la palanca izquierda son las flechas
/// (con repetición si se dejan apretadas), A es Retorno, B y Menú son Esc, X pausa y los gatillos superiores L1/R1
/// retroceden y adelantan 10 s en el reproductor. Las teclas se mandan con `KeyInjector` a la ventana, así que funcionan
/// igual en el modo TV y en el reproductor que se abre desde él.
final class TVGameControllers {
    /// Las teclas de `KeyInjector` de cada botón.
    nonisolated static let buttons: [String: String] = [
        "a": "return", "b": "escape", "menu": "escape", "x": "space", "l1": "j", "r1": "l",
    ]
    /// Inclinación de la palanca a partir de la cual cuenta como una flecha.
    nonisolated static let threshold: Float = 0.55

    private var observers: [NSObjectProtocol] = []
    private var held: String?
    private var repeatTask: Task<Void, Never>?
    private(set) var connected: [String] = []
    var window: () -> NSWindow? = { NSApp.keyWindow }

    /// La flecha de una inclinación de la palanca (o nil en el centro). Gana el eje más inclinado.
    nonisolated static func arrow(x: Float, y: Float) -> String? {
        guard max(abs(x), abs(y)) >= threshold else { return nil }
        if abs(x) > abs(y) { return x > 0 ? "right" : "left" }
        return y > 0 ? "up" : "down"
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            // Al conectarse uno se vuelven a atar todos (atar dos veces el mismo no cambia nada).
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { GCController.controllers().forEach { self?.attach($0) } }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshNames() }
            },
        ]
        GCController.controllers().forEach(attach)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        repeatTask?.cancel()
        held = nil
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
            controller.microGamepad?.valueChangedHandler = nil
        }
    }

    private func refreshNames() {
        connected = GCController.controllers().map { $0.vendorName ?? String(localized: "Control") }
    }

    private func attach(_ controller: GCController) {
        refreshNames()
        if Automation.shared.logsTV { NSLog("Glasstube modo TV: control conectado: \(controller.vendorName ?? "?")") }
        if let pad = controller.extendedGamepad {
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in MainActor.assumeIsolated { self?.direction(x: x, y: y) } }
            pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in MainActor.assumeIsolated { self?.direction(x: x, y: y) } }
            bind(pad.buttonA, "a")
            bind(pad.buttonB, "b")
            bind(pad.buttonX, "x")
            bind(pad.buttonMenu, "menu")
            bind(pad.leftShoulder, "l1")
            bind(pad.rightShoulder, "r1")
        } else if let pad = controller.microGamepad {
            // Siri Remote y controles sencillos.
            pad.reportsAbsoluteDpadValues = false
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in MainActor.assumeIsolated { self?.direction(x: x, y: y) } }
            bind(pad.buttonA, "a")
            bind(pad.buttonX, "x")
            bind(pad.buttonMenu, "menu")
        }
    }

    private func bind(_ button: GCControllerButtonInput, _ name: String) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard pressed, let key = Self.buttons[name] else { return }
                self?.press(key)
            }
        }
    }

    /// Una flecha al inclinar y, si se mantiene, se repite (0,4 s y luego cada 0,13 s).
    private func direction(x: Float, y: Float) {
        let arrow = Self.arrow(x: x, y: y)
        guard arrow != held else { return }
        held = arrow
        repeatTask?.cancel()
        guard let arrow else { return }
        press(arrow)
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                self?.press(arrow)
                try? await Task.sleep(for: .milliseconds(130))
            }
        }
    }

    private func press(_ key: String) {
        guard NSApp.isActive else { return }
        if Automation.shared.logsTV { NSLog("Glasstube modo TV: control → \(key)") }
        KeyInjector.press(key, in: window())
    }
}
