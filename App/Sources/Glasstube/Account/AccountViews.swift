import AppKit
import SwiftUI
import YTKit

/// Avatar circular de una cuenta (o el símbolo de persona si no hay imagen).
///
/// La foto se dibuja ya recortada en un `NSImage` de `size` puntos y se muestra sin `.resizable()`: en la toolbar,
/// macOS toma el tamaño de la imagen e ignora `.frame` y `.clipShape`, y con la foto de 176 px de YouTube el menú de
/// cuenta salía como una burbuja de vidrio de ~190 pt debajo de la barra.
struct AccountAvatar: View {
    let account: Account?
    var size: CGFloat = 22

    @ViewState private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: account?.id) {
            image = nil
            guard let url = account?.avatarURL(points: size),
                  let photo = await ImagePipeline.shared.image(for: url) else { return }
            image = Self.circular(photo, points: size)
        }
        .accessibilityHidden(true)
    }

    /// La foto llenando un círculo de `points` puntos (recorta lo que sobre si no es cuadrada). Se dibuja al vuelo, así
    /// que se ve nítida en pantallas Retina.
    static func circular(_ photo: NSImage, points: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: points, height: points), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            let source = photo.size
            let scale = max(rect.width / max(source.width, 1), rect.height / max(source.height, 1))
            let drawn = NSSize(width: source.width * scale, height: source.height * scale)
            photo.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                  width: drawn.width, height: drawn.height))
            return true
        }
    }
}

/// Menú de cuenta de la toolbar (`AccountSelectionPresenter` de SmartTube): el avatar de la cuenta elegida; dentro, las
/// cuentas para cambiar, agregar otra y cerrar sesión. Es un `Menu` del sistema (vidrio de la toolbar).
struct AccountMenu: View {
    @Environment(AccountModel.self) private var accounts
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            if accounts.isSignedIn {
                ForEach(Array(accounts.sessions.enumerated()), id: \.offset) { _, session in
                    Section(session.first(where: { !$0.isBrand })?.displayByline ?? "Cuenta de Google") {
                        ForEach(session) { account in
                            Toggle(isOn: Binding(get: { accounts.selected?.id == account.id },
                                                 set: { if $0 { accounts.select(account) } })) {
                                Text(account.displayName)
                                Text(account.isBrand ? (account.displayByline ?? account.kindLabel) : account.kindLabel)
                            }
                        }
                    }
                }
                Divider()
                Button("Agregar otra cuenta…", systemImage: "person.crop.circle.badge.plus") { accounts.beginSignIn() }
                if let selected = accounts.selected {
                    Button("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right") { accounts.signOut(selected) }
                }
            } else {
                Section("Sin sesión") {
                    Button("Iniciar sesión con un código…", systemImage: "person.crop.circle.badge.plus") { accounts.beginSignIn() }
                }
            }
            Divider()
            Button("Ajustes de cuentas…") {
                UserDefaults.standard.set("accounts", forKey: "settingsTab")
                openSettings()
            }
        } label: {
            if let selected = accounts.selected {
                Label { Text(selected.displayName) } icon: { AccountAvatar(account: selected, size: 22) }
            } else {
                Label("Cuenta", systemImage: "person.crop.circle")
            }
        }
        .menuIndicator(.hidden)
        .help(accounts.selected.map { "Cuenta: \($0.displayName)" } ?? "Cuenta: iniciar sesión")
        .accessibilityLabel(accounts.selected.map { "Cuenta: \($0.displayName). Cambiar de cuenta o cerrar sesión" } ?? "Cuenta: iniciar sesión")
    }
}

/// Hoja de inicio de sesión por código (el `SignInPresenter` de SmartTube): el código grande para escribirlo en
/// youtube.com/activate desde el teléfono o la computadora, y el estado de espera. Hoja del sistema.
struct SignInSheet: View {
    @Environment(AccountModel.self) private var accounts
    @ViewState private var copied = false

