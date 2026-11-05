import SwiftUI
import YTKit

/// Medidas del modo TV a partir del tamaño de la ventana (pensadas para 1920×1080 y escaladas de 0,7 a 1,4).
nonisolated struct TVMetrics {
    let size: CGSize
    var scale: CGFloat { min(1.4, max(0.7, min(size.width / 1920, size.height / 1080))) }
    var cardWidth: CGFloat { 400 * scale }
    var shortWidth: CGFloat { 220 * scale }
    var menuExpanded: CGFloat { 330 * scale }
    var menuCollapsed: CGFloat { 104 * scale }
    var heroHeight: CGFloat { max(260 * scale, size.height * 0.36) }
    var margin: CGFloat { 56 * scale }
    func font(_ points: CGFloat) -> CGFloat { points * scale }
}

/// El modo TV (fase 5b): fondo oscuro y opaco con la imagen de la tarjeta enfocada, el menú de secciones en una columna de
/// vidrio (se encoge a íconos mientras el foco está en las filas, como los encabezados de Leanback), la ficha grande de lo
/// enfocado y las filas de tarjetas. El vidrio es solo para la navegación y la ayuda de teclas: las tarjetas y el texto
/// son contenido. El foco es un anillo blanco grueso y la tarjeta crece (sin crecer con «Reducir movimiento»).
struct TVModeView: View {
    let tv: TVMode
    @Environment(AppModel.self) private var model
    @Environment(LocalLibrary.self) private var library
    private var reduceMotion: Bool { Motion.isReduced }
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { proxy in
            let metrics = TVMetrics(size: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.black
                TVBackdrop(item: tv.focusedItem, metrics: metrics)
                HStack(alignment: .top, spacing: 0) {
                    TVSectionMenu(tv: tv, metrics: metrics)
                        .padding(.leading, metrics.margin * 0.6)
                        .padding(.vertical, metrics.margin * 0.6)
                    VStack(alignment: .leading, spacing: 0) {
                        TVHero(tv: tv, metrics: metrics)
                            .frame(height: metrics.heroHeight, alignment: .bottomLeading)
                        TVRows(tv: tv, metrics: metrics)
                    }
                    .padding(.leading, metrics.margin * 0.7)
                }
                TVOverlay(tv: tv, metrics: metrics)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: tv.focus)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space, .escape]) { press in
            let key: TVMode.Key = switch press.key {
            case .upArrow: .up
            case .downArrow: .down
            case .leftArrow: .left
            case .rightArrow: .right
            case .escape: .back
            default: .enter
            }
            NSCursor.setHiddenUntilMouseMoves(true)
            return tv.handle(key) ? .handled : .ignored
        }
        .onAppear {
            focused = true
            tv.start()
        }
        // Al cerrar el reproductor (y al pedirlo la app), el foco vuelve aquí.
        .onChange(of: model.contentFocusRequest) { focused = true }
        .onChange(of: model.player == nil) { _, closed in if closed { focused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Modo TV")
        .accessibilityHint("Flechas para moverte, Retorno para abrir y Esc para volver")
    }
}

/// La imagen de lo enfocado arriba a la derecha, fundida con el negro hacia la izquierda y hacia abajo (contenido opaco,
/// sin desenfoques propios).
private struct TVBackdrop: View {
    let item: MediaItem?
    let metrics: TVMetrics

    var body: some View {
        ZStack {
            if let item {
                RemoteImage(urls: MediaItemImages.banner(item))
                    .frame(width: metrics.size.width * 0.66, height: metrics.size.width * 0.66 * 9 / 16)
                    .clipped()
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.45)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .opacity(0.55)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: item?.id)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// El menú de secciones: una columna de vidrio. La sección elegida va resaltada; con el foco en el menú, en blanco con
/// texto negro (como el foco de tvOS).
private struct TVSectionMenu: View {
    let tv: TVMode
    let metrics: TVMetrics
    private var reduceMotion: Bool { Motion.isReduced }

    private var expanded: Bool { tv.focus == .menu }

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 6 * metrics.scale) {
                Image(systemName: "play.tv")
                    .font(.system(size: metrics.font(30), weight: .semibold))
                    .frame(width: metrics.menuCollapsed - 28 * metrics.scale, height: 54 * metrics.scale)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 4 * metrics.scale) {
                            ForEach(Array(tv.sections.enumerated()), id: \.element.id) { index, section in
                                row(section, index: index).id(section.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: tv.selected) { _, index in
                        guard tv.sections.indices.contains(index) else { return }
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { proxy.scrollTo(tv.sections[index].id, anchor: .center) }
                    }
                }
            }
            .padding(14 * metrics.scale)
            .frame(width: expanded ? metrics.menuExpanded : metrics.menuCollapsed, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .glassEffect(.regular, in: .rect(cornerRadius: 34 * metrics.scale))
        }
    }

