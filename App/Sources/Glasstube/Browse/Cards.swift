import AppKit
import Observation
import SwiftUI
import YTKit

/// Radio de las miniaturas. El resto de formas dentro de la miniatura (duración, avisos) son concéntricas a ella.
let thumbnailRadius: CGFloat = 16

/// Tarjeta de cualquier elemento: video (y mix), Short, canal o lista.
struct ItemCard: View {
    let item: MediaItem
    var progress: Double?
    var isFocused = false

    var body: some View {
        switch item.kind {
        case .channel:
            ChannelCard(item: item, isFocused: isFocused)
        case .video where item.isShort:
            ShortCard(item: item, isFocused: isFocused)
        default:
            VideoCard(item: item, progress: progress, isFocused: isFocused)
        }
    }
}

/// Tarjeta de video: miniatura opaca 16:9 con esquinas concéntricas, duración y progreso visto. Al pasar el puntero
/// (o con el foco del teclado) se eleva y reproduce la vista previa del storyboard; clic derecho = menú del video
/// (el `VideoMenuPresenter` de SmartTube).
struct VideoCard: View {
    let item: MediaItem
    var progress: Double?
    var isFocused = false

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(LocalLibrary.self) private var library
    @Environment(\.playContext) private var playContext
    @ViewState private var hovering = false
    @ViewState private var preview = StoryboardPreview()

    /// El título de DeArrow si está activado (el original queda en la ayuda).
    private var title: String { model.deArrow.title(for: item) }

