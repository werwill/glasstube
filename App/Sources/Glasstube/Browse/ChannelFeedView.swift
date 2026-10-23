import AppKit
import SwiftUI
import UniformTypeIdentifiers
import YTKit

/// Feed de varios canales por RSS (fase 5a): un grupo de canales o las suscripciones de esta Mac. Los videos nuevos de
/// cada canal se piden en paralelo y con caché (`RSSFeedService` de YTKit, como `RssService` de SmartTube) y se juntan
/// del más nuevo al más viejo; los Shorts van aparte, en su fila.
struct ChannelFeedView: View {
    enum Source: Hashable {
        case group(String)
        case subscriptions
    }

    let source: Source
    /// Control junto al título (el selector YouTube / Esta Mac de Suscripciones).
    var accessory: AnyView?

    @Environment(AppModel.self) private var model
    @Environment(LocalLibrary.self) private var library
    @Environment(ChannelGroupStore.self) private var groups
    @Environment(AccountModel.self) private var accounts
    @ViewState private var result: RSSFeedService.Result?
    @ViewState private var loadedChannels: [String] = []
    @ViewState private var lastReload = 0
    @ViewState private var width: CGFloat = 1100
    @ViewState private var grid = GridFocus()
    @FocusState private var gridFocused: Bool

    private var group: ChannelGroup? {
        if case .group(let id) = source { return groups.group(id) }
        return nil
    }

    private var channels: [GroupChannel] {
        switch source {
        case .group: group?.channels ?? []
        case .subscriptions: groups.subscriptions
        }
    }

    private var title: String {
        switch source {
        case .group: group?.title ?? "Grupo"
        case .subscriptions: "Suscripciones"
        }
    }

    private var subtitle: String {
        let count = channels.count
        let channelsText = count == 1 ? "1 canal" : "\(count) canales"
        switch source {
        case .group: return "\(channelsText) · lo nuevo de cada uno, por RSS"
        case .subscriptions: return "\(channelsText) que sigues en esta Mac · sus videos nuevos llegan por RSS, sin cuenta"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !channels.isEmpty { ChannelStrip(channels: channels, groupId: group?.id) }
                content
            }
            .padding(.horizontal, GridMetrics.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - GridMetrics.pagePadding * 2 } action: { width = $0 }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .modifier(GridKeyboardNavigation(sections: sections.map { ($0.items, columns(for: $0.items)) }, grid: grid,
                                         isFocused: $gridFocused) { model.open($0) })
        .task(id: TaskKey(channels: channels.map(\.id), reload: model.reloadToken)) { await load() }
    }

