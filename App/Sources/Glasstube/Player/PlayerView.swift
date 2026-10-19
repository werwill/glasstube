import AppKit
import PlaybackKit
import SwiftUI
import YTKit

/// Reproductor a pantalla completa (dentro de la ventana o en pantalla completa con F).
///
/// - Un solo `GlassEffectContainer` para todos los controles: barra superior, cápsula de controles, burbuja del
///   storyboard, aviso y "Saltar patrocinio" (teñido). Al ocultarse, la cápsula se transforma en una barra mínima de
///   progreso con el mismo `glassEffectID`: el sistema hace el cambio de forma.
/// - Degradado oscuro bajo los controles y vidrio `.regular` (nunca `.clear`) para que se lean sobre un video claro.
/// - Los controles aparecen con el puntero y con cualquier tecla, y el foco del teclado entra en ellos.
/// - Siempre en apariencia oscura, como el reproductor de la maqueta y los del sistema: el video manda.
/// - Panel lateral (descripción, capítulos, comentarios, chat, sugeridos): otra pieza del mismo contenedor, a la
///   derecha; el video se encoge a la izquierda para no quedar tapado.
struct PlayerView: View {
    let player: PlayerModel

    @Environment(AppModel.self) private var app
    @Namespace private var glass
    @FocusState private var keyFocus: Bool

    /// Ancho que ocupa el panel lateral abierto (con sus márgenes): el video queda a su izquierda.
    private var reserved: CGFloat { player.panelTab != nil ? SidePanel.width + 24 + 12 : 0 }

    var body: some View {
        ZStack {
            Color.black
            if let engine = player.engine {
                PlayerVideoView(engine: engine, isActive: app.playerPresentation == .full)
                    .padding(.trailing, reserved)
                    .accessibilityLabel("Video: \(player.title)")
            }
            Color.clear
                .contentShape(.rect)
                .onTapGesture(count: 2) { player.toggleFullScreen() }
                .onTapGesture { player.togglePause() }
                .padding(.trailing, reserved)
            scrims
            stateOverlay
                .padding(.trailing, reserved)
            GlassEffectContainer(spacing: 18) {
                HStack(spacing: 12) {
                    chrome
                    if player.panelTab != nil {
                        SidePanel()
                            .glassEffect(.regular, in: .rect(cornerRadius: 28))
                            .glassEffectID("panel", in: glass)
                            .padding(.top, 20)
                            .padding(.bottom, 28)
                            .padding(.trailing, 24)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .coordinateSpace(.named(PlayerSpace.name))
        .environment(player)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($keyFocus)
        .onAppear { keyFocus = true }
        .onChange(of: player.popover) { _, popover in if popover == nil { keyFocus = true } }
        .onKeyPress(phases: [.down, .repeat]) { press in
            PlayerKeyboard(player: player, app: app).handle(press)
        }
        .onContinuousHover { phase in
            if case .active = phase { player.bumpControls() }
        }
        .background(WindowAccessor { player.window = $0 })
        .animation(.smooth(duration: 0.35), value: player.controlsVisible)
        .animation(.smooth(duration: 0.25), value: player.activeSegment?.id)
        .animation(.smooth(duration: 0.3), value: player.panelTab == nil)
        .animation(.smooth(duration: 0.25), value: player.upNext?.item.id)
    }

    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.38), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
            Spacer(minLength: 0)
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                .frame(height: 300)
        }
        .opacity(player.controlsVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Aviso de LOGIN_REQUIRED sin cuenta: se ofrece iniciar sesión (al iniciarla, queda solo «Reintentar»).
    private var offersSignIn: Bool { player.failureNeedsSignIn && !app.accounts.isSignedIn }

    @ViewBuilder
    private var stateOverlay: some View {
        if let failure = player.failure {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 34))
                Text("No se pudo reproducir").font(.title2.bold())
                Text(failure).font(.callout).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                if offersSignIn {
                    Text("YouTube a veces lo pide a quien ve sin cuenta. Con una cuenta iniciada, Glasstube pide los videos con ella.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                HStack {
                    Button("Volver") { app.closePlayer() }
                        .buttonStyle(.glass)
                    if offersSignIn {
                        Button("Iniciar sesión…") { app.accounts.beginSignIn() }
                            .buttonStyle(.glass)
                    }
                    Button("Reintentar") { player.replace(with: player.item, remember: false) }
                        .buttonStyle(.glassProminent)
                }
                .controlSize(.large)
            }
            .padding(30)
        } else if !player.hasStartedPlaying {
            // Hasta el primer cuadro: la miniatura del video (no un negro mudo) y el indicador.
            ZStack {
                RemoteImage(urls: MediaItemImages.banner(player.item), contentMode: .fit)
                    .overlay { LateImage(url: app.deArrow.thumbnailURL(for: player.item)) }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .opacity(0.55)
                    .accessibilityHidden(true)
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Cargando el video")
            }
            .allowsHitTesting(false)
        } else if player.isWaiting {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel("Esperando datos")
        }
    }

    @ViewBuilder
    private var chrome: some View {
        VStack(spacing: 0) {
            if player.controlsVisible {
                PlayerTopBar()
                    .padding(.top, 20)
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let toast = player.toast {
                Text(toast)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("toast", in: glass)
                    .padding(.top, 16)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if let upNext = player.upNext {
                    UpNextCard(upNext: upNext)
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
                        .glassEffectID("upnext", in: glass)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if let segment = player.activeSegment {
                    SkipSegmentButton(segment: segment, remaining: segment.end - player.position)
                        .glassEffectID("skip", in: glass)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            // Con un menú abierto (sale sobre su botón, a la derecha), "Saltar" se hace a un lado como en la maqueta; con la
            // burbuja del storyboard a la vista, sube por encima de ella.
            .padding(.trailing, player.popover == nil ? 32 : 446)
            .padding(.bottom, (player.controlsVisible ? 16 : 14) + (player.controlsVisible && player.scrubTime != nil ? StoryboardBubble.height + 8 : 0))

            if player.controlsVisible {
                PlayerControlsCapsule()
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
                    .glassEffectID("controls", in: glass)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)
            } else {
                CollapsedProgress()
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("controls", in: glass)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 22)
            }
        }
        .overlay(alignment: .topLeading) {
            if player.controlsVisible, let time = player.scrubTime {
                StoryboardBubble(time: time)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    .glassEffectID("bubble", in: glass)
                    .position(x: player.scrubX, y: player.scrubBarTop - 26 - StoryboardBubble.height / 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
}

enum PlayerSpace {
    static let name = "player"
}

/// Barra mínima de progreso cuando los controles están ocultos (el mismo vidrio, encogido).
struct CollapsedProgress: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.24))
                Capsule().fill(.white)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 6)
        .padding(2)
        .accessibilityElement()
        .accessibilityLabel("Progreso")
        .accessibilityValue("\(Format.time(player.position)) de \(Format.time(player.duration))")
    }

    private var fraction: Double {
        guard let duration = player.duration, duration > 0 else { return 0 }
        return min(1, max(0, player.position / duration))
    }
}

/// "Saltar patrocinio · 0:44": cápsula de vidrio teñida (verde de SponsorBlock).
struct SkipSegmentButton: View {
    let segment: SponsorSegment
    let remaining: Double
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Button { player.skipActiveSegment() } label: {
            HStack(spacing: 10) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text(segment.skipTitle)
                    .font(.system(size: 15, weight: .semibold))
                Text(Format.time(max(0, remaining)))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.3), in: .capsule)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 48)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(segment.color.opacity(0.55)).interactive(), in: .capsule)
        .overlay {
            if player.focusedControl == .skip {
                Capsule().strokeBorder(.white, lineWidth: 2).padding(-3)
            }
        }
        .accessibilityLabel("\(segment.skipTitle), quedan \(Format.time(max(0, remaining)))")
        .help("\(segment.skipTitle) (Retorno con el foco)")
    }
}

