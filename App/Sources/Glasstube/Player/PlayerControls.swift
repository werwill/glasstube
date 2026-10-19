import AppKit
import PlaybackKit
import SwiftUI
import YTKit

/// Botón de ícono dentro del vidrio de los controles. No lleva vidrio propio (nunca vidrio sobre vidrio): solo un
/// resalte al pasar el puntero y un anillo cuando tiene el foco del teclado.
struct PlayerIconButton: View {
    let control: PlayerControl
    let symbol: String
    let label: String
    var size: CGFloat = 44
    var iconSize: CGFloat = 19
    /// Fondo suave permanente (play/pausa, subtítulos activos, panel abierto).
    var filled = false
    var help: String?
    /// Número junto al ícono (me gusta, no me gusta): el botón pasa a ser una cápsula.
    var count: String?
    let action: () -> Void

    @Environment(PlayerModel.self) private var player
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: iconSize, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                if let count {
                    Text(count).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
            }
            .padding(.horizontal, count == nil ? 0 : 12)
            .frame(minWidth: size, minHeight: size, maxHeight: size)
            .background {
                Capsule().fill(.white.opacity(filled ? 0.14 : (hovering ? 0.12 : 0)))
            }
            .overlay {
                if player.focusedControl == control {
                    Capsule().strokeBorder(.white, lineWidth: 2)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(help ?? label)
    }
}

/// Botón de texto (velocidad, calidad) con el mismo resalte.
struct PlayerTextButton: View {
    let control: PlayerControl
    let title: String
    let label: String
    var showsChevron = false
    var highlighted = false
    let action: () -> Void

    @Environment(PlayerModel.self) private var player
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                if showsChevron {
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold))
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 56)
            .frame(height: 44)
            .background(Capsule().fill(.white.opacity(highlighted ? 0.18 : (hovering ? 0.12 : 0))))
            .overlay {
                if player.focusedControl == control { Capsule().strokeBorder(.white, lineWidth: 2) }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - Barra superior

/// Arriba a la izquierda: volver, título y canal · capítulo. A la derecha: me gusta, comentarios, descripción y más.
struct PlayerTopBar: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var app
    @Environment(AccountModel.self) private var accounts

    private var channelId: String? { player.item.channelId ?? player.metadata?.channelId }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 8) {
                PlayerIconButton(control: .back, symbol: "chevron.backward", label: "Volver", iconSize: 17, filled: true,
                                 help: "Volver (Esc)") { app.closePlayer() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(1)
                }
                .padding(.trailing, accounts.isSignedIn && channelId != nil ? 4 : 16)
                if accounts.isSignedIn, channelId != nil {
                    PlayerTextButton(control: .subscribe, title: player.isSubscribed == true ? "Suscrito" : "Suscribirse",
                                     label: player.isSubscribed == true ? "Cancelar la suscripción a \(player.author ?? "el canal")" : "Suscribirse a \(player.author ?? "el canal")",
                                     highlighted: player.isSubscribed != true) { player.toggleSubscribe() }
                        .disabled(player.isSubscribed == nil && player.metadata == nil)
                }
            }
            .padding(4)
            .frame(maxWidth: 640, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .glassEffect(.regular, in: .capsule)

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                PlayerIconButton(control: .like, symbol: player.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup",
                                 label: player.likeStatus == .like ? "Quitar me gusta" : "Me gusta",
                                 help: accounts.isSignedIn ? nil : "Me gusta (inicia sesión)", count: player.likeCountText) { player.toggleLike() }
                if accounts.isSignedIn || player.votes != nil {
                    PlayerIconButton(control: .dislike, symbol: player.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                                     label: player.likeStatus == .dislike ? "Quitar no me gusta" : "No me gusta",
                                     help: player.votes != nil ? "No me gusta (estimación de Return YouTube Dislike)" : nil,
                                     count: player.votes.map { DislikeClient.compact($0.dislikes) }) { player.toggleDislike() }
                }
                PlayerIconButton(control: .comments, symbol: player.chat != nil ? "bubble.left.and.text.bubble.right" : "text.bubble",
                                 label: player.chat != nil ? "Chat en vivo" : "Comentarios",
                                 filled: player.panelTab == .comments || player.panelTab == .chat,
                                 help: player.chat != nil ? "Chat en vivo (panel lateral, D)" : "Comentarios (panel lateral, D)") {
                    player.togglePanel(player.chat != nil ? .chat : .comments)
                }
                PlayerIconButton(control: .info, symbol: "info.circle", label: "Descripción, capítulos y sugeridos",
                                 filled: player.panelTab == .description || player.panelTab == .chapters || player.panelTab == .suggestions,
                                 help: "Descripción, capítulos y sugeridos (D)") {
                    if let tab = player.panelTab, tab != .comments, tab != .chat { player.closePanel() } else { player.togglePanel(.description) }
                }
                PlayerIconButton(control: .more, symbol: "ellipsis", label: "Más acciones") { player.popover = .more }
                    .popover(isPresented: popoverBinding(.more), arrowEdge: .bottom) { MoreActionsMenu().playerPopover() }
            }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private var subtitle: String {
        let chapter = player.chapter(at: player.position).map { chapter in
            let number = (player.chapters.firstIndex(of: chapter) ?? 0) + 1
            return "Capítulo \(number): \(chapter.title)"
        }
        return [player.author, chapter].compactMap { $0 }.joined(separator: " · ")
    }

    private func popoverBinding(_ kind: PlayerPopover) -> Binding<Bool> {
        Binding(get: { player.popover == kind }, set: { if !$0, player.popover == kind { player.popover = nil } })
    }
}

