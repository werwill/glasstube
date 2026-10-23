import AppKit
import CoreSpotlight
import Foundation
import YTKit

/// Opciones de arranque para pruebas y capturas automáticas (dominio de argumentos de `UserDefaults`):
///
///     Glasstube -GTWindowFile /tmp/w.txt -GTWindowSize 1440x900 -appearance dark
///     Glasstube -GTPlay aqz-KE-bpKQ -GTStartAt 200 -GTKeepControls YES -GTPopover quality -GTScrub 260
///
/// - `GTWindowFile`: escribe ahí el número de la ventana principal (para `screencapture -l`).
/// - `GTWindowSize`: tamaño de la ventana en puntos.
/// - `GTPlay`, `GTStartAt`: abre ese video al arrancar (`GTLive YES`: es un directo, va por HLS con `AVEngine`).
/// - `GTKeepControls`: los controles del reproductor no se ocultan.
/// - `GTPopover`: abre ese menú (quality, speed, captions, audio, more) unos segundos después de cargar.
/// - `GTScrub`: muestra la burbuja del storyboard en ese segundo, como si el puntero estuviera sobre la barra.
/// - `GTSponsorDemo`: `inicio-fin` en segundos; añade un tramo de patrocinio DE PRUEBA al video (solo para capturas).
/// - `GTHidden`: oculta los controles al cargar (para la captura de la barra mínima).
/// - `GTSearch` (resultados), `GTSearchText` (campo con sugerencias), `GTChannel` (UC…, @handle), `GTSection`
///   (`music`, `history`…): navegación al arrancar.
/// - `GTSignIn`: abre la hoja de inicio de sesión (pide un código real a YouTube).
/// - `GTPlaylistPicker`: abre "Guardar en una playlist" para ese video (con sesión).
/// - `GTAccountMenu`: abre el menú de cuenta de la toolbar a los N segundos (capturas).
/// - `GTSinCorreo`: la cuenta se ve con su nombre y avatar, pero ningún correo (capturas).
/// - `GTWindowFrameFile`: escribe ahí el marco de la ventana en pantalla, `x,y,ancho,alto` desde arriba a la izquierda
///   (para `screencapture -R`, que sí incluye los menús abiertos); `GTWindowRight` la pega al borde derecho de la
///   pantalla para que el menú de cuenta quede dentro de la ventana.
/// - `GTAnonimo`: en pantalla, la cuenta se llama "Cuenta de prueba" y no muestra correo ni avatar (capturas).
/// - `GTOpenSettings`: abre Ajustes con ⌘, y `GTWindowFile` pasa a ser esa ventana (`-settingsTab player` elige la
///   pestaña).
/// - `GTHoverIndex`: la tarjeta N de "Para ti" se comporta como si tuviera el puntero encima (vista previa).
/// - `GTPanel`: abre el panel lateral del reproductor en esa pestaña (description, chapters, comments, chat, suggestions);
///   `GTPanelFocus N` pone el foco del teclado en su fila N. `GTSinPersonas`: quien comenta sale como `@personaN`.
/// - `GTQueue`: `id,id,…` en la cola. `GTMini N`: pasa al minirreproductor a los N s de cargar (`GTMiniWindowFile`:
///   escribe ahí su número de ventana). `GTMiniDrag dx;dy`: luego lo arrastra desde el centro dx, dy puntos (y hacia
///   arriba) con eventos de ratón en la cola, como el ratón de verdad, y anota dónde quedó. Un valor que empieza con
///   «-» se toma como otra opción: los negativos van con un espacio delante (`-GTMiniDrag " -1000;350"`).
/// - `GTSinLlavero`: no lee el Llavero (sin sesión; evita el aviso de permiso tras recompilar). `GTLlaveroLento N`:
///   igual, pero la lectura tarda N s (como el aviso del Llavero sin responder).
/// - `GTVerbose`: registro de red de YTKit en stderr.
/// - `GTSimularBot N`: las primeras N respuestas del player de cada video son un LOGIN_REQUIRED («confirma que no eres un
///   bot»); con 1 se ve la recuperación, con 2 el aviso.
/// - `GTCubrir N`: tapa la ventana principal con otra opaca desde el arranque durante N s (prueba del video en negro).
/// - Fase 4: `GTRemoto` (registro del control remoto), `GTRemotoEnMemoria` (pantalla de Lounge nueva, sin tocar la
///   vinculación guardada), `GTPairing N` (abre «Vincular un teléfono» a los N s), `GTCodigoDePrueba` (la hoja muestra
///   el código 123-456-789-012 en lugar de pedir uno: capturas), `GTEnlaces` (registro de enlaces), `GTPegar url`
///   (pone `url` en el portapapeles, manda ⌘V por el menú y deja el portapapeles como estaba), `GTSoltar url` (como si
///   se soltara ese enlace en la ventana), `GTSpotlight` (registro de Spotlight), `GTSpotlightQuery texto` (busca en el
///   índice de la app a los 12 s), `GTSpotlightOpen video:ID` (abre un resultado como lo hace Spotlight),
///   `GTDockMenu título` (escribe el menú del Dock y elige esa opción).
/// - `GTActualizacionesURL url`: el aviso de versiones nuevas consulta esa dirección (también `file:///…/latest.json`, una
///   respuesta simulada de `releases/latest`) en lugar de la API de GitHub, sin el límite de una vez al día.
/// - Fase 5a: `GTGruposEnMemoria` (grupos y suscripciones de esta Mac solo en memoria: no lee ni escribe groups.json),
///   `GTBibliotecaEnMemoria` (lo mismo con library.json: sin historial y sin guardar bloqueos), `GTGrupos
///   "Nombre=UC…,UC…;Otro=UC…"` (crea esos grupos), `GTSuscripcionesLocales "UC…,UC…"`, `GTBloquear "UC…=Nombre;…"`,
///   `GTImportar ruta` (importa ese archivo de PocketTube, GrayJay o NewPipe), `GTGrupo nombre|índice` (abre ese grupo),
///   `GTEditarGrupo nombre` (abre su hoja «Canales del grupo»), `GTNuevoGrupo` (el aviso para nombrar uno),
///   `GTSoloVideos id,id,…` (capturas: los feeds RSS muestran solo esos videos; con `GTWindowFrameFile` la ventana se
///   trae al frente varias veces en los primeros 9 s, para `screencapture -R`), `GTFiltro "tipo=video,fecha=semana,duracion=3-20,prioridad=popularidad,cc"` (filtros de `GTSearch`; el menú de
///   filtros se abre con un clic real, `-GTClicks "9:1340;84"` en una ventana de 1440 pt), `GTRegistroGrupos` (registro
///   de los feeds RSS).
/// - `GTSinPuntero`: las tarjetas no se elevan ni muestran la vista previa por el puntero real (grabaciones y capturas;
///   la de `GTHoverIndex` sí).
/// - `GTKeys`: `segundos:tecla,…` (space, left, right, up, down, return, tab, escape, `cmd+,` o un carácter, p. ej. `j`, `>`):
///   eventos de teclado reales por `NSApp.sendEvent`, contados desde que se carga el video (o el arranque).
final class Automation {
    static let shared = Automation()