    private func row(_ section: TVSection, index: Int) -> some View {
        let isSelected = index == tv.selected
        let isFocused = isSelected && tv.focus == .menu
        return Button { tv.click(section: index) } label: {
            HStack(spacing: 16 * metrics.scale) {
                Image(systemName: tv.symbol(of: section))
                    .font(.system(size: metrics.font(24), weight: .semibold))
                    .frame(width: 40 * metrics.scale)
                if expanded {
                    Text(tv.title(of: section))
                        .font(.system(size: metrics.font(24), weight: isSelected ? .bold : .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isFocused ? Color.black : (isSelected ? Color.white : Color.white.opacity(0.72)))
            .padding(.horizontal, 12 * metrics.scale)
            .frame(maxWidth: .infinity, minHeight: 54 * metrics.scale, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20 * metrics.scale)
                    .fill(isFocused ? Color.white : (isSelected ? Color.white.opacity(0.16) : .clear))
            }
            .contentShape(.rect(cornerRadius: 20 * metrics.scale))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tv.title(of: section))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// La ficha grande: con el foco en una tarjeta, su título y datos; en el menú, el nombre de la sección.
private struct TVHero: View {
    let tv: TVMode
    let metrics: TVMetrics
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * metrics.scale) {
            if let item = tv.focusedItem {
                Text(model.deArrow.title(for: item))
                    .font(.system(size: metrics.font(46), weight: .bold))
                    .tracking(-0.8)
                    .lineLimit(2)
                    .frame(maxWidth: metrics.size.width * 0.55, alignment: .leading)
                Text(meta(item))
                    .font(.system(size: metrics.font(21)))
                    .foregroundStyle(.white.opacity(0.82))
            } else {
                Text(tv.page?.title ?? "Glasstube")
                    .font(.system(size: metrics.font(56), weight: .bold))
                    .tracking(-1)
                Text(tv.page?.rows.isEmpty == false ? String(localized: "→ o Retorno para entrar a las filas · Esc para salir del modo TV") : " ")
                    .font(.system(size: metrics.font(20)))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.bottom, 26 * metrics.scale)
        .padding(.top, metrics.margin)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func meta(_ item: MediaItem) -> String {
        var parts: [String] = []
        if let author = item.author { parts.append(author) }
        if item.isLive { parts.append(String(localized: "En vivo")) } else if let duration = item.durationBadge { parts.append(duration) }
        if let text = item.publishedText ?? item.viewCountText { parts.append(text) }
        if item.kind == .channel { parts.append(String(localized: "Canal")) }
        if item.kind == .playlist { parts.append(item.videoCountText ?? String(localized: "Playlist")) }
        return parts.joined(separator: " · ")
    }
}

/// Las filas de tarjetas de la página de arriba. La fila enfocada se lleva a la vista y cada fila a su tarjeta.
private struct TVRows: View {
    let tv: TVMode
    let metrics: TVMetrics
    private var reduceMotion: Bool { Motion.isReduced }

    var body: some View {
        if let page = tv.page {
            switch page.state {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty(let message), .failed(let message):
                Label(message, systemImage: page.state == .failed(message) ? "wifi.exclamationmark" : "rectangle.on.rectangle.slash")
                    .font(.system(size: metrics.font(24)))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 20 * metrics.scale)
            case .loaded:
                rows(page)
            }
        }
    }

    private func rows(_ page: TVPage) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 36 * metrics.scale) {
                    ForEach(Array(page.rows.enumerated()), id: \.element.id) { index, row in
                        TVRowView(tv: tv, row: row, index: index, column: page.column(of: index),
                                  isFocusedRow: tv.focus == .content && page.row == index, metrics: metrics)
                            .id(row.id)
                    }
                }
                .padding(.bottom, metrics.size.height * 0.4)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
            .onChange(of: page.row) { _, row in
                guard page.rows.indices.contains(row) else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) { proxy.scrollTo(page.rows[row].id, anchor: .top) }
            }
        }
    }
}

private struct TVRowView: View {
    let tv: TVMode
    let row: TVRow
    let index: Int
    let column: Int
    let isFocusedRow: Bool
    let metrics: TVMetrics
    private var reduceMotion: Bool { Motion.isReduced }
    @Environment(LocalLibrary.self) private var library

    private var isShorts: Bool { row.items.allSatisfy(\.isShort) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * metrics.scale) {
            Text(row.title)
                .font(.system(size: metrics.font(26), weight: .bold))
                .foregroundStyle(isFocusedRow ? .white : .white.opacity(0.7))
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 30 * metrics.scale) {
                        ForEach(Array(row.items.enumerated()), id: \.offset) { offset, item in
                            TVCard(item: item, isFocused: isFocusedRow && offset == column, isShort: isShorts,
                                   width: isShorts ? metrics.shortWidth : metrics.cardWidth, metrics: metrics,
                                   progress: library.progress(for: item.videoId)) {
                                tv.click(row: index, column: offset)
                            }
                            .id(offset)
                        }
                    }
                    .padding(.vertical, 20 * metrics.scale)
                    .padding(.trailing, metrics.margin)
                }
                .scrollIndicators(.never)
                .scrollClipDisabled()
                .onChange(of: column) { _, column in
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { proxy.scrollTo(column, anchor: UnitPoint(x: 0.08, y: 0.5)) }
                }
            }
        }
        .opacity(tv.focus == .menu || isFocusedRow ? 1 : 0.8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.title)
    }
}

