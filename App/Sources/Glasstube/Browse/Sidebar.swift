import SwiftUI

/// Barra lateral: la `List` del sistema dentro de `NavigationSplitView`, que macOS 26 dibuja como panel de vidrio
/// flotante. Secciones de la maqueta: biblioteca, Explorar, Mis grupos (los grupos de canales, fase 5a) y Ajustes al pie.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountModel.self) private var accounts
    @Environment(ChannelGroupStore.self) private var groups
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
            Section {
                ForEach(groups.groups) { group in
                    groupRow(group)
                }
                .onMove { groups.move(fromOffsets: $0, toOffset: $1) }
                if groups.groups.isEmpty {
                    Button { model.groupPrompt = .create(nil) } label: {
                        Label("Nuevo grupo…", systemImage: "folder.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                    .help("Junta canales en un grupo y ve sus videos nuevos en un solo lugar")
                    Button { model.importingGroups = true } label: {
                        Label("Importar…", systemImage: "square.and.arrow.down")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                    .help("Grupos de PocketTube o GrayJay, o las suscripciones de NewPipe")
                }
            } header: {
                HStack {
                    Text("Mis grupos")
                    Spacer()
                    Menu {
                        Button("Nuevo grupo…", systemImage: "folder.badge.plus") { model.groupPrompt = .create(nil) }
                        Button("Importar de PocketTube, NewPipe o GrayJay…", systemImage: "square.and.arrow.down") {
                            model.importingGroups = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .accessibilityLabel("Agregar grupo")
                    .help("Nuevo grupo o importar")
                }
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

    /// La selección es el destino actual si es una sección fija o un grupo.
    private var selection: Binding<Destination?> {
        Binding(
            get: {
                switch model.navigator.current {
                case .section, .channelGroup: model.navigator.current
                default: nil
                }
            },
            set: { destination in if let destination { model.navigator.go(destination) } }
        )
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.symbol)
            .tag(Destination.section(item))
            .help(help(for: item))
    }

    private func groupRow(_ group: ChannelGroup) -> some View {
        Label(group.title, systemImage: "folder")
            .tag(Destination.channelGroup(group.id))
            .help(group.channels.isEmpty ? "Grupo sin canales" : "\(group.channels.count) \(group.channels.count == 1 ? "canal" : "canales")")
            .contextMenu {
                Button("Canales del grupo…", systemImage: "person.2") { model.groupEditor = GroupEditorRequest(id: group.id) }
                Button("Renombrar…", systemImage: "pencil") { model.groupPrompt = .rename(group) }
                Divider()
                Button("Subir", systemImage: "arrow.up") { groups.move(group.id, by: -1) }
                    .disabled(groups.groups.first?.id == group.id)
                Button("Bajar", systemImage: "arrow.down") { groups.move(group.id, by: 1) }
                    .disabled(groups.groups.last?.id == group.id)
                Divider()
                Button("Borrar grupo…", systemImage: "trash", role: .destructive) { model.groupToDelete = group }
            }
    }

    private func help(for item: SidebarItem) -> String {
        switch (item, accounts.isSignedIn) {
        case (.subscriptions, false): "Los canales que sigues en esta Mac (sus videos llegan por RSS, sin cuenta)"
        case (.history, false): "Historial local de esta Mac"
        case (.playlists, false): "Ver más tarde (local); las playlists de YouTube requieren cuenta"
        case (.subscriptions, true): "Videos nuevos de tus suscripciones de YouTube (y de las de esta Mac)"
        case (.history, true): "Historial de tu cuenta de YouTube (y el de esta Mac)"
        case (.playlists, true): "Tus playlists de YouTube, Ver más tarde y Me gusta"
        case (.shorts, _): "Shorts que recomienda YouTube; se reproducen en el reproductor de siempre"
        default: item.title
        }
    }
}
