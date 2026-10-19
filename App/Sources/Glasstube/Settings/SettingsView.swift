import SwiftUI

/// Ajustes: escena `Settings` con `TabView` y `Form` agrupado, con las pestañas de los presenters de SmartTube. En
/// esta fase funcionan Interfaz, Reproductor, Subtítulos y SponsorBlock; el resto explica cuándo llega.
struct SettingsView: View {
    /// La pestaña abierta se recuerda (y se puede fijar al lanzar con `-settingsTab player`).
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Interfaz", systemImage: "macwindow", value: "interface") { InterfaceSettings() }
            Tab("Reproductor", systemImage: "play.rectangle", value: "player") { PlayerSettings() }
            Tab("Subtítulos", systemImage: "captions.bubble", value: "subtitles") { SubtitleSettings() }
            Tab("SponsorBlock", systemImage: "forward.frame", value: "sponsorblock") { SponsorBlockSettings() }
            Tab("DeArrow", systemImage: "textformat.abc", value: "dearrow") { DeArrowSettings() }
            Tab("Cuentas", systemImage: "person.crop.circle", value: "accounts") { AccountSettings() }
            Tab("Control remoto", systemImage: "iphone.radiowaves.left.and.right", value: "remote") { RemoteSettings() }
            Tab("Respaldo", systemImage: "externaldrive", value: "backup") { BackupSettings() }
        }
        .frame(width: 780, height: 520)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(LocalLibrary.self) private var library

    var body: some View {
        @Bindable var settings = settings
        Form {
            UpdateSettingsSection()
            Section {
                Toggle("Agregar a Spotlight los videos que veo y sus canales", isOn: $settings.spotlightEnabled)
                Button("Quitar todo de Spotlight") {
                    model.spotlight.removeAll()
                    model.show(banner: "Se quitaron de Spotlight los videos y canales de Glasstube")
                }
            } header: {
                Text("Spotlight")
            } footer: {
                Text("Busca con ⌘ espacio un video que viste o un canal y ábrelo directo en Glasstube. En el índice de esta Mac solo va lo público de YouTube: título, canal, duración y miniatura.")
            }
            Section("Contenido oculto") {
                LabeledContent("Videos marcados como «No me interesa»", value: "\(library.hiddenVideos.count)")
                Button("Mostrar de nuevo los videos ocultos") { library.unhideAll() }
                    .disabled(library.hiddenVideos.isEmpty)
            }
            Section("Canales bloqueados") {
                if library.blockedChannels.isEmpty {
                    Text("Ninguno. Usa «Bloquear canal» en el menú de un video.").foregroundStyle(.secondary)
                }
                ForEach(library.blockedChannels) { channel in
                    LabeledContent(channel.name) {
                        Button("Desbloquear") { library.unblock(channel) }
                    }
                }
            }
            Section("Acerca de") {
                LabeledContent("Glasstube", value: Self.version)
                Text("Reimplementación para macOS de SmartTube (MIT). Reproduce con mpv y FFmpeg bajo LGPL (enlazados de forma dinámica en Libmpv.framework); los textos de licencia van en Contents/Resources/Licenses.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// La versión del `Info.plist` (la que escribe `Scripts/package-app.sh`); «desarrollo» sin empaquetar.
    static var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "desarrollo" }
        return (info?["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
    }
}

/// Ajustes › General › Actualizaciones: el aviso de versiones nuevas y lo que consulta.
struct UpdateSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @ViewState private var result: UpdateChecker.Result?

    var body: some View {
        @Bindable var settings = settings
        let updates = model.updates
        Section {
            Toggle("Avisarme cuando haya una versión nueva", isOn: $settings.checkForUpdates)
                .disabled(!updates.isConfigured)
            LabeledContent {
                HStack(spacing: 8) {
                    if updates.isChecking { ProgressView().controlSize(.small) }
                    Button("Buscar ahora") {
                        Task { result = await updates.check() }
                    }
                    .disabled(!updates.isConfigured || updates.isChecking)
                }
            } label: {
                Text(resultText ?? lastCheckText)
            }
            if let page = updates.releasesPage {
                Link("Ver todas las versiones en GitHub", destination: page)
            }
        } header: {
            Text("Actualizaciones")
        } footer: {
            Text(updates.isConfigured
                ? "Al abrir Glasstube, como mucho una vez al día, se pregunta a GitHub (api.github.com/repos/\(updates.repository ?? "")) cuál es la última versión publicada. Es la única consulta: no lleva datos tuyos ni de lo que ves, y no se instala nada solo. «Descargar» abre la página de la versión en el navegador."
                : "Esta compilación no se empaquetó con Scripts/package-app.sh (no tiene versión ni repositorio en su Info.plist), así que no busca versiones nuevas.")
        }
    }

    private var lastCheckText: String {
        guard let date = model.updates.lastCheck else { return "Todavía no se ha consultado" }
        return "Última consulta: \(date.formatted(.relative(presentation: .named)))"
    }

    private var resultText: String? {
        switch result {
        case .available(let update): "Hay una versión nueva: \(update.version)"
        case .upToDate: "Tienes la versión más reciente"
        case .failed: "No se pudo consultar GitHub; revisa la conexión"
        case .unconfigured, nil: nil
        }
    }
}

struct InterfaceSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Apariencia") {
                Picker("Apariencia", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("El reproductor siempre usa la apariencia oscura, como los reproductores del sistema.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Tarjetas") {
                Toggle("Vista previa del storyboard al pasar el puntero", isOn: $settings.hoverPreviews)
                Toggle("Mostrar Shorts en Inicio", isOn: $settings.showShortsOnHome)
            }
            Section("Controles del reproductor") {
                Picker("Ocultar los controles tras", selection: $settings.controlsTimeout) {
                    Text("2 s").tag(2.0)
                    Text("3 s").tag(3.0)
                    Text("5 s").tag(5.0)
                    Text("8 s").tag(8.0)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PlayerSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Calidad máxima al empezar", selection: $settings.maxHeight) {
                    ForEach(AppSettings.qualities, id: \.height) { Text($0.title).tag($0.height) }
                }
                Picker("Códec preferido", selection: $settings.codec) {
                    ForEach(AppSettings.VideoCodec.allCases) { Text($0.title).tag($0) }
                }
                Picker("Búfer", selection: $settings.buffer) {
                    ForEach(AppSettings.BufferSize.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Video")
            } footer: {
                Text("VP9 y H.264 se decodifican por hardware en Apple silicon; AV1 solo desde el M3. Los cambios valen para el próximo video.")
            }
            Section {
                Toggle("Seguir donde lo dejé", isOn: $settings.resumePlayback)
                Toggle("Reproducción automática con los sugeridos", isOn: $settings.autoplayNext)
                Picker("Cuenta atrás de «A continuación»", selection: $settings.autoplayCountdown) {
                    Text("Sin espera").tag(0.0)
                    Text("5 s").tag(5.0)
                    Text("8 s").tag(8.0)
                    Text("15 s").tag(15.0)
                }
            } header: {
                Text("Reproducción")
            } footer: {
                Text("Lo que pongas en la cola («Reproducir a continuación», «Agregar a la cola» o el resto de una playlist) se reproduce siempre; la reproducción automática sigue después con el primero de los sugeridos.")
            }
            Section {
                Toggle("Mostrar los «no me gusta» (Return YouTube Dislike)", isOn: $settings.showDislikes)
            } footer: {
                Text("YouTube ya no publica cuántos «no me gusta» tiene un video; returnyoutubedislikeapi.com da una estimación. Se consulta con el id del video.")
            }
            Section("Teclado") {
                LabeledContent("Pausa", value: "Espacio o K")
                LabeledContent("Atrás y adelante 10 s", value: "J y L")
                LabeledContent("Atrás y adelante 5 s", value: "← y →")
                LabeledContent("Pantalla completa y subtítulos", value: "F y C")
                LabeledContent("Velocidad", value: "Shift+. y Shift+,")
                LabeledContent("Panel lateral (descripción, comentarios, sugeridos)", value: "D; dentro, flechas, Retorno y Esc")
                LabeledContent("En el panel: me gusta, responder, cola", value: "G, R, Q (al final) y N (a continuación)")
                LabeledContent("Minirreproductor", value: "I")
                LabeledContent("Siguiente y anterior", value: "Shift+N y Shift+P")
            }
        }
        .formStyle(.grouped)
    }
}

/// DeArrow (`DeArrowSettingsPresenter` de SmartTube): apagado por omisión; con él, títulos y miniaturas de la comunidad.
struct DeArrowSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Usar DeArrow", isOn: $settings.deArrowEnabled)
                Toggle("Reemplazar los títulos", isOn: $settings.deArrowTitles)
                    .disabled(!settings.deArrowEnabled)
                Toggle("Reemplazar las miniaturas", isOn: $settings.deArrowThumbnails)
                    .disabled(!settings.deArrowEnabled)
            } footer: {
                Text("Títulos y miniaturas que vota la comunidad de DeArrow (dearrow.ajay.app) en lugar de los «clickbait», en las tarjetas y en el reproductor. Al pasar el puntero sobre un título cambiado se ve el original.")
            }
            Section("Privacidad") {
                Text("Los títulos se consultan por prefijo del hash del video (sponsor.ajay.app/api/branding), sin enviar su id, como SponsorBlock. Las miniaturas las genera dearrow-thumb.ajay.app y esa petición sí lleva el id del video.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SubtitleSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Activar subtítulos al empezar un video", isOn: $settings.subtitlesByDefault)
                Picker("Idioma preferido", selection: $settings.subtitleLanguage) {
                    Text("Español").tag("es")
                    Text("Inglés").tag("en")
                    Text("Portugués").tag("pt")
                    Text("Francés").tag("fr")
                    Text("Alemán").tag("de")
                    Text("Japonés").tag("ja")
                }
            } footer: {
                Text("Los subtítulos de YouTube se piden en WebVTT y los dibuja mpv. El estilo (tamaño, fondo) llega en la fase 3.")
            }
        }
        .formStyle(.grouped)
    }
}

