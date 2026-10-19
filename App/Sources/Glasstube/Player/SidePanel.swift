import AppKit
import PlaybackKit
import SwiftUI
import YTKit

/// Panel lateral del reproductor (hallazgos/05: «entra desde la derecha como hoja de vidrio»): descripción, capítulos,
/// comentarios, chat en vivo y sugeridos con la cola. Es una pieza más del `GlassEffectContainer` del reproductor; el
/// contenido va sin vidrio (nunca vidrio sobre vidrio): filas con resalte al pasar el puntero y anillo con el teclado.
/// Mientras está abierto, el video se encoge a la izquierda para no quedar tapado.
struct SidePanel: View {
    static let width: CGFloat = 392
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            PanelTabBar()
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)
            Rectangle().fill(.white.opacity(0.14)).frame(height: 1).padding(.horizontal, 14)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        switch player.panelTab ?? .description {
                        case .description: DescriptionTab()
                        case .chapters: ChaptersTab()
                        case .comments: CommentsTab()
                        case .chat: ChatTab()
                        case .suggestions: SuggestionsTab()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.automatic)
                .onChange(of: player.panelFocus) { _, focus in
                    if case .row(let id)? = focus { withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                }
                // El chat baja solo con cada mensaje nuevo.
                .onChange(of: player.chat?.messages.last?.id) {
                    if player.panelTab == .chat { proxy.scrollTo("chat:end", anchor: .bottom) }
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panel: \((player.panelTab ?? .description).title)")
    }
}

/// Pestañas del panel (botones de texto, sin vidrio propio) y cerrar.
struct PanelTabBar: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        // Con cuatro o más pestañas (capítulos, chat) se aprietan un poco para caber en el ancho del panel.
        let compact = player.availableTabs.count > 3
        HStack(spacing: compact ? 0 : 2) {
            ForEach(player.availableTabs) { tab in
                let selected = player.panelTab == tab
                Button {
                    player.panelTab = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: compact ? 12 : 12.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, compact ? 7 : 10)
                        .frame(height: 30)
                        .background(Capsule().fill(.white.opacity(selected ? 0.2 : 0)))
                        .overlay {
                            if selected, player.panelFocus == .tabs { Capsule().strokeBorder(.white, lineWidth: 2) }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(tab == .comments ? "Comentarios (D abre y cierra el panel)" : tab.title)
            }
            Spacer(minLength: 4)
            Button { player.closePanel() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar el panel")
            .help("Cerrar el panel (Esc)")
        }
    }
}

/// Fila del panel: resalte al pasar el puntero, anillo con el foco del teclado y clic = Retorno.
struct PanelRow<Content: View>: View {
    let id: String
    var action: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(PlayerModel.self) private var player
    @ViewState private var hovering = false

    var body: some View {
        let focused = player.panelFocus == .row(id)
        content()
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(focused ? 0.14 : (hovering && action != nil ? 0.08 : 0))))
            .overlay {
                if focused { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.9), lineWidth: 2) }
            }
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .onTapGesture { action?() }
            .id(id)
    }
}

// MARK: - Descripción

