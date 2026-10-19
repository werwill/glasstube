import AppKit
import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers
import YTKit

/// Delegado de la app: lo que llega de macOS (fase 4). El esquema `glasstube://` (y enlaces de YouTube abiertos con
/// la app), los resultados de Spotlight, el menú del Dock, «Abrir en Glasstube» del menú Servicios y ⌘V con un enlace
/// cuando ningún campo de texto lo toma.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Servicios: `NSServices` del Info.plist llama a `openInGlasstube(_:userData:error:)`.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        AppModel.current?.didFinishLaunching()
    }

    // MARK: - URL

    /// `glasstube://…` y enlaces de YouTube abiertos con la app (`open -a Glasstube https://youtu.be/…`).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            AppModel.current?.openExternal(url.absoluteString, from: "url")
        }
    }

    // MARK: - Spotlight

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let link = SpotlightIndex.link(for: identifier) else { return false }
        AppModel.current?.open(link, from: "spotlight")
        return true
    }

    // MARK: - Dock

    /// Clic secundario en el ícono del Dock: Inicio, Suscripciones y Seguir viendo.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        AppModel.current?.dockMenu()
    }

    // MARK: - Servicios

    /// «Abrir en Glasstube» (texto seleccionado o un enlace en cualquier app).
    @objc func openInGlasstube(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // El texto seleccionado y, si lo hay, el enlace (el primero que sea de YouTube).
        let texts = [NSPasteboard.PasteboardType.string, .URL].compactMap { pasteboard.string(forType: $0) }
        guard let model = AppModel.current, let text = texts.first(where: { YouTubeLink.parse($0) != nil }) else {
            if Automation.shared.logsLinks { NSLog("Glasstube enlaces: servicios: no es de YouTube (tipos \(pasteboard.types?.map(\.rawValue) ?? []))") }
            error.pointee = "El texto no tiene un enlace de YouTube" as NSString
            return
        }
        model.openExternal(text, from: "servicios")
    }

    // MARK: - Pegar

    /// ⌘V fuera de un campo de texto (los campos lo atienden antes en la cadena de respuesta): abre el enlace de YouTube
    /// del portapapeles.
    @objc func paste(_ sender: Any?) {
        AppModel.current?.openPasteboard()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)) {
            let pasteboard = NSPasteboard.general
            return pasteboard.string(forType: .URL) != nil || pasteboard.string(forType: .string) != nil
        }
        return true
    }
}

/// Elemento de menú con su acción en un cierre (menú del Dock). El destino va también en `representedObject`, porque
/// `target` no lo retiene.
enum ActionMenuItem {
    static func make(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
}

final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run(_ sender: Any?) { handler() }
}