/// Una tarjeta grande: miniatura (16:9, o vertical en los Shorts), duración, progreso y título. El foco es un anillo
/// blanco de 5 pt fuera de la miniatura, una sombra y, sin «Reducir movimiento», un 8 % más grande.
private struct TVCard: View {
    let item: MediaItem
    let isFocused: Bool
    let isShort: Bool
    let width: CGFloat
    let metrics: TVMetrics
    let progress: Double?
    let action: () -> Void
    @Environment(AppModel.self) private var model
    private var reduceMotion: Bool { Motion.isReduced }
    @Environment(\.colorSchemeContrast) private var contrast

    private var radius: CGFloat { 18 * metrics.scale }
    private var thumbnailHeight: CGFloat { isShort ? width * 16 / 9 : width * 9 / 16 }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12 * metrics.scale) {
                RemoteImage(urls: MediaItemImages.card(item, width: 640))
                    .overlay { LateImage(url: model.deArrow.thumbnailURL(for: item)) }
                    .frame(width: width, height: thumbnailHeight)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge = item.isLive ? String(localized: "EN VIVO") : item.durationBadge {
                            Text(badge)
                                .font(.system(size: metrics.font(16), weight: .bold).monospacedDigit())
                                .padding(.horizontal, 8 * metrics.scale)
                                .padding(.vertical, 4 * metrics.scale)
                                .background(item.isLive ? Color.red : Color.black.opacity(0.75), in: .rect(cornerRadius: 6 * metrics.scale))
                                .padding(10 * metrics.scale)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress, progress > 0.01 {
                            GeometryReader { geometry in
                                Rectangle().fill(.red).frame(width: geometry.size.width * progress)
                            }
                            .frame(height: 5 * metrics.scale)
                            .background(.white.opacity(0.35))
                        }
                    }
                    .clipShape(.rect(cornerRadius: radius))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius + 7 * metrics.scale)
                            .strokeBorder(.white, lineWidth: (contrast == .increased ? 7 : 5) * metrics.scale)
                            .padding(-7 * metrics.scale)
                            .opacity(isFocused ? 1 : 0)
                    }
                    .shadow(color: .black.opacity(isFocused ? 0.7 : 0), radius: 26 * metrics.scale, y: 14 * metrics.scale)
                    .scaleEffect(isFocused && !reduceMotion ? 1.08 : 1)
                VStack(alignment: .leading, spacing: 4 * metrics.scale) {
                    Text(model.deArrow.title(for: item))
                        .font(.system(size: metrics.font(isShort ? 18 : 21), weight: .semibold))
                        .lineLimit(2)
                        .foregroundStyle(isFocused ? .white : .white.opacity(0.85))
                    if let author = item.author, !isShort {
                        Text(author)
                            .font(.system(size: metrics.font(17)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: width, alignment: .leading)
                // La miniatura crece un 8 % desde el centro: el título baja lo que crece por abajo, más el anillo.
                .padding(.top, isFocused ? (reduceMotion ? 0 : thumbnailHeight * 0.04) + 6 * metrics.scale : 0)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isFocused)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        [model.deArrow.title(for: item), item.author, item.isLive ? String(localized: "en vivo") : item.durationBadge, isShort ? String(localized: "Short") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// Hora arriba a la derecha y, abajo, la ayuda de teclas en una cápsula de vidrio.
private struct TVOverlay: View {
    let tv: TVMode
    let metrics: TVMetrics

    var body: some View {
        ZStack {
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: metrics.font(24), weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, metrics.margin * 0.6)
                    .padding(.trailing, metrics.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            GlassEffectContainer {
                HStack(spacing: 22 * metrics.scale) {
                    hint("arrow.up.and.down.and.arrow.left.and.right", String(localized: "Moverse"))
                    hint("return", String(localized: "Abrir"))
                    hint("escape", tv.focus == .menu ? String(localized: "Salir") : String(localized: "Atrás"))
                    if !tv.controllers.connected.isEmpty { hint("gamecontroller", String(localized: "A abrir · B atrás")) }
                }
                .font(.system(size: metrics.font(17), weight: .medium))
                .padding(.horizontal, 22 * metrics.scale)
                .padding(.vertical, 12 * metrics.scale)
                .glassEffect(.regular, in: .capsule)
            }
            .padding(.bottom, metrics.margin * 0.5)
            .padding(.trailing, metrics.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8 * metrics.scale) {
            Image(systemName: symbol)
            Text(text)
        }
    }
}