struct DescriptionTab: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var app
    @Environment(AccountModel.self) private var accounts

    var body: some View {
        let meta = player.metadata
        PanelRow(id: "desc:header") {
            VStack(alignment: .leading, spacing: 6) {
                Text(player.title).font(.system(size: 16, weight: .bold)).textSelection(.enabled)
                if player.title != player.originalTitle {
                    Label("Título de DeArrow · original: \(player.originalTitle)", systemImage: "textformat.abc")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7))
                }
                let stats = [meta?.viewCountText, meta?.publishedDate].compactMap { $0 }.joined(separator: " · ")
                if !stats.isEmpty { Text(stats).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.8)) }
            }
        }
        if meta?.likeCountText != nil || player.votes != nil {
            PanelRow(id: "desc:votes") { VotesSummary() }
        }
        if let author = player.author {
            PanelRow(id: "desc:channel", action: { player.openChannel() }) {
                HStack(spacing: 10) {
                    RemoteImage(urls: MediaItemImages.avatar(meta?.authorThumbnails ?? player.item.authorThumbnails))
                        .frame(width: 36, height: 36).clipShape(.circle)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(author).font(.system(size: 13.5, weight: .semibold))
                        if let subscribers = meta?.subscriberCountText {
                            Text(subscribers).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    Spacer(minLength: 0)
                    if accounts.isSignedIn {
                        Text(player.isSubscribed == true ? "Suscrito" : "Suscribirse")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(.white.opacity(player.isSubscribed == true ? 0.14 : 0.24)))
                            .onTapGesture { player.toggleSubscribe() }
                    }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        if meta == nil {
            ProgressView().frame(maxWidth: .infinity).padding()
        }
        ForEach(Array(player.descriptionParagraphs.enumerated()), id: \.offset) { index, paragraph in
            PanelRow(id: "desc:p\(index)") {
                Text(paragraph).font(.system(size: 13)).foregroundStyle(.white.opacity(0.92)).textSelection(.enabled)
            }
        }
    }
}

/// Me gusta de YouTube y no me gusta de Return YouTube Dislike, con la proporción.
struct VotesSummary: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Label(player.likeCountText ?? "—", systemImage: player.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                if let votes = player.votes {
                    Label(DislikeClient.compact(votes.dislikes), systemImage: player.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            if let ratio = player.votes?.likeRatio {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white).frame(width: proxy.size.width * ratio)
                    }
                }
                .frame(height: 3)
                Text("No me gusta: estimación de Return YouTube Dislike")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Capítulos

struct ChaptersTab: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let current = player.chapter(at: player.position)
        ForEach(Array(player.chapters.enumerated()), id: \.element.startMs) { index, chapter in
            PanelRow(id: "ch:\(chapter.startMs)", action: { player.seek(to: Double(chapter.startMs) / 1000) }) {
                HStack(spacing: 10) {
                    RemoteImage(urls: MediaItemImages.urls(chapter.thumbnails, width: 160))
                        .frame(width: 96, height: 54)
                        .clipShape(.rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(index + 1). \(chapter.title)").font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(Format.time(Double(chapter.startMs) / 1000)).font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                    if current == chapter {
                        Image(systemName: "waveform").foregroundStyle(Color.accentColor).accessibilityLabel("Capítulo actual")
                    }
                }
            }
        }
    }
}

// MARK: - Comentarios

struct CommentsTab: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if let comments = player.comments {
            if !comments.isAvailable {
                PanelMessage(symbol: "text.bubble", text: "Los comentarios están desactivados en este video.")
            } else {
                CommentsHeader(model: comments)
                ForEach(comments.rows) { row in
                    switch row {
                    case .comment(let comment):
                        CommentRow(model: comments, comment: comment, rowID: row.id, isReply: false)
                    case .reply(let comment, _):
                        CommentRow(model: comments, comment: comment, rowID: row.id, isReply: true)
                    case .moreReplies(let parent):
                        PanelRow(id: row.id, action: { comments.loadMoreReplies(parent: parent) }) {
                            Label("Más respuestas", systemImage: "arrow.turn.down.right")
                                .font(.system(size: 12.5, weight: .semibold)).padding(.leading, 38)
                        }
                    case .loadMore:
                        PanelRow(id: row.id, action: { comments.loadMore() }) {
                            HStack {
                                Spacer()
                                if comments.isLoading { ProgressView().controlSize(.small) } else { Text("Más comentarios").font(.system(size: 12.5, weight: .semibold)) }
                                Spacer()
                            }
                        }
                        .onAppear { comments.loadMore() }
                    }
                }
                if comments.comments.isEmpty, comments.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
                if let failure = comments.failure {
                    PanelMessage(symbol: "exclamationmark.triangle", text: failure)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding()
        }
    }
}

struct CommentsHeader: View {
    let model: CommentsModel
    @Environment(PlayerModel.self) private var player

    var body: some View {
        PanelRow(id: "com:sort", action: { model.select(sort: (model.selectedSort + 1) % max(1, model.sorts.count)) }) {
            HStack {
                Text(player.metadata?.commentsCountText.map { "\($0) comentarios" } ?? "Comentarios")
                    .font(.system(size: 13.5, weight: .bold))
                Spacer()
                if model.sorts.count > 1 {
                    Label(model.sorts[model.selectedSort].title, systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .help("Cambiar el orden (Retorno)")
                }
            }
        }
    }
}

struct CommentRow: View {
    let model: CommentsModel
    let comment: Comment
    let rowID: String
    let isReply: Bool
    @Environment(PlayerModel.self) private var player
    @Environment(AccountModel.self) private var accounts
    @FocusState private var replyFocused: Bool

