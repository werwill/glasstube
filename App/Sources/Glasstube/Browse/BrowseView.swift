import SwiftUI
import YTKit

/// Qué página de YTKit se muestra.
enum BrowseSource: Hashable {
    case topic(Topic, title: String)
    case search(String)
    case playlist(String, title: String?)
    /// "Ver todo" de una fila: la fila y su continuación.
    case group(MediaGroup)
    /// Shorts sin cuenta: YTKit aún no tiene el feed (`reel_watch_sequence`); se muestran los Shorts de una búsqueda.
    case shorts
    /// Con cuenta: Suscripciones (FEsubscriptions), Historial (FEhistory) y Playlists (FEplaylist_aggregation).
    case subscriptions, history, library

    var title: String {
        switch self {
        case .topic(_, let title): title
        case .search(let query): "Resultados para «\(query)»"
        case .playlist(_, let title): title ?? "Playlist"
        case .group(let group): group.title ?? "Más videos"
        case .shorts: "Shorts"
        case .subscriptions: "Suscripciones"
        case .history: "Historial"
        case .library: "Playlists"
        }
    }
}

/// Una página de filas: secciones con su título y paginación por `continuation` (más elementos de una fila con
/// `continueGroup` y más filas con `continuePage`) al llegar al final.
struct BrowseView: View {
    let source: BrowseSource
    /// Control junto al título (el selector YouTube / Esta Mac de Historial y Playlists).
    var accessory: AnyView?

    @Environment(AppModel.self) private var model
    @Environment(LocalLibrary.self) private var library
    @ViewState private var page: BrowsePage?
    @ViewState private var failure: String?
    @ViewState private var loadingMore = false
    @ViewState private var width: CGFloat = 1100
    @ViewState private var grid = GridFocus()
    @FocusState private var gridFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    PageHeader(title: headerTitle, subtitle: subtitle)
                    if let accessory { accessory }
                }
                content
            }
            .padding(.horizontal, GridMetrics.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - GridMetrics.pagePadding * 2 } action: { width = $0 }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .modifier(GridKeyboardNavigation(sections: groups.map { ($0.items, columns(for: $0.items)) }, grid: grid, isFocused: $gridFocused) { model.open($0, context: playContext) })
        .task(id: model.reloadToken) { await load() }
    }

    /// El título de la página (lista, fila) o el del destino (temas de Explorar y búsquedas).
    private var headerTitle: String {
        switch source {
        case .playlist, .group: page?.title ?? source.title
        default: source.title
        }
    }

    private var subtitle: String? {
        switch source {
        case .shorts: "Sin cuenta todavía no hay feed de Shorts: estos salen de una búsqueda."
        case .topic: page?.isFallback == true ? "Contenido sustituto de YouTube" : nil
        case .subscriptions, .history, .library: model.accounts.selected.map { "De tu cuenta de YouTube · \($0.displayName)" }
        default: nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if page != nil {
            if groups.isEmpty {
                ContentUnavailableView("Nada que mostrar", systemImage: "rectangle.on.rectangle.slash",
                                       description: Text(page?.notice ?? "YouTube no devolvió videos para esta página."))
                    .frame(minHeight: 300)
            }
            ForEach(groups.indices, id: \.self) { index in
                let group = groups[index]
                CardSection(title: groups.count > 1 || group.title != page?.title ? group.title : nil,
                            items: group.items, section: index, grid: grid, progress: accountProgress,
                            shortsAsGrid: source == .shorts)
                    .environment(\.playlistContext, playlistContext)
                    .environment(\.playContext, playContext)
                    .environment(\.feedbackLabel, feedbackLabel)
                if index == groups.count - 1, canLoadMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .onAppear { Task { await loadMore() } }
                }
            }
        } else if let failure {
            LoadStateView(state: .failed(failure)) { Task { await load() } }
        } else {
            LoadStateView(state: .loading)
        }
    }

    private var groups: [MediaGroup] {
        guard let page else { return [] }
        return page.groups.compactMap { group in
            var group = group
            group.items = library.visible(group.items)
            if source == .shorts { group.items = group.items.filter(\.isShort) }
            return group.items.isEmpty ? nil : group
        }
    }

    private func columns(for items: [MediaItem]) -> Int {
        guard items.allSatisfy(\.isShort) else { return GridMetrics.columns(for: width) }
        return source == .shorts ? GridMetrics.columns(for: width, minimum: GridMetrics.shortWidth) : items.count
    }

    /// La última fila con continuación, o la página.
    private var canLoadMore: Bool {
        guard let page else { return false }
        return page.groups.last(where: { $0.continuation != nil }) != nil || page.continuation != nil
    }

    private func load() async {
        failure = nil
        do {
            let loaded: BrowsePage
            switch source {
            case .topic(let topic, _):
                loaded = try await model.service.topic(topic)
            case .search(let query):
                loaded = try await model.service.search(query)
            case .playlist(let id, _):
                loaded = try await model.service.playlist(id)
            case .group(let group):
                loaded = BrowsePage(title: group.title, groups: [group], surface: group.continuation?.surface ?? .web)
            case .subscriptions:
                loaded = try await model.service.subscriptions()
            case .history:
                loaded = try await model.service.history()
            case .library:
                loaded = try await model.service.playlists()
            case .shorts:
                var result = try await model.service.search("#shorts")
                // Los Shorts de la búsqueda llegan en sus estantes: se juntan en una cuadrícula.
                let shorts = result.groups.flatMap(\.items).filter(\.isShort)
                result.groups = [MediaGroup(kind: .search, title: nil, items: shorts, renderer: "shorts")]
                result.continuation = nil
                loaded = result
            }
            withAnimation(.smooth) { page = loaded }
            // Capturas: la tarjeta N de la primera fila con la vista previa activa (`GTHoverIndex`).
            if let index = Automation.shared.hoverIndex, let first = groups.first, first.items.indices.contains(index) {
                Automation.shared.forcedHoverId = first.items[index].videoId
            }
            // Tras buscar (Retorno en el campo), el foco pasa al primer resultado; en las demás páginas, solo si el
            // campo de búsqueda no lo tiene.
            if source.isSearch || !model.searchFieldFocused {
                try? await Task.sleep(for: .milliseconds(100))
                model.focusContent(fromKeyboard: source.isSearch && model.searchFieldFocused)
            }
        } catch where error.isCancellation {
        } catch {
            if page == nil { failure = "\(error)" }
        }
    }

    private func loadMore() async {
        guard !loadingMore, var current = page else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            if let index = current.groups.lastIndex(where: { $0.continuation != nil }) {
                let more = try await model.service.continueGroup(current.groups[index])
                current.groups[index].items += more.items
                current.groups[index].continuation = more.items.isEmpty ? nil : more.continuation
            } else if let continuation = current.continuation {
                let more = try await model.service.continuePage(continuation)
                current.groups += more.groups
                current.continuation = more.groups.isEmpty ? nil : more.continuation
                // Suscripciones de TV llegan de tres en tres sin título: se suman a "Más recientes".
                if source == .subscriptions { current = current.mergingUntitledRows(title: "Más recientes") }
            }
            page = current
        } catch {
            // Sin más páginas: se quita la continuación para no reintentar en bucle.
            if let index = current.groups.lastIndex(where: { $0.continuation != nil }) {
                current.groups[index].continuation = nil
            } else {
                current.continuation = nil
            }
            page = current
        }
    }
}

