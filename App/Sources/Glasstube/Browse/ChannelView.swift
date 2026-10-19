import SwiftUI
import YTKit

/// Canal: cabecera (banner, avatar, nombre, suscriptores) y sus pestañas (Inicio, Videos, Shorts, En vivo,
/// Playlists…), cada una paginada con `continueGroup`.
struct ChannelView: View {
    let channelId: String
    let fallbackTitle: String?

    @Environment(AppModel.self) private var model
    @Environment(LocalLibrary.self) private var library
    @Environment(AccountModel.self) private var accounts
    @ViewState private var page: ChannelPage?
    /// Con cuenta: suscripción al canal (nil mientras no se sabe).
    @ViewState private var subscribed: Bool?
    @ViewState private var subscribeParams: String?
    @ViewState private var tab: ChannelTab.Kind = .home
    @ViewState private var failure: String?
    @ViewState private var loadingMore = false
    @ViewState private var width: CGFloat = 1100
    @ViewState private var grid = GridFocus()
    @FocusState private var gridFocused: Bool

    /// Pestañas que se pueden navegar (Publicaciones y Tienda no traen videos).
    private static let navigable: Set<ChannelTab.Kind> = [.home, .videos, .shorts, .live, .playlists, .releases, .podcasts, .courses, .shows]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let page, tabs(of: page).count > 1 {
                    Picker("Pestaña del canal", selection: tabBinding) {
                        ForEach(tabs(of: page), id: \.kind) { tab in
                            Text(tab.title).tag(tab.kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                content
            }
            .padding(.horizontal, GridMetrics.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - GridMetrics.pagePadding * 2 } action: { width = $0 }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .modifier(GridKeyboardNavigation(sections: groups.map { ($0.items, columns(for: $0.items)) }, grid: grid, isFocused: $gridFocused) { model.open($0) })
        .task(id: TaskKey(tab: tab, reload: model.reloadToken)) { await load() }
    }

    private struct TaskKey: Hashable {
        var tab: ChannelTab.Kind
        var reload: Int
    }

    private var tabBinding: Binding<ChannelTab.Kind> {
        Binding(get: { tab }, set: { newValue in
            guard newValue != tab else { return }
            tab = newValue
        })
    }

    private func tabs(of page: ChannelPage) -> [ChannelTab] {
        page.tabs.filter { Self.navigable.contains($0.kind) }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let banner = page?.banner, !banner.isEmpty {
                RemoteImage(urls: MediaItemImages.urls(banner, width: 2048))
                    .aspectRatio(6.2, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: thumbnailRadius))
                    .accessibilityHidden(true)
            }
            HStack(spacing: 18) {
                RemoteImage(urls: MediaItemImages.avatar(page?.avatar ?? []))
                    .frame(width: 96, height: 96)
                    .clipShape(.circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(page?.title ?? fallbackTitle ?? "Canal")
                        .font(.system(size: 30, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text([page?.handle, page?.subscriberCountText, page?.videoCountText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    if let description = page?.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: 640, alignment: .leading)
                    }
                }
                Spacer()
                if accounts.isSignedIn {
                    Group {
                        if subscribed == true {
                            Button("Suscrito", systemImage: "checkmark") { toggleSubscription() }
                                .buttonStyle(.glass)
                        } else {
                            Button("Suscribirse") { toggleSubscription() }
                                .buttonStyle(.glassProminent)
                        }
                    }
                    .controlSize(.large)
                    .disabled(subscribed == nil)
                    .help(subscribed == true ? "Cancelar la suscripción" : "Suscribirse con tu cuenta")
                    .task(id: TaskKey(tab: .home, reload: model.reloadToken)) { await loadSubscription() }
                } else {
                    Button("Suscribirse") { accounts.beginSignIn() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .help("Inicia sesión para suscribirte")
                }
            }
        }
    }

    private func loadSubscription() async {
        guard let state = try? await model.service.subscriptionState(channelId: channelId) else { return }
        subscribed = state.isSubscribed
        subscribeParams = state.params
    }

    /// Optimista: cambia de inmediato y vuelve si YouTube no lo acepta.
    private func toggleSubscription() {
        guard let current = subscribed else { return }
        let id = page?.channelId ?? channelId
        subscribed = !current
        let params = subscribeParams
        let name = page?.title ?? fallbackTitle ?? "el canal"
        Task {
            do {
                if current {
                    try await model.service.unsubscribe(channelId: id)
                } else {
                    try await model.service.subscribe(channelId: id, params: params)
                }
                model.show(banner: current ? "Cancelaste la suscripción a \(name)" : "Te suscribiste a \(name)")
            } catch {
                subscribed = current
                model.show(banner: "YouTube no aceptó el cambio: \(AccountModel.describe(error))")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if page != nil {
            if groups.isEmpty {
                ContentUnavailableView("Esta pestaña está vacía", systemImage: "rectangle.on.rectangle.slash")
                    .frame(minHeight: 240)
            }
            ForEach(groups.indices, id: \.self) { index in
                CardSection(title: groups[index].title, items: groups[index].items, section: index, grid: grid,
                            shortsAsGrid: tab == .shorts)
                if index == groups.count - 1, groups[index].continuation != nil || page?.content.continuation != nil {
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
        return page.content.groups.compactMap { group in
            var group = group
            group.items = library.visible(group.items)
            return group.items.isEmpty ? nil : group
        }
    }

    private func columns(for items: [MediaItem]) -> Int {
        guard items.allSatisfy(\.isShort) else { return GridMetrics.columns(for: width) }
        return tab == .shorts ? GridMetrics.columns(for: width, minimum: GridMetrics.shortWidth) : items.count
    }

    private func load() async {
        failure = nil
        do {
            let loaded = try await model.service.channel(channelId, tab: tab)
            withAnimation(.smooth) { page = loaded }
            if let name = loaded.title {
                // Spotlight: el canal abierto (fase 4).
                model.spotlight.index(channel: loaded.channelId, name: name, avatar: loaded.avatar,
                                      detail: loaded.subscriberCountText ?? loaded.handle)
            }
            if let selected = loaded.selectedTab, selected != tab, tab == .home { tab = selected }
            if !model.searchFieldFocused {
                try? await Task.sleep(for: .milliseconds(100))
                model.focusContent()
            }
        } catch where error.isCancellation {
        } catch {
            failure = "\(error)"
        }
    }

    private func loadMore() async {
        guard !loadingMore, var current = page else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            if let index = current.content.groups.lastIndex(where: { $0.continuation != nil }) {
                let more = try await model.service.continueGroup(current.content.groups[index])
                current.content.groups[index].items += more.items
                current.content.groups[index].continuation = more.items.isEmpty ? nil : more.continuation
            } else if let continuation = current.content.continuation {
                let more = try await model.service.continuePage(continuation)
                current.content.groups += more.groups
                current.content.continuation = more.groups.isEmpty ? nil : more.continuation
            }
        } catch {
            if let index = current.content.groups.lastIndex(where: { $0.continuation != nil }) {
                current.content.groups[index].continuation = nil
            } else {
                current.content.continuation = nil
            }
        }
        page = current
    }
}

/// De dónde salen Historial y Playlists cuando hay sesión.
enum LibraryScope: String, CaseIterable, Identifiable {
    case youtube, mac
    var id: String { rawValue }
    var title: String { self == .youtube ? "YouTube" : "Esta Mac" }
}

/// Selector YouTube / Esta Mac junto al título.
struct LibraryScopePicker: View {
    @Binding var scope: LibraryScope

    var body: some View {
        Picker("Origen", selection: $scope) {
            ForEach(LibraryScope.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// Historial: con sesión, el de la cuenta de YouTube (FEhistory, agrupado por día); siempre, el de esta Mac.
struct HistoryView: View {
    @Environment(AccountModel.self) private var accounts
    @AppStorage("historyScope") private var scope = LibraryScope.youtube

    var body: some View {
        if accounts.isSignedIn && scope == .youtube {
            BrowseView(source: .history, accessory: AnyView(LibraryScopePicker(scope: $scope)))
        } else {
            LocalHistoryView(scope: accounts.isSignedIn ? $scope : nil)
        }
    }
}

/// Historial local: lo reproducido en esta Mac, con su progreso.
struct LocalHistoryView: View {
    var scope: Binding<LibraryScope>?
    @Environment(AppModel.self) private var model
    @Environment(LocalLibrary.self) private var library
    @ViewState private var width: CGFloat = 1100
    @ViewState private var confirmClear = false
    @ViewState private var grid = GridFocus()
    @FocusState private var gridFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    PageHeader(title: "Historial", subtitle: scope == nil
                               ? "Lo que has visto en esta Mac. Inicia sesión para ver también el historial de tu cuenta de YouTube."
                               : "Lo que has visto en esta Mac.")
                    if !library.history.isEmpty {
                        Button("Borrar historial…", role: .destructive) { confirmClear = true }
                    }
                    if let scope { LibraryScopePicker(scope: scope) }
                }
                if library.history.isEmpty {
                    ContentUnavailableView("Todavía no has visto nada", systemImage: "clock",
                                           description: Text("Los videos que reproduzcas aparecerán aquí con su progreso."))
                        .frame(minHeight: 300)
                } else {
                    CardSection(title: nil, items: library.history.map(\.item), section: 0, grid: grid,
                                progress: { library.progress(for: $0.videoId) })
                }
            }
            .padding(.horizontal, GridMetrics.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - GridMetrics.pagePadding * 2 } action: { width = $0 }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .modifier(GridKeyboardNavigation(sections: [(library.history.map(\.item), GridMetrics.columns(for: width))], grid: grid, isFocused: $gridFocused) { model.open($0) })
        .confirmationDialog("¿Borrar el historial de esta Mac?", isPresented: $confirmClear) {
            Button("Borrar historial", role: .destructive) { library.clearHistory() }
        }
    }
}

/// Playlists: con sesión, las de la cuenta (FEplaylist_aggregation: propias, guardadas, Ver más tarde y Me gusta);
/// siempre, "Ver más tarde" de esta Mac.
struct PlaylistsView: View {
    @Environment(AccountModel.self) private var accounts
    @AppStorage("playlistsScope") private var scope = LibraryScope.youtube

    var body: some View {
        if accounts.isSignedIn && scope == .youtube {
            BrowseView(source: .library, accessory: AnyView(LibraryScopePicker(scope: $scope)))
        } else {
            LocalPlaylistsView(scope: accounts.isSignedIn ? $scope : nil)
        }
    }
}

/// "Ver más tarde" de esta Mac.
struct LocalPlaylistsView: View {
    var scope: Binding<LibraryScope>?
    @Environment(AppModel.self) private var model
    @Environment(LocalLibrary.self) private var library
    @ViewState private var width: CGFloat = 1100
    @ViewState private var grid = GridFocus()
    @FocusState private var gridFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    PageHeader(title: "Playlists")
                    if let scope { LibraryScopePicker(scope: scope) }
                }
                CardSection(title: "Ver más tarde · en esta Mac", items: library.watchLater.map(\.item), section: 0, grid: grid)
                if library.watchLater.isEmpty {
                    Text("Usa «Ver más tarde» en el banner o en el menú de un video para guardarlo aquí.")
                        .foregroundStyle(.secondary)
                }
                if scope == nil {
                    SignInNotice(what: "Tus playlists de YouTube", symbol: "list.and.film")
                }
            }
            .padding(.horizontal, GridMetrics.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - GridMetrics.pagePadding * 2 } action: { width = $0 }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .modifier(GridKeyboardNavigation(sections: [(library.watchLater.map(\.item), GridMetrics.columns(for: width))], grid: grid, isFocused: $gridFocused) { model.open($0) })
    }
}

/// Suscripciones: los videos nuevos de los canales a los que está suscrita la cuenta.
struct SubscriptionsView: View {
    @Environment(AccountModel.self) private var accounts

    var body: some View {
        if accounts.isSignedIn {
            BrowseView(source: .subscriptions)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    PageHeader(title: "Suscripciones")
                    SignInNotice(what: "Las suscripciones", symbol: "play.rectangle.on.rectangle")
                }
                .padding(.horizontal, GridMetrics.pagePadding)
                .padding(.top, 8)
            }
        }
    }
}

/// Aviso de sección que requiere cuenta (nunca una sección vacía sin explicación).
struct SignInNotice: View {
    let what: String
    let symbol: String
    @Environment(AccountModel.self) private var accounts

    var body: some View {
        ContentUnavailableView {
            Label("\(what) requieren iniciar sesión", systemImage: symbol)
        } description: {
            Text("Inicia sesión con un código, como en la app de YouTube para TV. Mientras tanto, el historial y «Ver más tarde» se guardan en esta Mac.")
        } actions: {
            Button("Iniciar sesión con un código…") { accounts.beginSignIn() }
                .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}