struct SponsorBlockSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Usar SponsorBlock", isOn: $settings.sponsorBlockEnabled)
                Toggle("Saltar automáticamente (si no, muestra el botón «Saltar»)", isOn: $settings.sponsorBlockAutoSkip)
                    .disabled(!settings.sponsorBlockEnabled)
            } footer: {
                Text("Tramos de la comunidad (sponsor.ajay.app): patrocinio, autopromoción, recordatorios, intro, créditos, avances y partes sin música. Se consultan por prefijo del hash del video, sin enviar su id.")
            }
            Section("Colores en la barra") {
                ForEach(SponsorBlockClient.categories, id: \.self) { category in
                    let segment = SponsorSegment(start: 0, end: 1, category: category, uuid: category)
                    LabeledContent(segment.skipTitle.replacingOccurrences(of: "Saltar ", with: "").capitalized) {
                        RoundedRectangle(cornerRadius: 3).fill(segment.color).frame(width: 36, height: 8)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct BackupSettings: View {
    @Environment(LocalLibrary.self) private var library

    var body: some View {
        Form {
            Section("Datos de esta Mac") {
                LabeledContent("Historial", value: "\(library.history.count) videos")
                LabeledContent("Ver más tarde", value: "\(library.watchLater.count) videos")
                LabeledContent("Archivo", value: "~/Library/Application Support/Glasstube/library.json")
            }
            Section {
                Text("Exportar e importar un respaldo compatible con SmartTube, PocketTube, NewPipe y Grayjay llega en la fase 5.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PendingSettings: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        Form {
            Section {
                ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            }
        }
        .formStyle(.grouped)
    }
}