// MARK: - Cápsula de controles

struct PlayerControlsCapsule: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var app

    /// Con AVPlayer (directos) es el PiP del sistema; con mpv, la ventana flotante propia.
    private var pipLabel: String {
        player.engine is AVEngine && PictureInPicture.isSupported ? "Imagen en imagen" : "Minirreproductor flotante"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(Format.time(player.isDragging ? (player.scrubTime ?? player.position) : player.position))
                    .frame(minWidth: 44, alignment: .leading)
                SeekBar()
                if player.item.isLive {
                    HStack(spacing: 5) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text("EN VIVO")
                    }
                    .frame(minWidth: 44, alignment: .trailing)
                    .accessibilityElement(children: .combine)
                } else {
                    Text(Format.time(player.duration))
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .monospacedDigit()

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    PlayerIconButton(control: .previous, symbol: "backward.end.fill", label: "Video anterior", iconSize: 18) {
                        player.playPrevious()
                    }
                    PlayerIconButton(control: .playPause, symbol: player.isPlaying ? "pause.fill" : "play.fill",
                                     label: player.isPlaying ? "Pausar" : "Reproducir", size: 52, iconSize: 24, filled: true,
                                     help: player.isPlaying ? "Pausar (espacio o K)" : "Reproducir (espacio o K)") {
                        player.togglePause()
                    }
                    PlayerIconButton(control: .next, symbol: "forward.end.fill", label: "Siguiente video", iconSize: 18) {
                        player.playNext()
                    }
                    .disabled(player.nextItem == nil)
                    PlayerIconButton(control: .mute, symbol: volumeSymbol, label: player.status?.isMuted == true ? "Activar sonido" : "Silenciar",
                                     iconSize: 18, help: "Volumen (M silencia)") {
                        player.toggleMute()
                    }
                    VolumeSlider()
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    PlayerTextButton(control: .speed, title: Format.rate(player.status?.rate ?? 1),
                                     label: "Velocidad de reproducción: \(Format.rate(player.status?.rate ?? 1))",
                                     highlighted: player.popover == .speed) { player.popover = .speed }
                        .popover(isPresented: binding(.speed), arrowEdge: .top) { SpeedMenu().playerPopover() }
                    PlayerIconButton(control: .captions, symbol: "captions.bubble", label: captionsLabel, iconSize: 18,
                                     filled: player.captionTrack != nil, help: "Subtítulos (C activa o quita)") { player.popover = .captions }
                        .popover(isPresented: binding(.captions), arrowEdge: .top) { CaptionsMenu().playerPopover() }
                    PlayerIconButton(control: .audio, symbol: "waveform", label: "Pista de audio", iconSize: 18) { player.popover = .audio }
                        .popover(isPresented: binding(.audio), arrowEdge: .top) { AudioMenu().playerPopover() }
                    PlayerTextButton(control: .quality, title: qualityTitle, label: "Calidad de video: \(qualityTitle)",
                                     showsChevron: true, highlighted: player.popover == .quality) { player.popover = .quality }
                        .popover(isPresented: binding(.quality), arrowEdge: .top) { QualityMenu().playerPopover() }
                    Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 22).padding(.horizontal, 6)
                        .accessibilityHidden(true)
                    PlayerIconButton(control: .pip, symbol: player.engine is AVEngine ? "pip.enter" : "pip", label: pipLabel, iconSize: 18,
                                     help: "\(pipLabel) (I)") { app.enterMiniPlayer() }
                    PlayerIconButton(control: .fullscreen, symbol: player.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                     label: player.isFullScreen ? "Salir de pantalla completa" : "Pantalla completa", iconSize: 18,
                                     help: "Pantalla completa (F)") { player.toggleFullScreen() }
                }
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var volumeSymbol: String {
        guard let status = player.status, !status.isMuted, status.volume > 0 else { return "speaker.slash.fill" }
        return status.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    private var captionsLabel: String {
        player.captionTrack.map { "Subtítulos: \($0.title)" } ?? "Subtítulos: desactivados"
    }

    private var qualityTitle: String {
        guard let track = player.status?.selectedVideoTrack else { return "Auto" }
        return Format.quality(track)
    }

    private func binding(_ kind: PlayerPopover) -> Binding<Bool> {
        Binding(get: { player.popover == kind }, set: { if !$0, player.popover == kind { player.popover = nil } })
    }
}

