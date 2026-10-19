import AppKit
import SwiftUI

// Glasstube: la app de macOS que reimplementa SmartTube (cliente alternativo de YouTube para Android TV, MIT) con el
// lenguaje Liquid Glass de macOS 26. El catálogo sale de YTKit y la reproducción de PlaybackKit (libmpv por SABR).
//
// Reglas de interfaz (smarttube-re/hallazgos/05-interfaz-liquid-glass.md): el contenido va opaco y el vidrio solo en
// navegación y controles; solo APIs de Liquid Glass del SDK y componentes del sistema; nunca vidrio sobre vidrio.

/// `@State` es una macro en el SDK de macOS 27 y su plugin (SwiftUIMacros) no viene en las Command Line Tools: el
/// compilador no la puede expandir. El mismo tipo con otro nombre se usa como envoltorio de propiedad normal.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct GlasstubeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        Window("Glasstube", id: "main") {
            MainWindow()
                .environment(model)
                .environment(model.settings)
                .environment(model.library)
                .environment(model.accounts)
                .environment(model.remote)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { GlasstubeCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.settings)
                .environment(model.library)
                .environment(model.accounts)
                .environment(model.remote)
        }
    }
}

/// Menús de la app. Los atajos del reproductor (espacio, J/K/L, flechas, F, C, Shift+. y Shift+,) no van aquí: los
/// atiende la vista del reproductor, que es la que tiene el foco y muestra los controles con cualquier tecla.
struct GlasstubeCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Atrás") { model.navigator.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.navigator.canGoBack || model.player != nil)
            Button("Adelante") { model.navigator.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.navigator.canGoForward || model.player != nil)
            Button("Recargar") { model.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Button("Buscar en YouTube") { model.focusSearch() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Abrir el enlace copiado") { model.openPasteboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandGroup(after: .appSettings) {
            Button("Vincular un teléfono…") { model.remote.beginPairing() }
        }
        CommandMenu("Reproducción") {
            Button(model.player?.isPlaying == true ? "Pausar" : "Reproducir") { model.player?.togglePause() }
                .disabled(model.player == nil)
            Button("Cerrar el reproductor") { model.closePlayer() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.player == nil)
        }
    }
}