    private struct TaskKey: Hashable {
        var channels: [String]
        var reload: Int
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            PageHeader(title: title, subtitle: channels.isEmpty ? nil : subtitle)
            if let accessory { accessory }
            if let group {
                // Controles de la página: vidrio (una sola capa, juntos en su contenedor).
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button { model.groupEditor = GroupEditorRequest(id: group.id) } label: {
                            Label("Canales…", systemImage: "person.2")
                        }
                        .help("Agregar o quitar canales del grupo")
                        Menu {
                            Button("Renombrar…", systemImage: "pencil") { model.groupPrompt = .rename(group) }
                            Button("Subir en la barra lateral", systemImage: "arrow.up") { groups.move(group.id, by: -1) }
                                .disabled(groups.groups.first?.id == group.id)
                            Button("Bajar en la barra lateral", systemImage: "arrow.down") { groups.move(group.id, by: 1) }
                                .disabled(groups.groups.last?.id == group.id)
                            Divider()
                            Button("Borrar grupo…", systemImage: "trash", role: .destructive) { model.groupToDelete = group }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .accessibilityLabel("Más opciones del grupo")
                        }
                        .menuStyle(.button)
                        .buttonBorderShape(.circle)
                        .menuIndicator(.hidden)
                        .help("Renombrar, ordenar o borrar el grupo")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                .fixedSize()
            }
        }
    }

    private struct Section {
        var title: String?
        var items: [MediaItem]
    }

    /// Videos en cuadrícula y, después, los Shorts en su fila. Sin lo oculto ni lo bloqueado.
    private var sections: [Section] {
        guard let result else { return [] }
        var visible = library.visible(result.items)
        if let only = Automation.shared.onlyVideos { visible = visible.filter { $0.videoId.map(only.contains) ?? false } }
        let videos = visible.filter { !$0.isShort }
        let shorts = visible.filter(\.isShort)
        var sections: [Section] = []
        if !videos.isEmpty { sections.append(Section(title: shorts.isEmpty ? nil : "Videos", items: videos)) }
        if !shorts.isEmpty { sections.append(Section(title: "Shorts", items: shorts)) }
        return sections
    }

    private func columns(for items: [MediaItem]) -> Int {
        items.allSatisfy(\.isShort) ? items.count : GridMetrics.columns(for: width)
    }

    @ViewBuilder
    private var content: some View {
        if channels.isEmpty {
            emptyState
        } else if let result {
            if sections.isEmpty {
                ContentUnavailableView("Nada nuevo por aquí", systemImage: "rectangle.on.rectangle.slash",
                                       description: Text(result.failed.count == channels.count
                                                         ? "Ningún canal respondió. Revisa la conexión y recarga (⌘R)."
                                                         : "Estos canales no tienen videos recientes (o están bloqueados)."))
                    .frame(minHeight: 260)
            }
            ForEach(sections.indices, id: \.self) { index in
                CardSection(title: sections[index].title, items: sections[index].items, section: index, grid: grid)
            }
            footer(result)
        } else {
            LoadStateView(state: .loading)
        }
    }

    @ViewBuilder
    private func footer(_ result: RSSFeedService.Result) -> some View {
        let names = result.failed.map { id in channels.first { $0.id == id }?.displayName ?? id }
        if !names.isEmpty || result.skipped > 0 {
            VStack(alignment: .leading, spacing: 4) {
                if !names.isEmpty {
                    Label("Sin respuesta de \(names.count == 1 ? "un canal" : "\(names.count) canales"): \(names.prefix(5).joined(separator: ", "))\(names.count > 5 ? "…" : "")",
                          systemImage: "exclamationmark.triangle")
                }
                if result.skipped > 0 {
                    Label("Se muestran los primeros \(RSSFeedService.maxChannels) canales; \(result.skipped) quedaron fuera.", systemImage: "info.circle")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch source {
        case .group:
            ContentUnavailableView {
                Label("Este grupo no tiene canales", systemImage: "folder")
            } description: {
                Text("Agrega canales con «Agregar a un grupo» en el menú «…» de un video o en la página de un canal, o aquí mismo con «Canales…».")
            } actions: {
                if let group {
                    Button("Agregar canales…") { model.groupEditor = GroupEditorRequest(id: group.id) }
                        .buttonStyle(.glassProminent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        case .subscriptions:
            ContentUnavailableView {
                Label("Todavía no sigues canales en esta Mac", systemImage: "play.rectangle.on.rectangle")
            } description: {
                Text(accounts.isSignedIn
                     ? "Aquí van los canales que sigues sin cuenta: «Suscribirse en esta Mac» en la página de un canal, o importa tus suscripciones de NewPipe."
                     : "Sin cuenta, usa «Suscribirse» en la página de un canal (o en el menú «…» de un video): sus videos nuevos llegan aquí por RSS. También puedes importar tus suscripciones de NewPipe o iniciar sesión.")
            } actions: {
                HStack {
                    Button("Importar de NewPipe…") { model.importingGroups = true }
                        .buttonStyle(.glass)
                    if !accounts.isSignedIn {
                        Button("Iniciar sesión con un código…") { accounts.beginSignIn() }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    private func load() async {
        let ids = channels.map(\.id)
        guard !ids.isEmpty else {
            result = RSSFeedService.Result()
            return
        }
        // ⌘R (Recargar) ignora la caché; abrir la página o cambiar los canales, no.
        let refresh = lastReload != model.reloadToken && result != nil && loadedChannels == ids
        lastReload = model.reloadToken
        let start = Date()
        let loaded = await model.service.rssFeed(channelIds: ids, refresh: refresh)
        guard !Task.isCancelled else { return }
        if Automation.shared.logsGroups {
            NSLog("Glasstube grupos: feed de \(ids.count) canales → \(loaded.items.count) videos (\(loaded.items.filter(\.isShort).count) Shorts) en %.2f s; de caché \(loaded.cached), sin respuesta \(loaded.failed.count)\(refresh ? ", recargado" : "")",
                  Date().timeIntervalSince(start))
        }
        withAnimation(.smooth) {
            result = loaded
            loadedChannels = ids
        }
        groups.update(titles: loaded.channelTitles)
        if !model.searchFieldFocused {
            try? await Task.sleep(for: .milliseconds(100))
            model.focusContent()
        }
        await completeAvatars()
    }

    /// Lo importado de PocketTube, GrayJay o NewPipe no trae fotos: se piden de la página de hasta 8 canales por visita y
    /// quedan guardadas.
    private func completeAvatars() async {
        let missing = channels.filter { $0.avatarURL == nil }.prefix(8).map(\.id)
        guard !missing.isEmpty else { return }
        let service = model.service
        let found = await withTaskGroup(of: GroupChannel?.self) { group -> [GroupChannel] in
            for id in missing {
                group.addTask {
                    guard let page = try? await service.channel(id, tab: .home), let avatar = page.avatar.best(forWidth: 88) else { return nil }
                    return GroupChannel(id: id, title: page.title, avatarURL: avatar.url)
                }
            }
            var result: [GroupChannel] = []
            for await channel in group { if let channel { result.append(channel) } }
            return result
        }
        guard !Task.isCancelled else { return }
        for channel in found { groups.update(channel: channel) }
        if Automation.shared.logsGroups { NSLog("Glasstube grupos: fotos completadas \(found.count) de \(missing.count)") }
    }
}

/// Los canales del feed en una fila: foto (o inicial) y nombre; clic abre el canal.
struct ChannelStrip: View {
    let channels: [GroupChannel]
    var groupId: String?
    @Environment(AppModel.self) private var model
    @Environment(ChannelGroupStore.self) private var groups

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(channels) { channel in
                    Button {
                        model.navigator.go(.channel(id: channel.id, title: channel.title))
                    } label: {
                        HStack(spacing: 8) {
                            ChannelAvatar(channel: channel, size: 26)
                            Text(channel.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.leading, 4)
                        .padding(.trailing, 12)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .help("Abrir \(channel.displayName)")
                    .contextMenu {
                        Button("Abrir canal", systemImage: "person.crop.square") {
                            model.navigator.go(.channel(id: channel.id, title: channel.title))
                        }
                        if let groupId {
                            Button("Quitar del grupo", systemImage: "minus.circle") { groups.remove(channelId: channel.id, from: groupId) }
                        } else {
                            Button("Dejar de seguir en esta Mac", systemImage: "minus.circle") { model.toggleLocalSubscription(channel) }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }
}

/// Foto del canal o, si todavía no se tiene (importado de PocketTube o GrayJay), su inicial en un círculo.
struct ChannelAvatar: View {
    let channel: GroupChannel
    var size: CGFloat

    var body: some View {
        Group {
            if let url = channel.avatarURL.flatMap(URL.init(string:)) {
                RemoteImage(url: url)
            } else {
                Circle()
                    .fill(Color(hue: hue, saturation: 0.35, brightness: 0.72))
                    .overlay {
                        Text(String(channel.displayName.prefix(1)).uppercased())
                            .font(.system(size: size * 0.45, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    /// El mismo color para el mismo canal en cada arranque (`hashValue` cambia de una ejecución a otra).
    private var hue: Double {
        Double(channel.id.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
    }
}

/// Hoja «Canales del grupo»: nombre, sus canales (quitar) y agregar uno por @handle, URL o id.
struct GroupChannelsSheet: View {
    let groupId: String
    @Environment(AppModel.self) private var model
    @Environment(ChannelGroupStore.self) private var groups
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var newChannel = ""
    @ViewState private var adding = false
    @ViewState private var addError: String?

    var body: some View {
        let group = groups.group(groupId)
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Nombre del grupo", text: $name)
                        .onSubmit { groups.rename(groupId, to: name) }
                }
                Section {
                    if group?.channels.isEmpty ?? true {
                        Text("Todavía no hay canales. Agrega uno aquí abajo, o con «Agregar a un grupo» en el menú «…» de un video o en la página del canal.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group?.channels ?? []) { channel in
                        HStack(spacing: 10) {
                            ChannelAvatar(channel: channel, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(channel.displayName)
                                if channel.title != nil {
                                    Text(channel.id).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button("Quitar", systemImage: "minus.circle") { groups.remove(channelId: channel.id, from: groupId) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Quitar \(channel.displayName) del grupo")
                        }
                    }
                } header: {
                    Text("Canales (\(group?.channels.count ?? 0))")
                }
                Section {
                    HStack {
                        TextField(text: $newChannel, prompt: Text("@handle, enlace del canal o id UC…")) { Text("Canal") }
                            .labelsHidden()
                            .onSubmit { Task { await add() } }
                        if adding { ProgressView().controlSize(.small) }
                        Button("Agregar") { Task { await add() } }
                            .disabled(newChannel.trimmingCharacters(in: .whitespaces).isEmpty || adding)
                    }
                    if let addError {
                        Text(addError).font(.callout).foregroundStyle(.red)
                    }
                } header: {
                    Text("Agregar un canal")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Listo") {
                    groups.rename(groupId, to: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 500)
        .onAppear { name = group?.title ?? "" }
    }

    private func add() async {
        let text = newChannel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        adding = true
        addError = nil
        defer { adding = false }
        do {
            let id: String
            if let direct = ChannelGroupImport.channelId(fromURL: text) {
                id = direct
            } else {
                id = try await model.service.resolveChannelId(text)
            }
            // El nombre y la foto, de la página del canal (una vez; quedan guardados).
            let page = try? await model.service.channel(id, tab: .home)
            let channel = GroupChannel(id: id, title: page?.title, avatarURL: page?.avatar.best(forWidth: 88)?.url)
            groups.add(channel, to: groupId)
            newChannel = ""
        } catch {
            addError = "No se encontró ese canal"
        }
    }
}

/// Aviso con campo de texto para el nombre de un grupo (nuevo o renombrar), el borrado con confirmación, la hoja de
/// canales y el selector de archivos para importar. Va en la ventana principal.
struct GroupDialogs: ViewModifier {
    @Bindable var model: AppModel
    @ViewState private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(promptTitle, isPresented: promptPresented) {
                TextField("Nombre", text: $name)
                Button(promptAction) { commit() }
                    .keyboardShortcut(.defaultAction)
                Button("Cancelar", role: .cancel) {}
            } message: {
                if case .create(let channel?) = model.groupPrompt {
                    Text("El grupo empezará con «\(channel.displayName)».")
                } else if case .create = model.groupPrompt {
                    Text("Después agrega canales desde el menú «…» de un video o desde la página de un canal.")
                }
            }
            .confirmationDialog("¿Borrar el grupo «\(model.groupToDelete?.title ?? "")»?", isPresented: deletePresented,
                                titleVisibility: .visible) {
                Button("Borrar grupo", role: .destructive) {
                    if let group = model.groupToDelete { model.deleteGroup(group) }
                }
            } message: {
                Text("Solo se borra el grupo: los canales no cambian ni se cancela ninguna suscripción.")
            }
            .sheet(item: $model.groupEditor) { GroupChannelsSheet(groupId: $0.id) }
            .fileImporter(isPresented: $model.importingGroups, allowedContentTypes: [.json, .data]) { result in
                if case .success(let url) = result { model.importGroups(from: url) }
            }
            .onChange(of: model.groupPrompt) { _, prompt in
                if case .rename(let group) = prompt { name = group.title } else { name = "" }
            }
    }

    private var promptTitle: String {
        if case .rename = model.groupPrompt { return "Renombrar el grupo" }
        return "Nuevo grupo de canales"
    }

    private var promptAction: String {
        if case .rename = model.groupPrompt { return "Renombrar" }
        return "Crear"
    }

    private var promptPresented: Binding<Bool> {
        Binding(get: { model.groupPrompt != nil }, set: { if !$0 { model.groupPrompt = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { model.groupToDelete != nil }, set: { if !$0 { model.groupToDelete = nil } })
    }

    private func commit() {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prompt = model.groupPrompt, !text.isEmpty else { return }
        switch prompt {
        case .create(let channel): model.createGroup(named: text, with: channel)
        case .rename(let group): model.groups.rename(group.id, to: text)
        }
        model.groupPrompt = nil
    }
}
