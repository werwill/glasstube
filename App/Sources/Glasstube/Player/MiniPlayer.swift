import AppKit
import PlaybackKit
import SwiftUI
import YTKit

/// Minirreproductor flotante: el "PiP" con el motor mpv (hallazgos/05). Es un `NSPanel` sin marco, siempre visible y
/// en todos los Spaces, con el video (la misma vista del motor: se pasa de la ventana principal a esta sin cortar la
/// reproducción) y controles de vidrio que aparecen al pasar el puntero. Con `AVEngine` (directos) se usa en cambio el
/// Picture in Picture del sistema.
@MainActor
final class MiniPlayerController {
    private var panel: MiniPanel?
    private var pictureInPicture: PictureInPicture?

    static let defaultSize = NSSize(width: 448, height: 252)
    static let margin: CGFloat = 20

    var isVisible: Bool { panel?.isVisible == true }
    var isPictureInPictureActive: Bool { pictureInPicture?.isActive == true }
    /// Número de ventana del minirreproductor (capturas).
    var windowNumber: Int? { panel?.windowNumber }

    func show(player: PlayerModel, app: AppModel) {
        close()
        let panel = MiniPanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.minSize = NSSize(width: 288, height: 162)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let root = MiniPlayerView(player: player)
            .environment(app)
            .environment(app.settings)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.wantsLayer = true
        host.layer?.cornerRadius = 16
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        panel.contentView = host
        // Donde se dejó la última vez; si no, abajo a la derecha de la pantalla de la ventana principal.
        if !panel.setFrameUsingName(Self.autosaveName) {
            let screen = NSApp.mainWindow?.screen ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.defaultSize.width - Self.margin, y: visible.minY + Self.margin))
            }
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        panel.orderFrontRegardless()
        self.panel = panel
        if let path = UserDefaults.standard.string(forKey: "GTMiniWindowFile") {
            try? String(panel.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static let autosaveName = "GlasstubeMiniPlayer"

    func close() {
        pictureInPicture?.onStop = nil
        pictureInPicture?.onRestore = nil
        pictureInPicture?.stop()
        pictureInPicture = nil
        guard let panel else { return }
        panel.saveFrame(usingName: Self.autosaveName)
        // Primero se suelta la vista del video, para que el reproductor de la ventana la pueda tomar.
        panel.contentView = nil
        panel.orderOut(nil)
        self.panel = nil
    }

    /// PiP del sistema para un directo (AVPlayer). Falso si macOS no lo da: entonces se usa la ventana flotante.
    func startPictureInPicture(engine: AVEngine, app: AppModel) -> Bool {
        guard PictureInPicture.isSupported, let pip = engine.makePictureInPicture() else { return false }
        pip.onRestore = { [weak app] in app?.expandPlayer() }
        // Al cerrar la ventanita del sistema, el video vuelve a la ventana (como en Safari).
        pip.onStop = { [weak app] in
            guard let app, app.playerPresentation == .pip else { return }
            app.expandPlayer()
        }
        pictureInPicture = pip
        pip.start()
        return true
    }
}

/// Panel sin marco que sí acepta el teclado (espacio, Retorno para volver, Esc para cerrar).
final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Contenido del minirreproductor: video y, al pasar el puntero, título, volver a la ventana, cerrar, ±10 s,
/// play/pausa y el progreso, en un solo `GlassEffectContainer`.
struct MiniPlayerView: View {
    let player: PlayerModel
    @Environment(AppModel.self) private var app
    @ViewState private var hovering = false
    @FocusState private var focused: Bool

    private var showsControls: Bool { hovering || !player.isPlaying || Automation.shared.keepControls }

    var body: some View {
        ZStack {
            Color.black
            if let engine = player.engine {
                PlayerVideoView(engine: engine, isActive: app.playerPresentation == .mini)
                    .accessibilityLabel("Video: \(player.title)")
            }
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(false)
            if player.isLoading {
                ProgressView().controlSize(.small)
            }
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(player.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                        Spacer(minLength: 6)
                        MiniButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Volver a la ventana (Retorno)") { app.expandPlayer() }
                        MiniButton(symbol: "xmark", label: "Cerrar (Esc)") { app.closePlayer() }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        MiniButton(symbol: "gobackward.10", label: "Atrás 10 s") { player.seek(by: -10) }
                        MiniButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", label: player.isPlaying ? "Pausar" : "Reproducir",
                                   size: 40) { player.togglePause() }
                        MiniButton(symbol: "goforward.10", label: "Adelante 10 s") { player.seek(by: 10) }
                        if player.nextItem != nil {
                            MiniButton(symbol: "forward.end.fill", label: "Siguiente") { player.playNext() }
                        }
                    }
                    Spacer(minLength: 0)
                    MiniProgress(player: player)
                }
                .padding(10)
                .opacity(showsControls ? 1 : 0)
            }
        }
        .foregroundStyle(.white)
        .contentShape(.rect)
        .onHover { inside in withAnimation(.smooth(duration: 0.2)) { hovering = inside } }
        .onTapGesture(count: 2) { app.expandPlayer() }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .space: player.togglePause()
            case .return: app.expandPlayer()
            case .escape: app.closePlayer()
            case .leftArrow: player.seek(by: -5)
            case .rightArrow: player.seek(by: 5)
            default:
                switch press.characters.lowercased() {
                case "k": player.togglePause()
                case "j": player.seek(by: -10)
                case "l": player.seek(by: 10)
                case "i": app.expandPlayer()
                case "m": player.toggleMute()
                default: return .ignored
                }
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Minirreproductor")
    }
}

/// Botón de vidrio del minirreproductor (los controles flotan sobre el video: cada uno es una pieza del contenedor).
struct MiniButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Barra fina de progreso al pie (no se arrastra: para eso está la ventana).
struct MiniProgress: View {
    let player: PlayerModel

    var body: some View {
        HStack(spacing: 8) {
            Text(Format.time(player.position)).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule().fill(.white).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 4)
            Text(player.item.isLive ? "EN VIVO" : Format.time(player.duration)).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement()
        .accessibilityLabel("Progreso")
        .accessibilityValue("\(Format.time(player.position)) de \(Format.time(player.duration))")
    }

    private var fraction: Double {
        guard let duration = player.duration, duration > 0 else { return 0 }
        return min(1, max(0, player.position / duration))
    }
}