struct VolumeSlider: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Slider(value: Binding(get: { player.status?.isMuted == true ? 0 : player.status?.volume ?? 1 },
                              set: { player.setVolume($0) }), in: 0...1)
            .controlSize(.mini)
            .tint(.white)
            .frame(width: 76)
            .accessibilityLabel("Volumen")
    }
}

// MARK: - Barra de progreso

/// Barra con lo visto, lo descargado, cortes de capítulo y tramos de SponsorBlock (con borde para que se distingan
/// sobre cualquier imagen). Al pasar el puntero muestra la burbuja del storyboard; arrastrar busca al soltar.
struct SeekBar: View {
    @Environment(PlayerModel.self) private var player
    @ViewState private var hovering = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let duration = max(player.duration ?? 0, 0.001)
            let shown = player.isDragging ? (player.scrubTime ?? player.position) : player.position
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.24)).frame(height: barHeight)
                Capsule().fill(.white.opacity(0.36))
                    .frame(width: width * fraction(player.position + (player.status?.buffer.ahead ?? 0), duration), height: barHeight)
                Capsule().fill(.white)
                    .frame(width: width * fraction(shown, duration), height: barHeight)
                ForEach(player.segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .overlay(Rectangle().strokeBorder(.black.opacity(0.55), lineWidth: 1))
                        .frame(width: max(3, width * (segment.end - segment.start) / duration), height: barHeight + 2)
                        .offset(x: width * fraction(segment.start, duration))
                        .accessibilityHidden(true)
                }
                ForEach(player.chapters.dropFirst(), id: \.startMs) { chapter in
                    Rectangle()
                        .fill(Color(white: 0.08, opacity: 0.95))
                        .frame(width: 3, height: barHeight + 2)
                        .offset(x: width * fraction(Double(chapter.startMs) / 1000, duration) - 1.5)
                        .accessibilityHidden(true)
                }
                if let time = player.scrubTime, !player.isDragging {
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: 2, height: barHeight + 10)
                        .offset(x: width * fraction(time, duration) - 1)
                }
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .overlay {
                        if player.focusedControl == .seekBar {
                            Circle().strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3).padding(-4)
                        }
                    }
                    .offset(x: width * fraction(shown, duration) - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    hovering = true
                    scrub(to: point.x, width: width, duration: duration, proxy: proxy)
                case .ended:
                    hovering = false
                    if !player.isDragging { player.scrubTime = nil }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        player.isDragging = true
                        scrub(to: value.location.x, width: width, duration: duration, proxy: proxy)
                    }
                    .onEnded { value in
                        let time = duration * min(1, max(0, value.location.x / max(width, 1)))
                        player.isDragging = false
                        player.seek(to: time)
                        if !hovering { player.scrubTime = nil }
                    }
            )
        }
        .frame(height: 22)
        .background {
            // Capturas automáticas: la burbuja del storyboard en `GTScrub`, como si el puntero estuviera encima.
            if let time = Automation.shared.scrubTime, let duration = player.duration, duration > 0 {
                GeometryReader { proxy in
                    Color.clear.task(id: duration) {
                        try? await Task.sleep(for: .seconds(2))
                        scrub(to: proxy.size.width * time / duration, width: proxy.size.width, duration: duration, proxy: proxy)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Posición")
        .accessibilityValue("\(Format.time(player.position)) de \(Format.time(player.duration))")
        .accessibilityAdjustableAction { direction in
            player.seek(by: direction == .increment ? 5 : -5)
        }
    }

    private var barHeight: CGFloat { hovering || player.isDragging ? 8 : 6 }
    private var knob: CGFloat { 16 }

    /// Sin duración todavía (al cargar), todo en 0 en lugar de la perilla al final.
    private func fraction(_ value: Double, _ duration: Double) -> Double {
        guard player.duration != nil else { return 0 }
        return min(1, max(0, value / duration))
    }

    private func scrub(to x: CGFloat, width: CGFloat, duration: Double, proxy: GeometryProxy) {
        let clamped = min(max(0, x), width)
        player.scrubTime = duration * Double(clamped / max(width, 1))
        let frame = proxy.frame(in: .named(PlayerSpace.name))
        let half = StoryboardBubble.width / 2
        player.scrubX = min(max(frame.minX + clamped, frame.minX + half - 40), frame.maxX - half + 40)
        player.scrubBarTop = frame.minY
        player.bumpControls()
    }
}

// MARK: - Menús (popovers del sistema)

extension View {
    /// Los menús del reproductor van en la apariencia oscura del reproductor (si no, el popover toma la del sistema y en
    /// modo claro queda un menú blanco sobre el video).
    func playerPopover() -> some View {
        preferredColorScheme(.dark)
            .foregroundStyle(.primary)
    }
}

/// Encabezado y filas de los menús emergentes, con el aspecto de la maqueta.
struct MenuHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
    }
}