    var body: some View {
        PanelRow(id: rowID, action: isReply ? nil : { model.toggleReplies(comment) }) {
            HStack(alignment: .top, spacing: 10) {
                PersonAvatar(name: comment.author, thumbnails: comment.authorThumbnails, size: isReply ? 22 : 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(Automation.shared.personName(comment.author))
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, comment.authorIsChannelOwner ? 6 : 0)
                            .background(Capsule().fill(.white.opacity(comment.authorIsChannelOwner ? 0.2 : 0)))
                        if let published = comment.publishedText {
                            Text(published).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.65))
                        }
                        if comment.isPinned { Image(systemName: "pin.fill").font(.system(size: 10)).accessibilityLabel("Fijado") }
                    }
                    Text(comment.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack(spacing: 14) {
                        likeButton
                        if comment.isHearted { Image(systemName: "heart.fill").foregroundStyle(.red).font(.system(size: 11)).accessibilityLabel("Al creador le encantó") }
                        if accounts.isSignedIn, comment.replyParams != nil {
                            Button("Responder") { model.beginReply(to: comment); replyFocused = true }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                        }
                        if !isReply, comment.hasReplies {
                            Label(comment.replyCountText ?? "Respuestas", systemImage: model.threads[comment.id] == nil ? "chevron.down" : "chevron.up")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        if model.threads[comment.id]?.isLoading == true { ProgressView().controlSize(.mini) }
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    if model.replyingTo == comment.id { replyField }
                }
            }
            .padding(.leading, isReply ? 38 : 0)
        }
    }

