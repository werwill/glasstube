import PlaybackKit
import SwiftUI
import YTKit

/// Ventana principal: `NavigationSplitView` con la barra lateral del sistema (panel de vidrio flotante en macOS 26),
/// la barra de herramientas de vidrio (atrás/adelante, búsqueda, recargar y cuenta) y el contenido opaco. Mientras
/// hay un video abierto, el reproductor ocupa la ventana encima de todo (la navegación queda debajo, intacta).
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(RemoteControl.self) private var remote
    @FocusState private var searchFocused: Bool
    /// Un enlace arrastrado está sobre la ventana.
    @ViewState private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            NavigationSplitView {
                Sidebar()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
            } detail: {
                DetailRouter(destination: model.navigator.current)
                    .id(model.navigator.current)
            }
            .navigationTitle(title)
            .toolbar(removing: .title)
            .toolbar { toolbarContent }
            .searchable(text: $model.searchText, placement: .toolbarPrincipal, prompt: "Buscar videos, canales y playlists")
            .searchFocused($searchFocused)
            .searchSuggestions {
                ForEach(model.suggestions, id: \.self) { suggestion in
                    Label(suggestion, systemImage: "magnifyingglass")
                        .searchCompletion(suggestion)
                }
            }
            .onSubmit(of: .search) { model.search(model.searchText) }
            .task(id: model.searchText) { await loadSuggestions(for: model.searchText) }
            .onChange(of: model.searchFocusRequest) { searchFocused = true }
            .onChange(of: searchFocused) { _, focused in model.searchFieldFocused = focused }
            .toolbarVisibility(playerCoversWindow ? .hidden : .automatic, for: .windowToolbar)
            .allowsHitTesting(!playerCoversWindow)
            .disabled(playerCoversWindow)
            .accessibilityHidden(playerCoversWindow)

            if let player = model.player {
                switch model.playerPresentation {
                case .full:
                    PlayerView(player: player)
                        .transition(.opacity)
                        .zIndex(1)
                case .pip:
                    // Mientras dura el PiP del sistema, la capa de AVPlayer sigue en la ventana (sin verse).
                    if let engine = player.engine {
                        PlayerVideoView(engine: engine, isActive: true)
                            .frame(width: 16, height: 9)
                            .opacity(0.01)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                case .mini:
                    // El video está en la ventana flotante (`MiniPlayerController`).
                    EmptyView()
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: playerCoversWindow)
        // Fase 4: soltar un enlace de YouTube (de Safari, Mensajes, Notas…) lo abre.
        .onDrop(of: DropTypes.accepted, isTargeted: $dropTargeted) { model.openDropped($0) }
        .overlay {
            if dropTargeted {
                Label("Suelta el enlace para abrirlo en Glasstube", systemImage: "link")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .glassEffect(.regular, in: .capsule)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.2), value: dropTargeted)
        .sheet(isPresented: signInPresented) { SignInSheet() }
        .sheet(isPresented: pairingPresented) { PairingSheet() }
        .sheet(item: $model.playlistPicker) { PlaylistPickerSheet(item: $0) }
        .modifier(GroupDialogs(model: model))
        .overlay(alignment: .bottom) {
            // Aviso breve de una acción de cuenta: una cápsula de vidrio sobre el contenido (capa de controles).
            if let banner = model.banner ?? model.accounts.notice ?? (model.accounts.waitingForKeychain ? Self.keychainHint : nil) {
                Text(banner)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { model.accounts.notice = nil }
                    .task(id: model.accounts.notice) {
                        guard model.accounts.notice != nil else { return }
                        try? await Task.sleep(for: .seconds(5))
                        model.accounts.notice = nil
                    }
            }
        }
        .animation(.smooth, value: model.banner ?? model.accounts.notice ?? (model.accounts.waitingForKeychain ? Self.keychainHint : nil))
        .overlay(alignment: .bottomTrailing) {
            // Versión nueva en GitHub: abajo a la derecha, fuera del camino; con el reproductor en la ventana espera a que
            // se cierre.
            if let update = model.updates.available, !playerCoversWindow {
                UpdateNotice(update: update)
                    .padding([.trailing, .bottom], 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: model.updates.available)
        // Al cambiar de cuenta (o iniciar y cerrar sesión), las páginas se vuelven a pedir con la cuenta nueva.
        .onChange(of: model.accounts.generation) { model.reload() }
        .onAppear { settings.applyAppearance() }
        .background(WindowAccessor { Automation.shared.windowDidAppear($0) })
    }

    static let keychainHint = "macOS pide permiso para leer tu sesión de YouTube: busca el aviso «Glasstube quiere usar información confidencial…» y elige «Permitir siempre». Mientras tanto, todo sale sin cuenta."

    /// El reproductor ocupa la ventana (no en el minirreproductor ni en el PiP).
    private var playerCoversWindow: Bool { model.player != nil && model.playerPresentation == .full }

    private var pairingPresented: Binding<Bool> {
        Binding(get: { remote.pairing != nil }, set: { if !$0 { remote.closePairing() } })
    }

    private var signInPresented: Binding<Bool> {
        Binding(get: { model.accounts.signIn != nil }, set: { if !$0 { model.accounts.cancelSignIn() } })
    }

    private var title: String {
        switch model.navigator.current {
        case .section(let item): item.title
        case .search(let query, _): query
        case .channelGroup(let id): model.groups.group(id)?.title ?? "Grupo"
        case .channel(_, let title): title ?? "Canal"
        case .playlist(_, let title): title ?? "Playlist"
        case .group(let group): group.title ?? "Fila"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.navigator.goBack() } label: {
                Label("Atrás", systemImage: "chevron.backward")
            }
            .disabled(!model.navigator.canGoBack)
            .help("Atrás (⌘[)")
            Button { model.navigator.goForward() } label: {
                Label("Adelante", systemImage: "chevron.forward")
            }
            .disabled(!model.navigator.canGoForward)
            .help("Adelante (⌘])")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.reload() } label: {
                Label("Recargar", systemImage: "arrow.clockwise")
            }
            .help("Recargar (⌘R)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            AccountMenu()
        }
    }

    /// Sugerencias de YTKit mientras se escribe (con una pausa para no pedir en cada tecla).
    private func loadSuggestions(for text: String) async {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            model.suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        let found = (try? await model.service.searchSuggestions(query)) ?? []
        guard !Task.isCancelled else { return }
        model.suggestions = Array(found.prefix(10))
    }
}

/// Elige la vista de la columna de contenido según el destino.
struct DetailRouter: View {
    let destination: Destination
    @Environment(AppModel.self) private var model

    var body: some View {
        switch destination {
        case .section(.home):
            HomeView()
        case .section(.history):
            HistoryView()
        case .section(.subscriptions):
            SubscriptionsView()
        case .section(.playlists):
            PlaylistsView()
        case .section(.shorts):
            BrowseView(source: .shorts)
        case .section(let item):
            if let topic = item.topic {
                BrowseView(source: .topic(topic, title: item.title))
            }
        case .search(let query, let filter):
            BrowseView(source: .search(query, filter), accessory: AnyView(SearchFilterMenu(filter: filter) { newFilter in
                model.navigator.replace(.search(query, newFilter))
            }))
        case .channelGroup(let id):
            ChannelFeedView(source: .group(id))
        case .channel(let id, let title):
            ChannelView(channelId: id, fallbackTitle: title)
        case .playlist(let id, let title):
            BrowseView(source: .playlist(id, title: title))
        case .group(let group):
            BrowseView(source: .group(group))
        }
    }
}

/// Da acceso a la `NSWindow` que contiene la vista (para pantalla completa y las capturas automáticas).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