struct MenuRow: View {
    let title: String
    var detail: String?
    var isSelected = false
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                if isSelected { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor : .primary.opacity(hovering ? 0.1 : 0)))
            .foregroundStyle(isSelected ? .white : .primary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct MenuInfoRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Calidad (el `HQDialogController` de SmartTube): pistas de video de la fuente y, debajo, las preferencias.
struct QualityMenu: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(title: "Calidad")
            let tracks = player.qualityOptions
            if tracks.isEmpty {
                Text(player.item.isLive ? "Automática (HLS)" : "Cargando…").foregroundStyle(.secondary).padding(12)
            }
            ForEach(tracks) { track in
                MenuRow(title: Format.quality(track),
                        detail: [track.codec?.uppercased(), track.isHDR ? "HDR" : nil].compactMap { $0 }.joined(separator: " · "),
                        isSelected: track.isSelected) {
                    player.select(track)
                    player.popover = nil
                }
            }
            Divider().padding(.horizontal, 10).padding(.vertical, 4)
            MenuInfoRow(title: "Códec preferido", value: player.settings.codec.title)
            MenuInfoRow(title: "Búfer", value: player.settings.buffer.title)
            if let decoder = player.status?.hardwareDecoder {
                MenuInfoRow(title: "Decodificación", value: decoder == "videotoolbox" ? "Hardware" : decoder)
            }
        }
        .padding(8)
        .frame(width: 270)
    }
}

struct SpeedMenu: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(title: "Velocidad")
            ForEach(PlayerModel.rates, id: \.self) { rate in
                MenuRow(title: rate == 1 ? "Normal" : Format.rate(rate), isSelected: abs((player.status?.rate ?? 1) - rate) < 0.01) {
                    player.setRate(rate)
                    player.popover = nil
                }
            }
            Text("Shift+. y Shift+, cambian la velocidad")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .padding(8)
        .frame(width: 230)
    }
}

struct CaptionsMenu: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(title: "Subtítulos")
            MenuRow(title: "Desactivados", isSelected: player.captionTrack == nil) {
                player.selectCaption(nil)
                player.popover = nil
            }
            let captions = sorted
            if captions.isEmpty {
                Text(player.extras == nil ? "Cargando…" : "Este video no tiene subtítulos")
                    .foregroundStyle(.secondary).padding(12)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(captions) { track in
                        MenuRow(title: track.name, detail: track.isAutomatic ? "automáticos" : nil,
                                isSelected: player.captionTrack == track) {
                            player.selectCaption(track)
                            player.popover = nil
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(8)
        .frame(width: 280)
    }

    /// El idioma preferido primero, luego los manuales y después los automáticos.
    private var sorted: [CaptionTrack] {
        let language = player.settings.subtitleLanguage
        return (player.extras?.captions ?? []).sorted { a, b in
            let aPreferred = a.languageCode.hasPrefix(language), bPreferred = b.languageCode.hasPrefix(language)
            if aPreferred != bPreferred { return aPreferred }
            if a.isAutomatic != b.isAutomatic { return !a.isAutomatic }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }
}

struct AudioMenu: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(title: "Pista de audio")
            let tracks = player.status?.audioTracks ?? []
            if tracks.isEmpty {
                Text("Cargando…").foregroundStyle(.secondary).padding(12)
            }
            ForEach(tracks) { track in
                MenuRow(title: track.title, isSelected: track.isSelected) {
                    player.select(track)
                    player.popover = nil
                }
            }
        }
        .padding(8)
        .frame(width: 280)
    }
}

