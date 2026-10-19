import SwiftUI

/// Barra lateral: la `List` del sistema dentro de `NavigationSplitView`, que macOS 26 dibuja como panel de vidrio
/// flotante. Secciones de la maqueta: biblioteca, Explorar, Mis grupos (marcador de posición) y Ajustes al pie.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountModel.self) private var accounts
    @Environment(\.openSettings) private var openSettings
    @FocusState private var listFocused: Bool

    var body: some View {
        List(selection: selection) {
            ForEach(SidebarItem.library) { item in
                row(item)
            }
            Section("Explorar") {
                ForEach(SidebarItem.explore) { item in
                    row(item)
                }
            }
            Section("Mis grupos") {
                Label("Grupos de canales", systemImage: "folder")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                    .help("Los grupos de canales llegan en la fase 5")
                Text("Llegan en la fase 5")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .focused($listFocused)
        .onChange(of: model.sidebarFocusRequest) { listFocused = true }
        // → vuelve al contenido, como la cruceta de SmartTube.
        .onKeyPress(.rightArrow) {
            model.focusContent(fromKeyboard: true)
            return .handled
        }
        .safeAreaInset(edge: .bottom) {
            Button { openSettings() } label: {
                Label("Ajustes", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .help("Ajustes (⌘,)")
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { model.navigator.current.sidebarItem },
            set: { item in if let item { model.navigator.go(.section(item)) } }
        )
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        Label {
            HStack {
                Text(item.title)
                if item == .subscriptions, !accounts.isSignedIn {
                    Spacer()
                    Image(systemName: "lock")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Requiere cuenta")
                }
            }
        } icon: {
            Image(systemName: item.symbol)
        }
        .tag(item)
        .help(help(for: item))
    }

    private func help(for item: SidebarItem) -> String {
        switch (item, accounts.isSignedIn) {
        case (.subscriptions, false): "Requiere iniciar sesión"
        case (.history, false): "Historial local de esta Mac"
        case (.playlists, false): "Ver más tarde (local); las playlists de YouTube requieren cuenta"
        case (.subscriptions, true): "Videos nuevos de tus suscripciones"
        case (.history, true): "Historial de tu cuenta de YouTube (y el de esta Mac)"
        case (.playlists, true): "Tus playlists de YouTube, Ver más tarde y Me gusta"
        default: item.title
        }
    }
}