    private let defaults = UserDefaults.standard
    private weak var model: AppModel?
    private var didSetUpWindow = false

    var keepControls: Bool { defaults.bool(forKey: "GTKeepControls") }
    /// `GTSimularBot N`: las primeras N respuestas del player de cada video son un LOGIN_REQUIRED (prueba del aviso y
    /// de la recuperación).
    var simulatedBotChecks: Int { defaults.integer(forKey: "GTSimularBot") }
    /// Notas del motor en el registro (`GTKeys`, `GTClicks` o `GTVerbose`).
    var logsNotes: Bool { logsKeys || defaults.bool(forKey: "GTVerbose") }
    /// Capturas: quienes comentan o escriben en el chat salen como `@persona1`… con un círculo en lugar de su foto.
    var masksPeople: Bool { defaults.bool(forKey: "GTSinPersonas") }
    private var people: [String: Int] = [:]

    /// El nombre de quien comenta tal cual o, con `GTSinPersonas`, uno de prueba (el mismo para la misma persona).
    func personName(_ name: String) -> String {
        guard masksPeople else { return name }
        if let number = people[name] { return "@persona\(number)" }
        people[name] = people.count + 1
        return "@persona\(people.count)"
    }
    /// Capturas con sesión: nombre, correo y avatar de la cuenta se cambian por unos de prueba.
    var masksAccount: Bool { defaults.bool(forKey: "GTAnonimo") }
    /// Capturas con sesión: la cuenta se ve tal cual, pero sin correos.
    var hidesEmails: Bool { defaults.bool(forKey: "GTSinCorreo") || masksAccount }
    /// Fase 4: registros del control remoto, de los enlaces y de Spotlight.
    var logsRemote: Bool { defaults.bool(forKey: "GTRemoto") || defaults.bool(forKey: "GTVerbose") }
    var logsLinks: Bool { defaults.bool(forKey: "GTEnlaces") || defaults.string(forKey: "GTPegar") != nil
        || defaults.string(forKey: "GTSoltar") != nil || defaults.bool(forKey: "GTVerbose") }
    var logsSpotlight: Bool { defaults.bool(forKey: "GTSpotlight") || defaults.string(forKey: "GTSpotlightQuery") != nil }
    /// Código de vinculación de prueba (capturas, sin pedirlo a YouTube).
    var demoPairingCode: String? {
        guard let raw = defaults.string(forKey: "GTCodigoDePrueba") else { return nil }
        let digits = raw.filter(\.isNumber)
        return digits.count == 12 ? digits : "123456789012"
    }
    var logsKeys: Bool { defaults.string(forKey: "GTKeys") != nil || defaults.string(forKey: "GTClicks") != nil }
    var hoverIndex: Int? { defaults.object(forKey: "GTHoverIndex") != nil ? defaults.integer(forKey: "GTHoverIndex") : nil }
    /// Video que se trata como si tuviera el puntero encima (`GTHoverIndex`).
    var forcedHoverId: String?
    private weak var window: NSWindow?
    var scrubTime: Double? { defaults.object(forKey: "GTScrub") != nil ? defaults.double(forKey: "GTScrub") : nil }
    /// Fase 5a: filtros de la búsqueda de `GTSearch` (`GTFiltro`).
    var searchFilter: SearchFilter? { defaults.string(forKey: "GTFiltro").flatMap(Self.searchFilter) }
    /// Fase 5a, capturas: los feeds de grupos y suscripciones muestran solo estos videos (`GTSoloVideos id,id,…`), para
    /// elegir contenido Creative Commons sin caras de los feeds reales.
    var onlyVideos: Set<String>? {
        defaults.string(forKey: "GTSoloVideos").map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
    }
    /// Grabaciones: las tarjetas no reaccionan al puntero real (`GTSinPuntero`), que estaría donde lo dejó la persona; la
    /// vista previa sale solo en la de `GTHoverIndex`.
    var ignoresPointer: Bool { defaults.bool(forKey: "GTSinPuntero") }
    /// Fase 5a: registro de los feeds RSS de grupos y suscripciones de esta Mac.
    var logsGroups: Bool { defaults.bool(forKey: "GTRegistroGrupos") || defaults.bool(forKey: "GTVerbose") }