/// Burbuja de vidrio con el cuadro del storyboard sobre la barra al adelantar.
struct StoryboardBubble: View {
    let time: Double
    @Environment(PlayerModel.self) private var player
    @ViewState private var image: NSImage?

    static let width: CGFloat = 188
    static let height: CGFloat = 6 + (width - 12) * 9 / 16 + 6 + 18 + 6

    var body: some View {
        VStack(spacing: 6) {
            Rectangle().fill(.black.opacity(0.4))
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: Self.width - 12, height: (Self.width - 12) * 9 / 16)
                .clipped()
            .clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true))
            HStack(spacing: 8) {
                Text(Format.time(time)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Spacer(minLength: 0)
                if let chapter = player.chapter(at: time) {
                    Text(chapter.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.84)).lineLimit(1)
                }
            }
            .frame(height: 18)
            .padding(.horizontal, 6)
        }
        .padding(6)
        .frame(width: Self.width, height: Self.height)
        .containerShape(.rect(cornerRadius: 18))
        .task(id: Int(time)) {
            guard let storyboard = player.extras?.storyboard, let duration = player.duration,
                  let (url, rect) = storyboard.frame(at: time, duration: duration),
                  let sheet = await ImagePipeline.shared.image(for: url) else { return }
            image = StoryboardSpec.crop(sheet, rect: rect)
        }
        .accessibilityHidden(true)
    }
}

/// «A continuación» al terminar: miniatura, título y cuenta atrás, con «Reproducir ahora» (Retorno) y «Cancelar» (Esc).
/// Los botones van sin vidrio propio: son parte de esta pieza.
struct UpNextCard: View {
    let upNext: UpNext
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(urls: MediaItemImages.card(upNext.item, width: 320))
                .overlay { LateImage(url: app.deArrow.thumbnailURL(for: upNext.item)) }
                .frame(width: 128, height: 72)
                .clipShape(.rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let remaining = max(0, Int(upNext.deadline.timeIntervalSince(context.date).rounded(.up)))
                    Text(upNext.fromQueue ? "Sigue en la cola · \(remaining) s" : "A continuación · \(remaining) s")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(app.deArrow.title(for: upNext.item))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: .leading)
                HStack(spacing: 8) {
                    Button { player.playUpNext() } label: {
                        Label("Reproducir ahora", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Capsule().fill(.white.opacity(0.24)))
                            .contentShape(.capsule)
                    }
                    Button { player.cancelUpNext() } label: {
                        Text("Cancelar")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Capsule().fill(.white.opacity(0.1)))
                            .contentShape(.capsule)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("A continuación: \(app.deArrow.title(for: upNext.item))")
    }
}