extension BrowseSource {
    var isSearch: Bool {
        if case .search = self { return true }
        return false
    }
}

extension BrowseView {
    /// En las páginas de la cuenta, la barra roja es la de YouTube (lo visto en cualquier dispositivo); en las demás,
    /// la de esta Mac si la hay.
    fileprivate var accountProgress: (MediaItem) -> Double? {
        switch source {
        case .history, .subscriptions, .library, .playlist: { $0.percentWatched.map { Double($0) / 100 } }
        default: { _ in nil }
        }
    }

    /// Qué hace "No me interesa" en esta página con cuenta: el primer token del menú de YouTube es "Quitar del
    /// historial" en Historial y "Ocultar" en Suscripciones.
    fileprivate var feedbackLabel: String? {
        switch source {
        case .history: "Quitar del historial"
        case .subscriptions: "Ocultar"
        default: nil
        }
    }

    /// En una playlist, abrir un video pone el resto de la lista en la cola (`PlayQueue`).
    fileprivate var playContext: PlayContext? {
        guard case .playlist = source, let page else { return nil }
        return PlayContext(title: page.title ?? source.title, items: page.groups.flatMap(\.items))
    }

    /// La lista que se está viendo, para "Quitar de esta playlist" en el menú de las tarjetas (con cuenta).
    fileprivate var playlistContext: PlaylistContext? {
        guard case .playlist(let id, let title) = source, model.accounts.isSignedIn else { return nil }
        return PlaylistContext(id: id, title: page?.title ?? title) { videoId in
            guard var current = page else { return }
            for index in current.groups.indices { current.groups[index].items.removeAll { $0.videoId == videoId } }
            page = current
        }
    }
}

/// Lista abierta en la página (para quitar un video de ella desde el menú de su tarjeta).
struct PlaylistContext {
    let id: String
    let title: String?
    /// Quita la tarjeta de la página después de quitarla de la lista en YouTube.
    let removed: (String) -> Void
}

// Sin `@Entry` (macro sin plugin en las Command Line Tools): las claves de entorno a mano.
private struct PlaylistContextKey: EnvironmentKey {
    static let defaultValue: PlaylistContext? = nil
}

private struct FeedbackLabelKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct PlayContextKey: EnvironmentKey {
    static let defaultValue: PlayContext? = nil
}

extension EnvironmentValues {
    var playlistContext: PlaylistContext? {
        get { self[PlaylistContextKey.self] }
        set { self[PlaylistContextKey.self] = newValue }
    }

    /// La playlist abierta: al reproducir uno de sus videos, el resto pasa a la cola.
    var playContext: PlayContext? {
        get { self[PlayContextKey.self] }
        set { self[PlayContextKey.self] = newValue }
    }

    /// Nombre de "No me interesa" en la página (Historial: "Quitar del historial").
    var feedbackLabel: String? {
        get { self[FeedbackLabelKey.self] }
        set { self[FeedbackLabelKey.self] = newValue }
    }
}