extension AppModel {
    /// La ventana principal (la única `Window` de la app).
    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Glasstube" }
    }

    /// Trae la ventana principal al frente.
    func bringToFront() {
        NSApp.activate()
        if playerPresentation == .full { mainWindow?.makeKeyAndOrderFront(nil) }
    }

    // MARK: - Enlaces

    /// Un texto que llegó de fuera (URL, Servicios, pegar, arrastrar). Devuelve si tenía un enlace de YouTube.
    @discardableResult
    func openExternal(_ text: String, from source: String) -> Bool {
        guard let link = YouTubeLink.parse(text) else {
            if Automation.shared.logsLinks { NSLog("Glasstube enlaces: \(source): no es de YouTube") }
            return false
        }
        open(link, from: source)
        return true
    }

    /// Abre un enlace: el video en el reproductor (con su lista en la cola), o el canal, la lista o la búsqueda.
    func open(_ link: YouTubeLink, from source: String) {
        if Automation.shared.logsLinks { NSLog("Glasstube enlaces: \(source) → \(link)") }
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
        switch link {
        case .video(let id, let start, let list):
            var item = MediaItem(kind: .video, title: id, renderer: "link")
            item.videoId = id
            play(item, startAt: start)
            if let list { queuePlaylist(list, after: item) }
        case .playlist(let id):
            leavePlayerForBrowsing()
            navigator.go(.playlist(id: id, title: nil))
        case .channel(let id):
            leavePlayerForBrowsing()
            navigator.go(.channel(id: id, title: nil))
        case .search(let query):
            leavePlayerForBrowsing()
            search(query)
        }
    }

    /// El resto de la lista de un enlace `watch?v=…&list=…` pasa a la cola, como al abrir el video desde la lista.
    private func queuePlaylist(_ playlistId: String, after item: MediaItem) {
        let service = service
        Task {
            guard let page = try? await service.playlist(playlistId) else { return }
            let items = page.groups.flatMap(\.items).filter(\.isPlayable)
            guard items.contains(where: { $0.videoId == item.videoId }) else { return }
            queue.load(playlist: items, after: item, title: page.title)
        }
    }

    /// Para ir a otra página con un video en la ventana: el video sigue en el minirreproductor.
    func leavePlayerForBrowsing() {
        if player != nil, playerPresentation == .full { enterMiniPlayer() }
    }

    /// ⌘V con un enlace de YouTube en el portapapeles.
    func openPasteboard() {
        let pasteboard = NSPasteboard.general
        let texts = [NSPasteboard.PasteboardType.URL, .string].compactMap { pasteboard.string(forType: $0) }
        if !openExternal(texts.first(where: { YouTubeLink.parse($0) != nil }) ?? texts.first ?? "", from: "pegar") {
            show(banner: "Para abrirlo aquí, copia un enlace de YouTube (youtube.com o youtu.be)")
        }
    }

    /// Un enlace arrastrado a la ventana (desde Safari, Mensajes, Notas…).
    func openDropped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) })
                ?? providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                let text = url?.absoluteString ?? ""
                Task { @MainActor in self.droppedText(text) }
            }
        } else {
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                let text = string ?? ""
                Task { @MainActor in self.droppedText(text) }
            }
        }
        return true
    }

    private func droppedText(_ text: String) {
        if !openExternal(text, from: "arrastrar") {
            show(banner: "Eso no es un enlace de YouTube")
        }
    }

    // MARK: - Dock

    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem.make("Inicio", symbol: "house") { [weak self] in self?.goToSection(.home) })
        menu.addItem(ActionMenuItem.make("Suscripciones", symbol: "play.rectangle.on.rectangle") { [weak self] in self?.goToSection(.subscriptions) })
        let continueWatching = NSMenuItem(title: "Seguir viendo", action: nil, keyEquivalent: "")
        continueWatching.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)
        let submenu = NSMenu()
        let videos = library.continueWatching.prefix(6)
        if videos.isEmpty {
            let empty = NSMenuItem(title: "Nada a medias", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for saved in videos {
            let left = saved.duration.map { max(0, $0 - saved.position) }
            let title = deArrow.title(for: saved.item)
            let label = left.map { "\(title.count > 60 ? String(title.prefix(58)) + "…" : title) — quedan \(Format.time($0))" } ?? title
            submenu.addItem(ActionMenuItem.make(label) { [weak self] in
                self?.bringToFront()
                self?.play(saved.item)
            })
        }
        submenu.addItem(.separator())
        submenu.addItem(ActionMenuItem.make("Todo el historial", symbol: "clock.arrow.circlepath") { [weak self] in self?.goToSection(.history) })
        continueWatching.submenu = submenu
        menu.addItem(continueWatching)
        return menu
    }

    /// Una sección de la barra lateral desde fuera (Dock): con un video en la ventana, el video sigue en el
    /// minirreproductor.
    func goToSection(_ section: SidebarItem) {
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
        leavePlayerForBrowsing()
        navigator.go(.section(section))
    }
}

/// Lo que se puede soltar en la ventana: un enlace o texto con uno.
enum DropTypes {
    static let accepted: [UTType] = [.url, .plainText]
}