    func attach(to model: AppModel) {
        self.model = model
    }

    func windowDidAppear(_ window: NSWindow) {
        guard !didSetUpWindow else { return }
        didSetUpWindow = true
        // El título va fuera de la barra (la maqueta no lo muestra) y, con el reproductor, no queda una franja de
        // título sobre el video.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        if let size = defaults.string(forKey: "GTWindowSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            var frame = window.frame
            frame.origin.y += frame.height - size[1]
            frame.size = NSSize(width: size[0], height: size[1])
            window.setFrame(frame, display: true)
            window.center()
        }
        if defaults.bool(forKey: "GTWindowRight"), let screen = window.screen ?? NSScreen.main {
            var frame = window.frame
            frame.origin.x = screen.visibleFrame.maxX - frame.width
            window.setFrame(frame, display: true)
        }
        if let path = defaults.string(forKey: "GTWindowFrameFile"), let screen = NSScreen.screens.first {
            let frame = window.frame
            let top = screen.frame.height - frame.maxY
            try? "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))".write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let path = defaults.string(forKey: "GTWindowFile") {
            try? String(window.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
            // Para las capturas: ventana activa (si no, macOS atenúa los controles).
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        self.window = window
        if defaults.object(forKey: "GTCubrir") != nil { cover(window, seconds: defaults.double(forKey: "GTCubrir")) }
        if let model {
            if let query = defaults.string(forKey: "GTSearch") { model.search(query) }
            if let channel = defaults.string(forKey: "GTChannel") { model.navigator.go(.channel(id: channel, title: nil)) }
            if let section = defaults.string(forKey: "GTSection").flatMap(SidebarItem.init(rawValue:)) { model.navigator.go(.section(section)) }
            if let text = defaults.string(forKey: "GTSearchText") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    model.focusSearch()
                    try? await Task.sleep(for: .milliseconds(300))
                    model.searchText = text
                }
            }
            if let videoId = defaults.string(forKey: "GTPlaylistPicker") {
                // La hoja "Guardar en una playlist" de ese video (con sesión).
                var item = MediaItem(kind: .video, title: "Video \(videoId)", renderer: "automation")
                item.videoId = videoId
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    model.playlistPicker = item
                }
            }
            if defaults.object(forKey: "GTAccountMenu") != nil {
                // Capturas: abre el menú de cuenta de la toolbar (el `NSMenuToolbarItem` del `Menu` de SwiftUI) a los N s.
                let delay = max(1, defaults.double(forKey: "GTAccountMenu"))
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    self.openAccountMenu(in: window)
                }
            }
            if defaults.bool(forKey: "GTSignIn") {
                // Pide un código real (vence en 30 min si nadie lo usa) para la captura de la hoja.
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    model.accounts.beginSignIn()
                }
            }
            if defaults.string(forKey: "GTPlay") == nil { scheduleKeys() }
            phase4(model)
            phase5a(model)
            if defaults.bool(forKey: "GTOpenSettings") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    self.press("cmd+,")
                    try? await Task.sleep(for: .seconds(1.5))
                    // Las capturas apuntan entonces a la ventana de Ajustes.
                    let settings = NSApp.windows.last { $0 !== window && $0.isVisible && $0.canBecomeKey }
                    NSApp.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: NSNumber(value: true))
                    settings?.makeKeyAndOrderFront(nil)
                    if let path = self.defaults.string(forKey: "GTWindowFile"), let settings {
                        try? String(settings.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        if let videoId = defaults.string(forKey: "GTPlay"), let model {
            var item = MediaItem(kind: .video, title: videoId, renderer: "automation")
            item.videoId = videoId
            item.isLive = defaults.bool(forKey: "GTLive")
            let start = defaults.object(forKey: "GTStartAt") != nil ? defaults.double(forKey: "GTStartAt") : nil
            Task {
                try? await Task.sleep(for: .seconds(1))
                model.play(item, startAt: start)
            }
        }
    }

    /// Pruebas de la fase 4: vinculación, enlaces, Spotlight y Dock.
    private func phase4(_ model: AppModel) {
        if defaults.object(forKey: "GTPairing") != nil {
            Task {
                try? await Task.sleep(for: .seconds(max(1, defaults.double(forKey: "GTPairing"))))
                model.remote.beginPairing()
                try? await Task.sleep(for: .seconds(2))
                self.forceActivate()
            }
        }
        if let link = defaults.string(forKey: "GTPegar") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                // Lo que había en el portapapeles se guarda y se repone.
                let pasteboard = NSPasteboard.general
                let saved = (pasteboard.pasteboardItems ?? []).map { item in
                    item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
                }
                pasteboard.clearContents()
                pasteboard.setString(link, forType: .string)
                NSLog("Glasstube automation: ⌘V con un enlace en el portapapeles")
                self.press("cmd+v")
                try? await Task.sleep(for: .seconds(1))
                pasteboard.clearContents()
                pasteboard.writeObjects(saved.map { types in
                    let item = NSPasteboardItem()
                    for (type, data) in types { item.setData(data, forType: type) }
                    return item
                })
            }
        }
        if let link = defaults.string(forKey: "GTSoltar") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                let provider = URL(string: link).map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider(object: link as NSString)
                NSLog("Glasstube automation: se suelta un enlace: \(model.openDropped([provider]))")
            }
        }
        if let text = defaults.string(forKey: "GTSpotlightQuery") {
            Task {
                try? await Task.sleep(for: .seconds(defaults.double(forKey: "GTSpotlightQueryDelay").nonZero ?? 12))
                let found = await model.spotlight.query(text)
                NSLog("Glasstube spotlight: «\(text)» → \(found.count): \(found.joined(separator: "; "))")
            }
        }
        if let identifier = defaults.string(forKey: "GTSpotlightOpen") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                // Como cuando se abre un resultado en Spotlight: una actividad de Core Spotlight al delegado.
                let activity = NSUserActivity(activityType: CSSearchableItemActionType)
                activity.userInfo = [CSSearchableItemActivityIdentifier: identifier]
                let handled = NSApp.delegate?.application?(NSApp, continue: activity, restorationHandler: { _ in }) ?? false
                NSLog("Glasstube spotlight: abrir \(identifier) → \(handled ? "atendido" : "sin atender")")
            }
        }
        if let choice = defaults.string(forKey: "GTDockMenu") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                guard let menu = NSApp.delegate?.applicationDockMenu?(NSApp) else {
                    NSLog("Glasstube automation: sin menú del Dock")
                    return
                }
                func describe(_ menu: NSMenu, _ depth: Int) -> [String] {
                    menu.items.flatMap { item -> [String] in
                        let line = String(repeating: "  ", count: depth) + (item.isSeparatorItem ? "—" : item.title) + (item.isEnabled ? "" : " (desactivado)")
                        return [line] + (item.submenu.map { describe($0, depth + 1) } ?? [])
                    }
                }
                NSLog("Glasstube automation: menú del Dock:\n%@", describe(menu, 1).joined(separator: "\n"))
                let all = menu.items + menu.items.flatMap { $0.submenu?.items ?? [] }
                if let item = all.first(where: { $0.title.hasPrefix(choice) }), let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                    try? await Task.sleep(for: .seconds(1))
                    NSLog("Glasstube automation: Dock «\(item.title)» → \(model.navigator.current), reproductor \(model.player?.item.videoId ?? "no")")
                }
            }
        }
    }

    /// Capturas: la app al frente aunque otra tenga el foco (con una hoja abierta, la ventana inactiva sale atenuada).
    /// `activate()` es cooperativo y macOS lo ignora si la persona está usando otra app; esto es lo de antes de macOS 14
    /// (`activateIgnoringOtherApps:`), solo para la automatización.
    func forceActivate() {
        NSApp.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: NSNumber(value: true))
        model?.mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Lo que se pide al cargar un video (menú abierto, controles ocultos, teclas).
    func playerDidLoad(_ player: PlayerModel) {
        scheduleKeys()
        if let name = defaults.string(forKey: "GTPopover") {
            let popover: PlayerPopover? = switch name {
            case "quality": .quality
            case "speed": .speed
            case "captions": .captions
            case "audio": .audio
            case "more": .more
            default: nil
            }
            NSLog("Glasstube automation: abrir el menú \(name) en 4 s")
            Task {
                try? await Task.sleep(for: .seconds(4))
                player.popover = popover
                NSLog("Glasstube automation: menú = \(String(describing: player.popover))")
            }
        }
        if defaults.bool(forKey: "GTHidden") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                player.hideControls()
            }
        }
        if let name = defaults.string(forKey: "GTPanel"), let tab = SidePanelTab(rawValue: name) {
            // El panel lateral en esa pestaña (y, con `GTPanelFocus N`, el foco del teclado en su fila N).
            Task {
                try? await Task.sleep(for: .seconds(2))
                player.togglePanel(tab, keyboard: defaults.object(forKey: "GTPanelFocus") != nil)
                if defaults.object(forKey: "GTPanelFocus") != nil {
                    try? await Task.sleep(for: .seconds(defaults.double(forKey: "GTPanelFocusDelay").nonZero ?? 4))
                    let rows = player.panelRowIDs
                    let index = defaults.integer(forKey: "GTPanelFocus")
                    if rows.indices.contains(index) { player.panelFocus = .row(rows[index]) }
                }
                NSLog("Glasstube automation: panel \(name), filas \(player.panelRowIDs.count)")
                try? await Task.sleep(for: .seconds(10))
                NSLog("Glasstube automation: 10 s después: panel \(String(describing: player.panelTab)), filas \(player.panelRowIDs.count), comentarios \(player.comments?.comments.count ?? -1), chat \(player.chat.map { "\($0.messages.count) mensajes, \($0.state)" } ?? "no")")
            }
        }
        if let ids = defaults.string(forKey: "GTQueue"), let model, model.queue.isEmpty {
            // Videos en la cola (`id,id,…`), como «Agregar a la cola»; el título y el canal salen de `next`.
            Task {
                for id in ids.split(separator: ",").map(String.init) {
                    var item = MediaItem(kind: .video, title: id, renderer: "automation")
                    item.videoId = id
                    if let meta = try? await model.service.metadata(videoId: id) {
                        item.title = meta.title ?? id
                        item.author = meta.author
                        item.viewCountText = meta.shortViewCountText
                    }
                    model.queue.append(item)
                }
                NSLog("Glasstube automation: cola \(model.queue.items.map(\.title))")
            }
        }
        if defaults.object(forKey: "GTMini") != nil, !miniScheduled {
            miniScheduled = true
            Task {
                try? await Task.sleep(for: .seconds(max(1, defaults.double(forKey: "GTMini"))))
                model?.enterMiniPlayer()
                NSLog("Glasstube automation: presentación \(String(describing: model?.playerPresentation)), motor \(String(describing: player.engine.map { type(of: $0) }))")
                try? await Task.sleep(for: .seconds(3))
                NSLog("Glasstube automation: 3 s después: presentación \(String(describing: model?.playerPresentation)), PiP del sistema \(model?.miniPlayer.isPictureInPictureActive == true ? "activo" : "no"), mini \(model?.miniPlayer.isVisible == true ? "visible" : "no")")
                if let raw = defaults.string(forKey: "GTMiniDrag") {
                    let xy = raw.split(separator: ";").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if xy.count == 2 { await dragMiniPlayer(by: CGVector(dx: xy[0], dy: xy[1])) }
                }
                if defaults.object(forKey: "GTMiniExpand") != nil {
                    // `GTMiniExpand N`: vuelve a la ventana N s después.
                    try? await Task.sleep(for: .seconds(defaults.double(forKey: "GTMiniExpand")))
                    model?.expandPlayer()
                    NSLog("Glasstube automation: presentación \(String(describing: model?.playerPresentation)) en %.1f s", player.position)
                }
            }
        }
    }

    private var keysScheduled = false
    private var miniScheduled = false

    /// Arrastra el minirreproductor con `leftMouseDown`, `leftMouseDragged` y `leftMouseUp` en la cola de eventos.
    private func dragMiniPlayer(by delta: CGVector) async {
        guard let number = model?.miniPlayer.windowNumber, let window = NSApp.window(withWindowNumber: number) else { return }
        NSLog("Glasstube automation: minirreproductor antes en %@", NSStringFromRect(window.frame))
        let start = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let steps = 12
        for step in 0...(steps + 1) {
            let type: NSEvent.EventType = step == 0 ? .leftMouseDown : (step > steps ? .leftMouseUp : .leftMouseDragged)
            let progress = CGFloat(min(step, steps)) / CGFloat(steps)
            let screen = NSPoint(x: start.x + delta.dx * progress, y: start.y + delta.dy * progress)
            // En coordenadas de la ventana donde está ahora (se mueve con el arrastre).
            let location = NSPoint(x: screen.x - window.frame.minX, y: screen.y - window.frame.minY)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: number, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { continue }
            NSApp.postEvent(event, atStart: false)
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .seconds(1))
        NSLog("Glasstube automation: minirreproductor después en %@, pantalla útil %@", NSStringFromRect(window.frame),
              NSStringFromRect(window.screen?.visibleFrame ?? .zero))
    }

    private func scheduleKeys() {
        guard !keysScheduled else { return }
        keysScheduled = true
        let start = Date()
        if let raw = defaults.string(forKey: "GTKeys") {
            let steps = raw.split(separator: ",").compactMap { step -> (Double, String)? in
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let time = Double(parts[0]) else { return nil }
                return (time, parts[1])
            }
            Task {
                for (time, key) in steps {
                    let wait = time - Date().timeIntervalSince(start)
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    press(key)
                }
            }
        }
        // `GTClicks`: `segundos:x;y,…` en puntos de la ventana desde la esquina superior izquierda.
        if let raw = defaults.string(forKey: "GTClicks") {
            let steps = raw.split(separator: ",").compactMap { step -> (Double, CGPoint)? in
                let parts = step.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let time = Double(parts[0]) else { return nil }
                let xy = parts[1].split(separator: ";").compactMap { Double($0) }
                return xy.count == 2 ? (time, CGPoint(x: xy[0], y: xy[1])) : nil
            }
            Task {
                for (time, point) in steps {
                    let wait = time - Date().timeIntervalSince(start)
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    click(at: point)
                }
            }
        }
    }

    /// El menú de cuenta como lo abre un clic (un clic sintético en la toolbar no lo abre): el último elemento de menú
    /// de la toolbar, desplegado bajo su botón. Si SwiftUI no usa `NSMenuToolbarItem`, se busca un `NSPopUpButton` o un
    /// botón con menú en las vistas de la toolbar.
    func openAccountMenu(in window: NSWindow) {
        let items = window.toolbar?.items ?? []
        NSLog("Glasstube automation: toolbar: %@", items.map { "\(type(of: $0))(\($0.view.map { "\(type(of: $0))" } ?? "-"))" }.joined(separator: ", "))
        if let item = items.compactMap({ $0 as? NSMenuToolbarItem }).last {
            NSLog("Glasstube automation: menú de cuenta con \(item.menu.items.count) opciones")
            if let view = item.view, view.window != nil {
                item.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 6), in: view)
            } else if let content = window.contentView {
                item.menu.popUp(positioning: nil, at: NSPoint(x: content.bounds.width - 300, y: content.bounds.height - 52), in: content)
            }
            return
        }
        // SwiftUI: el botón del menú es un elemento de accesibilidad con la etiqueta "Cuenta: …"; su acción de
        // presionar lo abre como un clic.
        func find(_ element: Any, depth: Int = 0) -> NSAccessibilityProtocol? {
            guard depth < 40, let node = element as? NSAccessibilityProtocol else { return nil }
            if let label = node.accessibilityLabel(), label.hasPrefix("Cuenta") { return node }
            for child in node.accessibilityChildren() ?? [] {
                if let found = find(child, depth: depth + 1) { return found }
            }
            return nil
        }
        let accountView = items.last?.view
        if let accountView, let element = find(accountView) {
            NSLog("Glasstube automation: menú de cuenta por accesibilidad (%@)", element.accessibilityRole()?.rawValue ?? "?")
            if !element.accessibilityPerformShowMenu() { _ = element.accessibilityPerformPress() }
            return
        }
        // Si no: clic enviado a la ventana en el centro de esa vista.
        if let accountView, accountView.window === window {
            let center = accountView.convert(NSPoint(x: accountView.bounds.midX, y: accountView.bounds.midY), to: nil)
            NSLog("Glasstube automation: menú de cuenta con clic en la vista (%.0f, %.0f)", center.x, center.y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseDown ? 1 : 0) {
                    window.sendEvent(event)
                }
            }
            return
        }
        // Otra forma: el último botón con menú dentro de la barra de título.
        func controls(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(controls) }
        let frameView = window.contentView?.superview
        let candidates = frameView.map(controls)?.filter { ($0 is NSPopUpButton) || (($0 as? NSButton)?.menu != nil) } ?? []
        NSLog("Glasstube automation: botones con menú en la ventana: \(candidates.count)")
        if let popup = candidates.last(where: { $0 is NSPopUpButton }) as? NSPopUpButton {
            popup.performClick(nil)
        } else if let button = candidates.last as? NSButton, let menu = button.menu {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
        }
    }

    /// Clic real dentro de la ventana por `NSApp.sendEvent` (no mueve el puntero del sistema).
    func click(at point: CGPoint) {
        guard let window = window ?? NSApp.keyWindow, let content = window.contentView else { return }
        let location = NSPoint(x: point.x, y: content.bounds.height - point.y)
        NSLog("Glasstube automation: clic en (\(Int(point.x)), \(Int(point.y)))")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// Tecla real por `NSApp.sendEvent` (el mismo camino que el teclado): llega a `onKeyPress` de la vista con foco.
    func press(_ key: String) {
        if !key.hasPrefix("cmd+") { NSLog("Glasstube automation: tecla \(key)") }
        KeyInjector.press(key, in: window ?? NSApp.keyWindow)
    }

    private var coverWindow: NSWindow?

    /// Tapa la ventana con otra opaca (de esta app, por encima) durante unos segundos y anota cuándo macOS deja de
    /// componerla y cuándo vuelve.
    private func cover(_ window: NSWindow, seconds: Double) {
        let cover = NSWindow(contentRect: window.frame.insetBy(dx: -40, dy: -40), styleMask: [.borderless], backing: .buffered, defer: false)
        cover.backgroundColor = .darkGray
        cover.isOpaque = true
        cover.level = .floating
        cover.isReleasedWhenClosed = false
        cover.orderFrontRegardless()
        coverWindow = cover
        NSLog("Glasstube automation: ventana tapada durante %.0f s", seconds)
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                NSLog("Glasstube automation: ventana %@", window.occlusionState.contains(.visible) ? "visible" : "no visible")
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            self.coverWindow?.orderOut(nil)
            self.coverWindow = nil
            NSLog("Glasstube automation: se quitó la ventana que tapaba")
        }
    }

    /// Tramo de prueba (solo con `GTSponsorDemo`). La app normal usa los de SponsorBlock.
    func demoSegments(for videoId: String) -> [SponsorSegment] {
        guard let raw = defaults.string(forKey: "GTSponsorDemo") else { return [] }
        let bounds = raw.split(separator: "-").compactMap { Double($0) }
        guard bounds.count == 2, bounds[1] > bounds[0] else { return [] }
        return [SponsorSegment(start: bounds[0], end: bounds[1], category: "sponsor", uuid: "demo-\(videoId)")]
    }
}