    private var lifted: Bool { hovering || isFocused || (item.videoId != nil && Automation.shared.forcedHoverId == item.videoId) }
    /// Progreso local o, si no hay, el de la cuenta de YouTube (barra roja de la miniatura).
    private var watched: Double? { progress ?? library.progress(for: item.videoId) ?? item.percentWatched.map { Double($0) / 100 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.open(item, context: playContext) } label: {
                thumbnail
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reproducir: \(title)")
            .overlay(alignment: .topTrailing) {
                if lifted {
                    CardMoreButton(item: item)
                        .padding(8)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .help(model.deArrow.replacesTitle(of: item) ? "DeArrow · título original: \(item.title)" : item.title)
                Text(item.cardSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
        .contentShape(.rect)
        .onHover { inside in
            withAnimation(.smooth(duration: 0.2)) { hovering = inside }
        }
        .task(id: lifted) {
            if lifted && settings.hoverPreviews {
                preview.start(item: item, extras: model.extras)
            } else {
                preview.stop()
            }
        }
        .onDisappear { preview.stop() }
        .onAppear { model.deArrow.request(item.videoId) }
        .contextMenu { ItemMenu(item: item) }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(urls: MediaItemImages.card(item))
                // La miniatura de DeArrow tapa la de YouTube solo cuando ya cargó (el servidor la genera y puede tardar).
                .overlay { LateImage(url: model.deArrow.thumbnailURL(for: item)) }
                .overlay {
                    // En una superposición: un cuadro de otra proporción (2:1, vertical) no cambia el tamaño de la tarjeta.
                    if let frame = preview.frame {
                        Image(nsImage: frame)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    }
                }
                .clipped()

            HStack(alignment: .bottom) {
                if let time = preview.frameTime {
                    Text("Vista previa · \(Format.time(time))")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: .capsule)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                if let badge = item.durationBadge {
                    Text(badge)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(item.isLive ? Color.red : Color.black.opacity(0.74),
                                    in: ConcentricRectangle(corners: .concentric(minimum: .fixed(6)), isUniform: true))
                }
            }
            .padding(8)
            .padding(.bottom, watched != nil ? 4 : 0)

            if let fraction = preview.fraction {
                ProgressStrip(fraction: fraction, color: .white, track: .clear, height: 3)
            } else if let watched {
                ProgressStrip(fraction: watched, color: .accentColor, track: .white.opacity(0.4), height: 4)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .containerShape(.rect(cornerRadius: thumbnailRadius))
        .clipShape(.rect(cornerRadius: thumbnailRadius))
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: thumbnailRadius + 3)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                    .padding(-4)
            }
        }
        .offset(y: lifted ? -4 : 0)
        .shadow(color: .black.opacity(lifted ? 0.24 : 0.10), radius: lifted ? 17 : 1, y: lifted ? 16 : 1)
    }
}

/// Barra fina al pie de la miniatura (progreso visto o posición de la vista previa).
struct ProgressStrip: View {
    let fraction: Double
    var color: Color
    var track: Color
    var height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                Rectangle().fill(color).frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Botón "Más opciones" sobre la miniatura: un control, así que va en vidrio.
struct CardMoreButton: View {
    let item: MediaItem

    var body: some View {
        Menu {
            ItemMenu(item: item)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 30, height: 30)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Más opciones: \(item.title)")
        .help("Más opciones")
    }
}

/// Menú de un elemento (clic derecho y botón "…"): agregar a playlist, no me interesa, bloquear canal, abrir canal y
/// compartir. Con cuenta, las playlists son las de YouTube (Ver más tarde incluida) y "No me interesa" se le avisa a
/// YouTube; sin cuenta, "Ver más tarde" y los filtros son de esta Mac.
struct ItemMenu: View {
    let item: MediaItem
    @Environment(AppModel.self) private var model
    @Environment(LocalLibrary.self) private var library
    @Environment(AccountModel.self) private var accounts
    @Environment(\.playlistContext) private var playlistContext
    @Environment(\.feedbackLabel) private var feedbackLabel
    @Environment(ChannelGroupStore.self) private var groups

    var body: some View {
        if item.isPlayable {
            Button("Reproducir", systemImage: "play.fill") { model.play(item) }
            if item.videoId != nil {
                Button("Reproducir a continuación", systemImage: "text.line.first.and.arrowtriangle.forward") { model.enqueue(item, next: true) }
                Button("Agregar a la cola", systemImage: "text.badge.plus") { model.enqueue(item, next: false) }
            }
        }
        if item.kind == .video {
            Menu("Agregar a playlist", systemImage: "text.badge.plus") {
                if accounts.isSignedIn, let videoId = item.videoId {
                    Button("Ver más tarde", systemImage: "clock") {
                        model.accountAction("Se agregó a Ver más tarde") {
                            try await $0.addToPlaylist(playlistId: YouTubeService.watchLaterPlaylistId, videoId: videoId)
                        }
                    }
                    Button("Guardar en una playlist…", systemImage: "list.bullet") { model.playlistPicker = item }
                    Divider()
                }
                Button(library.isInWatchLater(item) ? "Quitar de Ver más tarde (en esta Mac)" : "Ver más tarde (en esta Mac)",
                       systemImage: library.isInWatchLater(item) ? "checkmark" : "clock") {
                    library.toggleWatchLater(item)
                }
            }
            if let playlistContext, let videoId = item.videoId {
                Button("Quitar de «\(playlistContext.title ?? "esta playlist")»", systemImage: "minus.circle") {
                    model.accountAction("Se quitó de la playlist") {
                        try await $0.removeFromPlaylist(playlistId: playlistContext.id, videoId: videoId)
                        playlistContext.removed(videoId)
                    }
                }
            }
            Button(accounts.isSignedIn ? (feedbackLabel ?? "No me interesa") : "No me interesa",
                   systemImage: feedbackLabel == "Quitar del historial" ? "trash" : "hand.thumbsdown") {
                library.hide(item)
                // Con cuenta también se le avisa a YouTube (deja de recomendarlo, lo oculta o lo quita del historial).
                if accounts.isSignedIn, item.feedbackToken != nil || item.menuPanel != nil {
                    let item = item
                    model.accountAction(nil) { try await $0.markAsNotInterested(item) }
                }
            }
        }
        if let channelId = item.channelId {
            Divider()
            Button("Abrir canal", systemImage: "person.crop.square") {
                model.navigator.go(.channel(id: channelId, title: item.author ?? (item.kind == .channel ? item.title : nil)))
            }
            if let channel = GroupChannel(item: item) {
                // Fase 5a: grupos de canales y, sin cuenta, suscripciones de esta Mac.
                Menu("Agregar a un grupo", systemImage: "folder.badge.plus") {
                    GroupMembershipItems(channel: channel)
                }
                if !accounts.isSignedIn {
                    Button(groups.isSubscribed(channel.id) ? "Dejar de seguir en esta Mac" : "Suscribirse en esta Mac",
                           systemImage: groups.isSubscribed(channel.id) ? "minus.circle" : "plus.circle") {
                        model.toggleLocalSubscription(channel)
                    }
                }
            }
            Button("Bloquear canal", systemImage: "nosign") {
                model.blockChannel(id: channelId, name: item.kind == .channel ? item.title : (item.author ?? item.title))
            }
        }
        if let url = AppModel.webURL(for: item) {
            Divider()
            ShareLink(item: url, subject: Text(model.deArrow.title(for: item))) {
                Label("Compartir…", systemImage: "square.and.arrow.up")
            }
            Button("Copiar enlace", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }
}

/// Short: miniatura vertical 9:16.
struct ShortCard: View {
    let item: MediaItem
    var isFocused = false
    @Environment(AppModel.self) private var model
    @ViewState private var hovering = false

    var body: some View {
        Button { model.open(item) } label: {
            ZStack(alignment: .bottomLeading) {
                // 600: la miniatura de 640 de un Short (4:3, con franjas) se recorta al centro y no queda borrosa.
                RemoteImage(urls: MediaItemImages.card(item, width: 600))
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.deArrow.title(for: item))
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(2)
                    if let views = item.viewCountText ?? item.metadataLines.first {
                        Text(views).font(.system(size: 12)).opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .padding(10)
            }
            .aspectRatio(9 / 16, contentMode: .fit)
            .clipShape(.rect(cornerRadius: thumbnailRadius))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: thumbnailRadius + 3)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                        .padding(-4)
                }
            }
            .offset(y: hovering || isFocused ? -4 : 0)
            .shadow(color: .black.opacity(hovering || isFocused ? 0.24 : 0.1), radius: hovering || isFocused ? 17 : 1, y: hovering || isFocused ? 16 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reproducir Short: \(item.title)")
        .onHover { inside in withAnimation(.smooth(duration: 0.2)) { hovering = inside } }
        .contextMenu { ItemMenu(item: item) }
    }
}

/// Canal: avatar redondo y nombre.
struct ChannelCard: View {
    let item: MediaItem
    var isFocused = false
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.open(item) } label: {
            VStack(spacing: 10) {
                RemoteImage(urls: MediaItemImages.avatar(item.authorThumbnails.isEmpty ? item.thumbnails : item.authorThumbnails))
                    .frame(width: 120, height: 120)
                    .clipShape(.circle)
                    .overlay {
                        if isFocused {
                            Circle().strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3).padding(-4)
                        }
                    }
                VStack(spacing: 2) {
                    Text(item.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                    Text(item.cardSubtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Abrir canal: \(item.title)")
        .contextMenu { ItemMenu(item: item) }
    }
}

/// Vista previa al pasar el puntero: recorre cuadros del storyboard del video (las mismas hojas que SmartTube usa
/// al adelantar), del 10 al 90 % de la duración.
@Observable
final class StoryboardPreview {
    private(set) var frame: NSImage?
    private(set) var frameTime: Double?
    private(set) var fraction: Double?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(item: MediaItem, extras: PlayerExtrasService) {
        guard task == nil, let videoId = item.videoId, !item.isLive, item.kind == .video else { return }
        task = Task { [weak self] in
            // Un momento antes de pedir nada: pasar el puntero por encima de la cuadrícula no debe disparar pedidos.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled,
                  let info = try? await extras.extras(videoId: videoId),
                  let storyboard = info.storyboard,
                  let duration = info.duration ?? item.durationSeconds.map(Double.init), duration > 0 else { return }
            let steps = 14
            var step = 0
            while !Task.isCancelled {
                let time = duration * (0.1 + 0.8 * Double(step) / Double(steps - 1))
                if let (url, rect) = storyboard.frame(at: time, duration: duration),
                   let sheet = await ImagePipeline.shared.image(for: url),
                   let image = StoryboardSpec.crop(sheet, rect: rect) {
                    guard !Task.isCancelled, let self else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        self.frame = image
                        self.frameTime = time
                        self.fraction = time / duration
                    }
                }
                step = (step + 1) % steps
                try? await Task.sleep(for: .milliseconds(650))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        withAnimation(.easeOut(duration: 0.15)) {
            frame = nil
            frameTime = nil
            fraction = nil
        }
    }
}

/// Los grupos con una marca en los que ya tiene el canal (elegir uno lo agrega o lo quita) y «Nuevo grupo…» (fase 5a).
/// Va dentro de un `Menu`: el de las tarjetas y el de la cabecera del canal.
struct GroupMembershipItems: View {
    let channel: GroupChannel
    @Environment(AppModel.self) private var model
    @Environment(ChannelGroupStore.self) private var groups

    var body: some View {
        ForEach(groups.groups) { group in
            Toggle(group.title, isOn: Binding(get: { group.contains(channel.id) },
                                              set: { _ in model.toggle(channel, inGroup: group.id) }))
        }
        if !groups.groups.isEmpty { Divider() }
        Button("Nuevo grupo con este canal…", systemImage: "folder.badge.plus") { model.groupPrompt = .create(channel) }
    }
}
