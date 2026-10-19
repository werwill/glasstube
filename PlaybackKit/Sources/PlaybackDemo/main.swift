import AppKit
import PlaybackKit
import SwiftUI

// Demo mínima (sin diseño): una ventana que reproduce un videoId público con MPVEngine por SABR y permite pausar,
// buscar y cambiar de calidad. Con --seek-at/--switch-at/--stop-at corre sola y deja un reporte (ver DemoOptions).

// Ciclo de vida AppKit con la vista en SwiftUI (NSHostingView): un ejecutable de SwiftPM sin bundle no llega a abrir
// la ventana de un `WindowGroup`. Sin @State: con solo Command Line Tools no está el plugin de macros de SwiftUI, así
// que el estado vive en el modelo (@Observable).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: DemoModel
    var window: NSWindow?

    init(model: DemoModel) {
        self.model = model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PlaybackDemo"
        window.contentView = NSHostingView(rootView: ContentView(model: model).frame(minWidth: 640, minHeight: 420))
        window.isReleasedWhenClosed = false
        if model.options.onTop { window.level = .floating }
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        model.window = window
        NSApp.activate()
        observeOcclusion(of: window)
        if let path = model.options.windowFile { try? String(window.windowNumber).write(toFile: path, atomically: true, encoding: .utf8) }
        obscure(window)
        Task { await model.start() }
    }

    private var observers: [NSObjectProtocol] = []
    private var cover: NSWindow?

    /// Anota cuándo macOS deja de componer la ventana y cuándo vuelve a hacerlo.
    private func observeOcclusion(of window: NSWindow) {
        let model = model
        model.record("ventana: \(window.occlusionState.contains(.visible) ? "visible" : "no visible")")
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                                queue: .main) { _ in
            MainActor.assumeIsolated { model.record("ventana: \(window.occlusionState.contains(.visible) ? "visible" : "no visible")") }
        })
    }

    /// `--cover`, `--hide` y `--minimize`: la ventana queda fuera de la vista desde antes de cargar el video.
    private func obscure(_ window: NSWindow) {
        let options = model.options
        if let seconds = options.cover {
            let cover = NSWindow(contentRect: window.frame.insetBy(dx: -40, dy: -40), styleMask: [.borderless], backing: .buffered, defer: false)
            cover.backgroundColor = .darkGray
            cover.isOpaque = true
            cover.level = .floating
            cover.isReleasedWhenClosed = false
            cover.orderFrontRegardless()
            self.cover = cover
            model.record(String(format: "ventana tapada por otra opaca durante %.0f s", seconds))
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated {
                    self?.cover?.orderOut(nil)
                    self?.model.record("se quita la ventana que tapaba")
                }
            }
        }
        if let seconds = options.hide {
            DispatchQueue.main.async { NSApp.hide(nil) }
            model.record(String(format: "app oculta durante %.0f s", seconds))
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated {
                    NSApp.unhide(nil)
                    self?.model.record("app visible otra vez")
                }
            }
        }
        if let seconds = options.minimize {
            window.miniaturize(nil)
            model.record(String(format: "ventana minimizada durante %.0f s", seconds))
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated {
                    window.deminiaturize(nil)
                    self?.model.record("ventana restaurada")
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    let model: DemoModel

    var body: some View {
        VStack(spacing: 8) {
            if let engine = model.engine {
                PlayerVideoView(engine: engine)
                    .aspectRatio(model.options.fill ? nil : 16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                controls(engine.status)
            } else {
                Spacer()
                Text(model.failure ?? "Cargando \(model.options.videoId)…")
                Spacer()
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func controls(_ status: PlayerStatus) -> some View {
        HStack {
            Button(status.state == .playing || status.state == .buffering ? "Pausa" : "Reproducir") { model.togglePause() }
                .keyboardShortcut(.space, modifiers: [])
            Button("−10 s") { model.seek(by: -10) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("+10 s") { model.seek(by: 10) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("+60 s") { model.seek(by: 60) }.keyboardShortcut(.upArrow, modifiers: [])
            Slider(value: Binding(get: { model.scrubbing ?? status.position }, set: { model.scrubbing = $0 }),
                   in: 0...max(1, status.duration ?? 1)) { editing in
                if !editing, let target = model.scrubbing {
                    model.seek(to: target)
                    model.scrubbing = nil
                }
            }
            Text(String(format: "%@ / %@", Self.time(status.position), status.duration.map(Self.time) ?? "--:--"))
                .monospacedDigit()
            Picker("Calidad", selection: Binding(get: { status.selectedVideoTrack?.id ?? "" }, set: { id in
                if let track = status.videoTracks.first(where: { $0.id == id }) { model.select(track) }
            })) {
                ForEach(status.videoTracks) { track in Text(track.title).tag(track.id) }
            }
            .frame(width: 200)
            Button("−") { if let t = model.qualityTrack(step: -1) { model.select(t) } }.keyboardShortcut("-", modifiers: [])
            Button("+") { if let t = model.qualityTrack(step: 1) { model.select(t) } }.keyboardShortcut("=", modifiers: [])
        }
        HStack {
            Text(verbatim: "\(status.state)")
            Text(status.videoDescription ?? "-")
            Text("por delante: " + (status.buffer.ahead.map { String(format: "%.1f s", $0) } ?? "-"))
            Text("caídos: \(status.droppedFrames)/\(status.decoderDroppedFrames)")
            Spacer()
            Text(model.lastNote).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
        }
        .font(.caption)
        .monospacedDigit()
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// Un ejecutable sin bundle arranca con la política `.prohibited`: sin esto no se ve ninguna ventana.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { AppDelegate(model: DemoModel(options: DemoOptions(arguments: CommandLine.arguments))) }
app.delegate = delegate
app.run()