struct MoreActionsMenu: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var app
    @Environment(LocalLibrary.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(title: "Más acciones")
            if player.item.channelId != nil || player.metadata?.channelId != nil {
                MenuRow(title: "Abrir canal", detail: player.engine is MPVEngine ? "el video sigue en el minirreproductor" : nil) {
                    player.openChannel()
                }
            }
            MenuRow(title: "Minirreproductor", detail: "I") {
                player.popover = nil
                app.enterMiniPlayer()
            }
            MenuRow(title: library.isInWatchLater(player.item) ? "Quitar de Ver más tarde" : "Ver más tarde") {
                library.toggleWatchLater(player.item)
                player.popover = nil
            }
            if let url = AppModel.webURL(for: player.item) {
                MenuRow(title: "Copiar enlace") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    player.popover = nil
                    player.showToast("Enlace copiado")
                }
                MenuRow(title: "Copiar enlace en este momento") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString + "&t=\(Int(player.position))s", forType: .string)
                    player.popover = nil
                    player.showToast("Enlace copiado")
                }
            }
            Divider().padding(.horizontal, 10).padding(.vertical, 4)
            if let status = player.status {
                MenuInfoRow(title: "Video", value: status.videoDescription ?? "—")
                MenuInfoRow(title: "Cuadros descartados", value: "\(status.droppedFrames)")
                MenuInfoRow(title: "Búfer por delante", value: status.buffer.ahead.map { String(format: "%.0f s", $0) } ?? "—")
            }
        }
        .padding(8)
        .frame(width: 300)
    }
}

// MARK: - Teclado

/// Atajos del reproductor. Cualquier tecla muestra los controles; si estaban ocultos, el foco entra en ellos.
struct PlayerKeyboard {
    let player: PlayerModel
    let app: AppModel

    func handle(_ press: KeyPress) -> KeyPress.Result {
        let result = perform(press)
        if Automation.shared.logsKeys {
            let state = String(format: "pos %.1f, vel %.2f, %@, foco %@, subtítulos %@, menú %@, me gusta %@, suscrito %@", player.position,
                               player.status?.rate ?? 0, player.isPlaying ? "reproduciendo" : "en pausa", String(describing: player.focusedControl),
                               player.captionTrack?.languageCode ?? "no", String(describing: player.popover),
                               player.likeStatus?.rawValue ?? "?", player.isSubscribed.map { $0 ? "sí" : "no" } ?? "?")
            let panel = "panel \(player.panelTab?.rawValue ?? "cerrado"), foco del panel \(String(describing: player.panelFocus)), cola \(app.queue.items.count), presentación \(app.playerPresentation)"
            NSLog("Glasstube automation: «\(press.characters)» → \(result == .handled ? "atendida" : "ignorada"); \(state); \(panel)")
        }
        return result
    }