    var body: some View {
        VStack(spacing: 22) {
            header
            switch accounts.signIn {
            case .requesting, .none:
                ProgressView("Pidiendo un código a YouTube…")
                    .frame(height: 170)
            case .waiting(let code, let url, let expiresAt):
                waiting(code: code, url: url, expiresAt: expiresAt)
            case .finishing:
                ProgressView("Trayendo tus cuentas…").frame(height: 170)
            case .done(let name):
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Sesión iniciada como \(name)").font(.title3.weight(.semibold))
                    Text("Suscripciones, Historial y Playlists ya están en la barra lateral.")
                        .foregroundStyle(.secondary)
                }
                .frame(height: 170)
            case .failed(let message):
                ContentUnavailableView {
                    Label("No se pudo iniciar sesión", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Pedir otro código") { accounts.beginSignIn() }
                        .buttonStyle(.glassProminent)
                }
                .frame(height: 200)
            }
            footer
        }
        .padding(28)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "play.tv")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Iniciar sesión en YouTube").font(.title2.weight(.semibold))
            Text("Como en la app de YouTube para TV: autoriza esta Mac desde otro dispositivo. Glasstube nunca ve tu contraseña.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func waiting(code: String, url: URL, expiresAt: Date) -> some View {
        VStack(spacing: 14) {
            Text("En tu teléfono o computadora, abre **\(url.host() ?? "youtube.com")\(url.path())** y escribe:")
                .multilineTextAlignment(.center)
            Text(code)
                .font(.system(size: 46, weight: .semibold, design: .monospaced))
                .kerning(2)
                .textSelection(.enabled)
                .padding(.vertical, 4)
                .accessibilityLabel("Código \(code.map(String.init).joined(separator: " "))")
            HStack(spacing: 10) {
                Button(copied ? "Copiado" : "Copiar código", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                Button("Abrir \(url.host() ?? "youtube.com")\(url.path())", systemImage: "safari") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.glass)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(expiresAt.timeIntervalSince(context.date)))
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Esperando a que lo autorices… vence en \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            if case .done = accounts.signIn {} else {
                Label {
                    Text("Usa de preferencia una cuenta secundaria: iniciar sesión desde un cliente no oficial va contra los términos de YouTube. La sesión se guarda en el Llavero de macOS.")
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if case .done = accounts.signIn {
                    Button("Listo") { accounts.cancelSignIn() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                } else {
                    Button("Cancelar") { accounts.cancelSignIn() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

/// Ajustes > Cuentas: sesiones de Google con sus cuentas, la elegida, agregar y cerrar sesión.
struct AccountSettings: View {
    @Environment(AccountModel.self) private var accounts
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            if accounts.sessions.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Sin sesión", systemImage: "person.crop.circle")
                    } description: {
                        Text("Inicia sesión con un código, como en la app de YouTube para TV, para ver tus suscripciones, tu historial y tus playlists, dar me gusta y suscribirte.")
                    } actions: {
                        Button("Iniciar sesión con un código…") { signInFromSettings() }
                            .buttonStyle(.glassProminent)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(accounts.sessions.enumerated()), id: \.offset) { _, session in
                Section {
                    ForEach(session) { account in
                        HStack(spacing: 12) {
                            AccountAvatar(account: account, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                Text(account.isBrand ? "\(account.kindLabel)\(account.displayByline.map { " · \($0)" } ?? "")" : (account.displayByline ?? account.kindLabel))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if accounts.selected?.id == account.id {
                                Label("En uso", systemImage: "checkmark.circle.fill")
                                    .labelStyle(.titleAndIcon)
                                    .foregroundStyle(.tint)
                            } else {
                                Button("Usar") { accounts.select(account) }
                            }
                        }
                    }
                } header: {
                    Text("Cuenta de Google")
                } footer: {
                    HStack {
                        Text(session.count > 1 ? "\(session.count) cuentas con la misma sesión (la personal y las de marca)." : "Una cuenta en esta sesión.")
                        Spacer()
                        if let first = session.first {
                            Button("Cerrar sesión", role: .destructive) { accounts.signOut(first) }
                        }
                    }
                }
            }
            if !accounts.sessions.isEmpty {
                Section {
                    Button("Agregar otra cuenta de Google…") { signInFromSettings() }
                    Button("Actualizar nombres y avatares") { accounts.refresh() }
                }
            }
            Section {
                Toggle("Guardar lo que veo en el historial de YouTube", isOn: $settings.syncWatchHistory)
            } header: {
                Text("Historial")
            } footer: {
                Text("Reporta la posición cada minuto, al pausar y al cerrar, como el reproductor de YouTube. El historial local de esta Mac se guarda siempre.")
            }
            Section {
                LabeledContent("Dónde se guarda", value: "Llavero de macOS (mx.glasstube.cuentas)")
                Text("Cerrar sesión revoca el acceso en Google y borra la sesión del Llavero. También puedes quitar el acceso desde myaccount.google.com > Seguridad > Tus conexiones.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Seguridad")
            }
        }
        .formStyle(.grouped)
    }

    /// La hoja del código va en la ventana principal: se cierra Ajustes para que quede a la vista.
    private func signInFromSettings() {
        NSApp.keyWindow?.performClose(nil)
        NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true || $0.title == "Glasstube" }?.makeKeyAndOrderFront(nil)
        accounts.beginSignIn()
    }
}

/// "Guardar en una playlist" (el `VideoMenuPresenter` de SmartTube con `getPlaylistsInfo`): las listas de la cuenta con
/// una casilla por lista; marcar agrega el video y desmarcar lo quita. Hoja del sistema.
struct PlaylistPickerSheet: View {
    let item: MediaItem
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var lists: [PlaylistInfo]?
    @ViewState private var failure: String?
    @ViewState private var busy: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Guardar en una playlist").font(.title3.weight(.semibold))
                Text(item.title).foregroundStyle(.secondary).lineLimit(2)
            }
            Group {
                if let lists {
                    if lists.isEmpty {
                        ContentUnavailableView("Sin playlists", systemImage: "list.bullet",
                                               description: Text("Esta cuenta todavía no tiene playlists propias."))
                    } else {
                        List(lists) { list in
                            Toggle(isOn: binding(for: list)) {
                                Label(list.title, systemImage: list.id == YouTubeService.watchLaterPlaylistId ? "clock" : "list.bullet")
                            }
                            .disabled(busy.contains(list.id))
                        }
                        .listStyle(.inset)
                    }
                } else if let failure {
                    ContentUnavailableView("No se pudieron cargar tus playlists", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ProgressView("Cargando tus playlists…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 280)
            HStack {
                Spacer()
                Button("Listo") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task { await load() }
    }

    private func load() async {
        guard let videoId = item.videoId else { return }
        do {
            lists = try await model.service.playlistsInfo(videoId: videoId)
        } catch {
            failure = AccountModel.describe(error)
        }
    }

    private func binding(for list: PlaylistInfo) -> Binding<Bool> {
        Binding(get: { list.containsVideo }, set: { add in
            guard let videoId = item.videoId, let index = lists?.firstIndex(where: { $0.id == list.id }) else { return }
            lists?[index].containsVideo = add
            busy.insert(list.id)
            Task {
                do {
                    if add {
                        try await model.service.addToPlaylist(playlistId: list.id, videoId: videoId)
                    } else {
                        try await model.service.removeFromPlaylist(playlistId: list.id, videoId: videoId)
                    }
                } catch {
                    lists?[index].containsVideo = !add
                    failure = AccountModel.describe(error)
                }
                busy.remove(list.id)
            }
        })
    }
}