    @ViewBuilder
    private var likeButton: some View {
        let label = Label(comment.likeCountText ?? "", systemImage: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
            .font(.system(size: 12, weight: .semibold))
        if accounts.isSignedIn, comment.likeAction != nil {
            Button { model.toggleLike(comment) { player.showToast($0) } } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel(comment.isLiked ? "Quitar me gusta" : "Me gusta")
        } else {
            label.accessibilityLabel("\(comment.likeCountText ?? "0") me gusta")
        }
    }

    private var replyField: some View {
        @Bindable var model = model
        return VStack(alignment: .trailing, spacing: 6) {
            TextField("Agrega una respuesta…", text: $model.replyText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($replyFocused)
                .onSubmit { model.sendReply(to: comment) { player.showToast($0) } }
            HStack {
                Button("Cancelar") { model.replyingTo = nil }
                Button("Responder") { model.sendReply(to: comment) { player.showToast($0) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sendingReply)
            }
            .controlSize(.small)
        }
        .padding(.top, 4)
    }
}

/// Avatar de una persona (quien comenta o escribe en el chat). En las capturas con `-GTSinPersonas`, un círculo con la
/// inicial en lugar de su foto.
struct PersonAvatar: View {
    let name: String
    let thumbnails: [YTThumbnail]
    var size: CGFloat = 28

    var body: some View {
        Group {
            if Automation.shared.masksPeople {
                Circle().fill(Color(hue: Double(abs(name.hashValue % 360)) / 360, saturation: 0.45, brightness: 0.75))
                    .overlay { Text(String(Automation.shared.personName(name).dropFirst().prefix(1)).uppercased()).font(.system(size: size * 0.45, weight: .bold)) }
            } else {
                RemoteImage(urls: MediaItemImages.urls(thumbnails, width: Int(size * 2)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

struct PanelMessage: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.8))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Chat en vivo

struct ChatTab: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if let chat = player.chat {
            HStack(spacing: 6) {
                Circle().fill(chat.state == .live ? Color.red : .gray).frame(width: 7, height: 7)
                Text(chatStatus(chat)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            ForEach(chat.messages) { message in
                ChatMessageRow(message: message)
                    .id("chat:\(message.id)")
            }
            Color.clear.frame(height: 1).id("chat:end")
        } else {
            PanelMessage(symbol: "bubble.left.and.bubble.right", text: "Este video no tiene chat en vivo.")
        }
    }

    private func chatStatus(_ chat: LiveChatModel) -> String {
        switch chat.state {
        case .idle: "Chat en vivo"
        case .connecting: "Conectando con el chat…"
        case .live: "Chat en vivo · \(chat.messages.count) mensajes"
        case .ended: "El chat terminó"
        case .failed(let error): "No se pudo leer el chat: \(error)"
        }
    }
}

struct ChatMessageRow: View {
    let message: LiveChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PersonAvatar(name: message.author, thumbnails: message.authorPhotos, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Automation.shared.personName(message.author))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(authorColor)
                    if let amount = message.amountText {
                        Text(amount).font(.system(size: 11.5, weight: .bold))
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, message.kind == .text ? 3 : 8)
        .background {
            if message.kind != .text {
                RoundedRectangle(cornerRadius: 12).fill(highlight)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var authorColor: Color {
        if message.isOwner { return .yellow }
        if message.isModerator { return Color(red: 0.55, green: 0.7, blue: 1) }
        if message.isMember { return .green }
        return .white.opacity(0.75)
    }

    /// Super Chat con su color (ARGB de YouTube); membresías y avisos en un gris claro.
    private var highlight: Color {
        guard let argb = message.colorARGB else { return .white.opacity(0.12) }
        let red = Double((argb >> 16) & 0xff) / 255, green = Double((argb >> 8) & 0xff) / 255, blue = Double(argb & 0xff) / 255
        return Color(red: red, green: green, blue: blue).opacity(0.55)
    }
}

// MARK: - Sugeridos y cola

struct SuggestionsTab: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        PanelRow(id: "sug:autoplay", action: { settings.autoplayNext.toggle() }) {
            Toggle(isOn: $settings.autoplayNext) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reproducción automática").font(.system(size: 13, weight: .semibold))
                    Text("Al terminar sigue con el primero de los sugeridos").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        if !app.queue.isEmpty {
            HStack {
                Text(app.queue.sourceTitle.map { "En cola · \($0)" } ?? "En cola (\(app.queue.items.count))")
                    .font(.system(size: 13.5, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Button("Vaciar") { app.queue.clear() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            ForEach(app.queue.items) { item in
                SuggestionRow(item: item, rowID: "q:\(item.id)", isQueued: true)
            }
        }
        Text("Sugeridos").font(.system(size: 13.5, weight: .bold)).padding(.horizontal, 8).padding(.top, 8)
        if player.metadata == nil {
            ProgressView().frame(maxWidth: .infinity).padding()
        }
        ForEach(player.suggestedVideos) { item in
            SuggestionRow(item: item, rowID: "s:\(item.id)", isQueued: false)
        }
    }
}

struct SuggestionRow: View {
    let item: MediaItem
    let rowID: String
    let isQueued: Bool
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var app

    var body: some View {
        PanelRow(id: rowID, action: { app.play(item) }) {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    RemoteImage(urls: MediaItemImages.card(item, width: 320))
                        .overlay { LateImage(url: app.deArrow.thumbnailURL(for: item)) }
                        .clipped()
                    if let badge = item.durationBadge {
                        Text(badge).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(item.isLive ? Color.red : Color.black.opacity(0.75), in: .rect(cornerRadius: 5))
                            .padding(4)
                    }
                }
                .frame(width: 128, height: 72)
                .clipShape(.rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.deArrow.title(for: item)).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                    Text([item.author, item.viewCountText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if isQueued {
                    Button { app.queue.remove(item) } label: {
                        Image(systemName: "minus.circle").font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Quitar de la cola")
                    .help("Quitar de la cola (Supr)")
                }
            }
        }
        .contextMenu {
            Button("Reproducir", systemImage: "play.fill") { app.play(item) }
            Button("Reproducir a continuación", systemImage: "text.line.first.and.arrowtriangle.forward") { app.enqueue(item, next: true) }
            Button("Agregar a la cola", systemImage: "text.badge.plus") { app.enqueue(item, next: false) }
            if isQueued { Button("Quitar de la cola", systemImage: "minus.circle") { app.queue.remove(item) } }
        }
        .onAppear { app.deArrow.request(item.videoId) }
    }
}

// MARK: - Filas y teclado

extension PlayerModel {
    /// Párrafos de la descripción (cada uno es una fila para el teclado).
    var descriptionParagraphs: [String] {
        (metadata?.description ?? "").components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var likeCountText: String? { metadata?.likeCountText }

    /// Las filas de la pestaña abierta, en orden (las mismas que dibuja el panel).
    var panelRowIDs: [String] {
        switch panelTab ?? .description {
        case .description:
            var ids = ["desc:header"]
            if metadata?.likeCountText != nil || votes != nil { ids.append("desc:votes") }
            if author != nil { ids.append("desc:channel") }
            ids += descriptionParagraphs.indices.map { "desc:p\($0)" }
            return ids
        case .chapters:
            return chapters.map { "ch:\($0.startMs)" }
        case .comments:
            guard let comments, comments.isAvailable else { return [] }
            return ["com:sort"] + comments.rows.map(\.id)
        case .chat:
            return []
        case .suggestions:
            return ["sug:autoplay"] + queue.items.map { "q:\($0.id)" } + suggestedVideos.map { "s:\($0.id)" }
        }
    }

    /// Abre el canal del video y deja el video en el minirreproductor (como YouTube al navegar con un video abierto).
    func openChannel() {
        var channelItem = item
        channelItem.channelId = item.channelId ?? metadata?.channelId
        channelItem.author = item.author ?? metadata?.author
        guard let channelId = channelItem.channelId else { return }
        popover = nil
        if engine is MPVEngine {
            app.enterMiniPlayer()
            app.navigator.go(.channel(id: channelId, title: channelItem.author))
        } else {
            app.openChannel(of: channelItem)
        }
    }

    /// Retorno sobre una fila del panel.
    func activatePanelRow(_ id: String) {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let (kind, value) = (parts[0], parts[1])
        switch kind {
        case "desc" where value == "channel":
            openChannel()
        case "ch":
            if let ms = Int(value) { seek(to: Double(ms) / 1000) }
        case "com":
            if let comments { comments.select(sort: (comments.selectedSort + 1) % max(1, comments.sorts.count)) }
        case "c":
            if let comment = comments?.comments.first(where: { $0.id == value }) { comments?.toggleReplies(comment) }
        case "m":
            comments?.loadMoreReplies(parent: value)
        case "more":
            comments?.loadMore()
        case "sug":
            settings.autoplayNext.toggle()
        case "q", "s":
            let pool = kind == "q" ? queue.items : suggestedVideos
            if let target = pool.first(where: { $0.id == value }) { app.play(target) }
        default:
            break
        }
    }

    /// El elemento (sugerido o en cola) de una fila, para las teclas de cola.
    func panelItem(_ id: String) -> MediaItem? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let pool = parts[0] == "q" ? queue.items : parts[0] == "s" ? suggestedVideos : []
        return pool.first { $0.id == parts[1] }
    }

    /// El comentario de una fila (para me gusta y responder con el teclado).
    func panelComment(_ id: String) -> Comment? {
        guard let comments else { return nil }
        for row in comments.rows where row.id == id {
            switch row {
            case .comment(let comment), .reply(let comment, _): return comment
            default: return nil
            }
        }
        return nil
    }
}

/// Teclado dentro del panel: ←/→ cambian de pestaña en la fila de pestañas, ↑/↓ recorren las filas, Retorno activa,
/// Esc cierra el panel. Teclas de las filas: G (me gusta), R (responder), Q (agregar a la cola), N (a continuación),
/// Supr (quitar de la cola). Lo demás (espacio, J/K/L del video…) sigue yendo al reproductor.
struct PanelKeyboard {
    let player: PlayerModel
    let app: AppModel

    func handle(_ press: KeyPress) -> KeyPress.Result? {
        guard player.panelTab != nil, let focus = player.panelFocus else { return nil }
        let rows = player.panelRowIDs
        switch press.key {
        case .escape:
            player.closePanel()
            return .handled
        case .leftArrow, .rightArrow:
            guard focus == .tabs else { return .handled }
            let tabs = player.availableTabs
            if let current = player.panelTab, let index = tabs.firstIndex(of: current) {
                let next = index + (press.key == .leftArrow ? -1 : 1)
                if tabs.indices.contains(next) { player.panelTab = tabs[next] }
            }
            return .handled
        case .downArrow:
            if focus == .tabs {
                if let first = rows.first { player.panelFocus = .row(first) }
            } else if case .row(let id) = focus, let index = rows.firstIndex(of: id), index + 1 < rows.count {
                player.panelFocus = .row(rows[index + 1])
            }
            return .handled
        case .upArrow:
            if case .row(let id) = focus {
                if let index = rows.firstIndex(of: id), index > 0 {
                    player.panelFocus = .row(rows[index - 1])
                } else {
                    player.panelFocus = .tabs
                }
            }
            return .handled
        case .tab:
            // Tab sale del panel a los controles del video.
            player.panelFocus = nil
            player.focusedControl = .playPause
            return .handled
        case .return:
            if case .row(let id) = focus { player.activatePanelRow(id) }
            return .handled
        case .delete, .deleteForward:
            if case .row(let id) = focus, id.hasPrefix("q:"), let item = player.panelItem(id) {
                app.queue.remove(item)
                player.panelFocus = .row(rows.first { $0.hasPrefix("q:") && $0 != id } ?? "sug:autoplay")
            }
            return .handled
        default:
            break
        }
        guard case .row(let id) = focus else { return nil }
        switch press.characters.lowercased() {
        case "q":
            if let item = player.panelItem(id) { app.enqueue(item, next: false); return .handled }
        case "n":
            if let item = player.panelItem(id) { app.enqueue(item, next: true); return .handled }
        case "g":
            if let comment = player.panelComment(id), app.accounts.isSignedIn, comment.likeAction != nil {
                player.comments?.toggleLike(comment) { player.showToast($0) }
                return .handled
            }
        case "r":
            if let comment = player.panelComment(id), app.accounts.isSignedIn, comment.replyParams != nil {
                player.comments?.beginReply(to: comment)
                return .handled
            }
        default:
            break
        }
        return nil
    }
}