    private func perform(_ press: KeyPress) -> KeyPress.Result {
        // Con el foco en el panel lateral, las flechas, Retorno y Esc son del panel.
        if let result = PanelKeyboard(player: player, app: app).handle(press) {
            player.bumpControls()
            return result
        }
        // «A continuación» a la vista: Retorno lo reproduce ya y Esc lo cancela.
        if player.upNext != nil, player.focusedControl == nil || press.key == .escape {
            if press.key == .return { player.playUpNext(); return .handled }
            if press.key == .escape { player.cancelUpNext(); return .handled }
        }
        let wasHidden = !player.controlsVisible
        player.bumpControls()
        if wasHidden && press.key != .leftArrow && press.key != .rightArrow { player.focusedControl = .playPause }
        let shift = press.modifiers.contains(.shift)
        let character = press.characters.lowercased()

        switch press.key {
        case .space:
            player.togglePause()
        case .return:
            if !wasHidden { activate(player.focusedControl ?? .playPause) }
        case .escape:
            if player.isFullScreen {
                player.toggleFullScreen()
            } else if player.panelTab != nil {
                player.closePanel()
            } else if !wasHidden && player.focusedControl != nil {
                player.hideControls()
            } else {
                app.closePlayer()
            }
        case .leftArrow, .rightArrow:
            let direction = press.key == .leftArrow ? -1 : 1
            if wasHidden || player.focusedControl == nil || player.focusedControl == .seekBar {
                player.seek(by: Double(direction) * 5)
                player.focusedControl = .seekBar
            } else {
                moveFocus(horizontal: direction)
            }
        case .upArrow, .downArrow:
            if !wasHidden { moveFocus(vertical: press.key == .upArrow ? -1 : 1) }
        case .tab:
            if !wasHidden { moveFocus(sequential: shift ? -1 : 1) }
        default:
            if shift && [">", ":", "."].contains(press.characters) {
                player.changeRate(by: 1)
            } else if shift && ["<", ";", ","].contains(press.characters) {
                player.changeRate(by: -1)
            } else {
                switch character {
                case "k": player.togglePause()
                case "j": player.seek(by: -10)
                case "l": player.seek(by: 10)
                case "f": player.toggleFullScreen()
                case "d": player.togglePanel(keyboard: true)
                case "i": app.enterMiniPlayer()
                case "c": player.toggleCaptions()
                case "m": player.toggleMute()
                case "n" where shift: player.playNext()
                case "p" where shift: player.playPrevious()
                case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                    if let digit = Double(character), let duration = player.duration { player.seek(to: duration * digit / 10) }
                default:
                    // Cualquier otra tecla solo muestra los controles (ya hecho arriba).
                    return wasHidden ? .handled : .ignored
                }
            }
        }
        return .handled
    }

    func activate(_ control: PlayerControl) {
        switch control {
        case .back: app.closePlayer()
        case .like: player.toggleLike()
        case .dislike: player.toggleDislike()
        case .subscribe: player.toggleSubscribe()
        case .comments: player.togglePanel(player.chat != nil ? .chat : .comments, keyboard: true)
        case .info: player.togglePanel(.description, keyboard: true)
        case .more: player.popover = .more
        case .skip: player.skipActiveSegment()
        case .seekBar, .playPause: player.togglePause()
        case .previous: player.playPrevious()
        case .next: player.playNext()
        case .mute: player.toggleMute()
        case .speed: player.popover = .speed
        case .captions: player.popover = .captions
        case .quality: player.popover = .quality
        case .audio: player.popover = .audio
        case .pip: app.enterMiniPlayer()
        case .fullscreen: player.toggleFullScreen()
        }
    }

    /// Filas que se ven ahora.
    private var rows: [[PlayerControl]] {
        let signedIn = app.accounts.isSignedIn
        let hasChannel = player.item.channelId != nil || player.metadata?.channelId != nil
        return PlayerControl.rows.filter { row in
            row != [.skip] || player.activeSegment != nil
        }.map { row in
            // "Suscribirse" y "No me gusta" solo se ven con sesión.
            row.filter { ($0 != .dislike || signedIn || player.votes != nil) && ($0 != .subscribe || (signedIn && hasChannel)) }
        }
    }

    private func position(of control: PlayerControl?) -> (row: Int, column: Int)? {
        guard let control else { return nil }
        for (r, row) in rows.enumerated() {
            if let c = row.firstIndex(of: control) { return (r, c) }
        }
        return nil
    }

    private func moveFocus(horizontal direction: Int) {
        guard let (r, c) = position(of: player.focusedControl) else { player.focusedControl = .playPause; return }
        let row = rows[r]
        // → desde el último control de arriba entra al panel lateral abierto.
        if direction > 0, c == row.count - 1, r == 0, player.panelTab != nil {
            player.focusedControl = nil
            player.panelFocus = .tabs
            return
        }
        player.focusedControl = row[min(row.count - 1, max(0, c + direction))]
    }

    private func moveFocus(vertical direction: Int) {
        guard let (r, c) = position(of: player.focusedControl) else { player.focusedControl = .playPause; return }
        let target = min(rows.count - 1, max(0, r + direction))
        guard target != r else { return }
        let from = rows[r], to = rows[target]
        let ratio = from.count > 1 ? Double(c) / Double(from.count - 1) : 0.5
        player.focusedControl = to[min(to.count - 1, Int((ratio * Double(to.count - 1)).rounded()))]
    }

    private func moveFocus(sequential direction: Int) {
        let flat = rows.flatMap { $0 }
        guard let current = player.focusedControl, let index = flat.firstIndex(of: current) else {
            player.focusedControl = flat.first
            return
        }
        player.focusedControl = flat[(index + direction + flat.count) % flat.count]
    }
}