extension Double {
    /// nil si es 0 (opciones `-GT…` ausentes).
    var nonZero: Double? { self == 0 ? nil : self }
}

// MARK: - Fase 5a: grupos, suscripciones de esta Mac, bloqueos y filtros

extension Automation {
    /// `tipo=video,fecha=semana,duracion=3-20,prioridad=popularidad,cc,4k,hd,hdr,vivo,subtitulos` (como `ytkit search --filtro`).
    static func searchFilter(_ text: String) -> SearchFilter {
        var filter = SearchFilter()
        for part in text.lowercased().split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            switch (pair.first ?? "", pair.count > 1 ? pair[1] : "") {
            case ("tipo", "video"): filter.type = .video
            case ("tipo", "shorts"): filter.type = .shorts
            case ("tipo", "canal"): filter.type = .channel
            case ("tipo", "playlist"): filter.type = .playlist
            case ("tipo", "pelicula"): filter.type = .movie
            case ("fecha", "hoy"): filter.uploadDate = .today
            case ("fecha", "semana"): filter.uploadDate = .week
            case ("fecha", "mes"): filter.uploadDate = .month
            case ("fecha", "año"), ("fecha", "ano"): filter.uploadDate = .year
            case ("duracion", "<3"), ("duracion", "corta"): filter.duration = .underThree
            case ("duracion", "3-20"), ("duracion", "media"): filter.duration = .threeToTwenty
            case ("duracion", ">20"), ("duracion", "larga"): filter.duration = .overTwenty
            case ("prioridad", "popularidad"): filter.priority = .popularity
            case ("cc", _): filter.features.insert(.creativeCommons)
            case ("4k", _): filter.features.insert(.uhd)
            case ("hd", _): filter.features.insert(.hd)
            case ("hdr", _): filter.features.insert(.hdr)
            case ("vivo", _): filter.features.insert(.live)
            case ("subtitulos", _): filter.features.insert(.subtitles)
            default: NSLog("Glasstube automation: filtro desconocido «\(part)»")
            }
        }
        return filter
    }

    fileprivate func phase5a(_ model: AppModel) {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "GTWindowFrameFile") != nil {
            // Capturas por región (`screencapture -R`, con menús abiertos): la ventana tiene que estar al frente.
            Task {
                for delay in [1.0, 2.5, 2.5, 2.5] {
                    try? await Task.sleep(for: .seconds(delay))
                    self.forceActivate()
                }
            }
        }
        if let spec = defaults.string(forKey: "GTGrupos") {
            for part in spec.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, !model.groups.groups.contains(where: { $0.title == pair[0] }) else { continue }
                let channels = pair[1].split(separator: ",").map { GroupChannel(id: $0.trimmingCharacters(in: .whitespaces)) }
                model.groups.create(title: pair[0], channels: channels.filter { ChannelGroupImport.isChannelId($0.id) })
            }
            NSLog("Glasstube grupos: \(model.groups.groups.map { "\($0.title) (\($0.channels.count))" }.joined(separator: ", "))")
        }
        if let spec = defaults.string(forKey: "GTSuscripcionesLocales") {
            // `subscribe` pone cada canal primero: se recorren al revés para que queden en el orden dado.
            for id in spec.split(separator: ",").reversed().map({ $0.trimmingCharacters(in: .whitespaces) }) where ChannelGroupImport.isChannelId(id) {
                model.groups.subscribe(GroupChannel(id: id))
            }
        }
        if let spec = defaults.string(forKey: "GTBloquear") {
            for part in spec.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if let id = pair.first { model.library.block(channelId: id, name: pair.count > 1 ? pair[1] : id) }
            }
        }
        if let path = defaults.string(forKey: "GTImportar") {
            NSLog("Glasstube grupos: importar \(URL(fileURLWithPath: path).lastPathComponent) → \(model.importGroups(from: URL(fileURLWithPath: path)))")
        }
        if let name = defaults.string(forKey: "GTGrupo") {
            let byIndex = Int(name).flatMap { model.groups.groups.indices.contains($0) ? model.groups.groups[$0] : nil }
            if let group = model.groups.groups.first(where: { $0.title == name }) ?? byIndex {
                model.navigator.go(.channelGroup(group.id))
            }
        }
        if let name = defaults.string(forKey: "GTEditarGrupo"), let group = model.groups.groups.first(where: { $0.title == name }) {
            Task {
                try? await Task.sleep(for: .seconds(2))
                model.groupEditor = GroupEditorRequest(id: group.id)
                try? await Task.sleep(for: .seconds(1))
                self.forceActivate()
            }
        }
        if defaults.bool(forKey: "GTNuevoGrupo") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                model.groupPrompt = .create(nil)
                try? await Task.sleep(for: .seconds(1))
                self.forceActivate()
            }
        }
    }
}
