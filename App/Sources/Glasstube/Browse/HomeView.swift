import SwiftUI
import YTKit

/// Inicio: banner del video destacado (se extiende bajo la barra lateral con `.backgroundExtensionEffect()`),
/// "Seguir viendo" (historial local) y "Para ti", y después las demás filas del Inicio de YTKit.
///
/// Sin cuenta, YouTube no da recomendaciones: YTKit arma el Inicio con las primeras filas de Explorar
/// (`BrowsePage.isFallback`), y "Para ti" mezcla esas filas.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @ViewState private var page: BrowsePage?
    @ViewState private var failure: String?
    @ViewState private var width: CGFloat = 1100
    @ViewState private var grid = GridFocus()
    @FocusState private var gridFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let featured {
                    FeaturedBanner(item: featured, badge: featuredBadge)
                } else {
                    Color.clear.frame(height: 24)
                }
                content
                    .padding(.horizontal, GridMetrics.pagePadding)
                    .padding(.top, featured == nil ? 0 : 28)
                    .padding(.bottom, 36)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width - GridMetrics.pagePadding * 2 } action: { width = $0 }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        // El banner empieza en el borde de la ventana, bajo la barra de herramientas de vidrio (como en la maqueta).
        .ignoresSafeArea(.container, edges: featured == nil ? [] : .top)
        .modifier(GridKeyboardNavigation(sections: sections.map { ($0.items, columns(for: $0.items)) }, grid: grid, isFocused: $gridFocused) { model.open($0) })
        .task(id: model.reloadToken) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let page {
            VStack(alignment: .leading, spacing: 34) {
                ForEach(sections.indices, id: \.self) { index in
                    let section = sections[index]
                    CardSection(title: section.title, items: section.items, section: index, grid: grid,
                                progress: section.isContinue ? { library.progress(for: $0.videoId) } : { _ in nil },
                                seeAll: section.seeAll)
                }
                if page.isFallback {
                    Label("Sin cuenta, YouTube no da recomendaciones: este Inicio se arma con Explorar (Música, Gaming, Noticias, Deportes y En vivo).",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let failure {
            LoadStateView(state: .failed(failure)) { Task { await load() } }
        } else {
            LoadStateView(state: .loading)
        }
    }

    private struct Section {
        var title: String?
        var items: [MediaItem]
        var isContinue = false
        var seeAll: (() -> Void)?
    }

    private func columns(for items: [MediaItem]) -> Int {
        items.allSatisfy(\.isShort) ? items.count : GridMetrics.columns(for: width)
    }

    /// Videos del Inicio sin Shorts (salvo que se pidan) y sin lo oculto o bloqueado.
    private var groups: [MediaGroup] {
        guard let page else { return [] }
        return page.groups.compactMap { group in
            var group = group
            group.items = library.visible(group.items).filter { settings.showShortsOnHome || !$0.isShort }
            return group.items.isEmpty ? nil : group
        }
    }

    /// "Para ti": las filas intercaladas (una de cada una por turno), solo videos, sin repetir, hasta 2 filas.
    private var forYou: [MediaItem] {
        let lists = groups.map { $0.items.filter { $0.kind == .video && !$0.isShort } }
        var result: [MediaItem] = []
        var seen = Set<String>()
        var round = 0
        let limit = max(8, GridMetrics.columns(for: width) * 2)
        while result.count < limit, lists.contains(where: { $0.count > round }) {
            for list in lists where list.count > round && result.count < limit {
                let item = list[round]
                if seen.insert(item.id).inserted { result.append(item) }
            }
            round += 1
        }
        return result
    }

    private var featured: MediaItem? {
        forYou.first { !$0.isLive } ?? forYou.first
    }

    private var featuredBadge: String {
        guard let featured, let group = groups.first(where: { $0.items.contains(featured) }), let title = group.title,
              title.localizedCaseInsensitiveCompare("Destacados") != .orderedSame else {
            return "Destacado en Explorar"
        }
        return "Destacado · \(title)"
    }

    private var sections: [Section] {
        var result: [Section] = []
        let continuing = library.visible(library.continueWatching.map(\.item)).prefix(GridMetrics.columns(for: width))
        if !continuing.isEmpty {
            result.append(Section(title: "Seguir viendo", items: Array(continuing), isContinue: true,
                                  seeAll: { model.navigator.go(.section(.history)) }))
        }
        let picks = forYou.filter { $0 != featured }
        if !picks.isEmpty {
            result.append(Section(title: "Para ti", items: picks))
        }
        let used = Set(forYou.map(\.id))
        for group in groups {
            let rest = group.items.filter { !used.contains($0.id) }
            guard !rest.isEmpty else { continue }
            let limit = rest.allSatisfy(\.isShort) ? rest.count : GridMetrics.columns(for: width) * 2
            let hasMore = rest.count > limit || group.continuation != nil
            result.append(Section(title: group.title, items: Array(rest.prefix(limit)),
                                  seeAll: hasMore ? { model.navigator.go(.group(group)) } : nil))
        }
        return result
    }

    private func load() async {
        failure = nil
        if Log.verbose { NSLog("Glasstube: Inicio: pidiendo (recarga \(model.reloadToken))") }
        do {
            let loaded = try await model.service.home()
            if Log.verbose { NSLog("Glasstube: Inicio: \(loaded.groups.count) filas, \(loaded.itemCount) elementos (cancelada: \(Task.isCancelled))") }
            withAnimation(.smooth) { page = loaded }
            if !model.searchFieldFocused {
                try? await Task.sleep(for: .milliseconds(100))
                model.focusContent()
            }
            if let index = Automation.shared.hoverIndex {
                let picks = forYou.filter { $0 != featured }
                if picks.indices.contains(index) { Automation.shared.forcedHoverId = picks[index].videoId }
            }
        } catch where error.isCancellation {
            if Log.verbose { NSLog("Glasstube: Inicio: cancelado") }
        } catch {
            if Log.verbose { NSLog("Glasstube: Inicio: error \(error)") }
            if page == nil { failure = "\(error)" }
        }
    }
}

/// Banner del video destacado. La imagen es contenido opaco y se extiende bajo la barra lateral y la barra de
/// herramientas; solo los botones (controles) llevan vidrio.
struct FeaturedBanner: View {
    let item: MediaItem
    let badge: String
    @Environment(AppModel.self) private var model
    @Environment(LocalLibrary.self) private var library

    static let height: CGFloat = 392

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urls: MediaItemImages.banner(item))
                .overlay { LateImage(url: model.deArrow.thumbnailURL(for: item)) }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 210)
                }
                .frame(height: Self.height)
                .backgroundExtensionEffect()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                Text(badge)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.35), in: .capsule)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.38), lineWidth: 1))
                Text(model.deArrow.title(for: item))
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                    .lineLimit(2)
                    .frame(maxWidth: 620, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Text(meta)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.88))
                HStack(spacing: 10) {
                    Button { model.play(item) } label: {
                        Label("Reproducir", systemImage: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)

                    Button { library.toggleWatchLater(item) } label: {
                        Label(library.isInWatchLater(item) ? "En Ver más tarde" : "Ver más tarde",
                              systemImage: library.isInWatchLater(item) ? "checkmark" : "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 6)
                            .frame(height: 30)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, GridMetrics.pagePadding + 4)
            .padding(.bottom, 30)
        }
        .frame(height: Self.height)
        .contextMenu { ItemMenu(item: item) }
    }

    private var meta: String {
        [item.author, item.durationBadge, item.publishedText ?? item.viewCountText].compactMap { $0 }.joined(separator: " · ")
    }
}
