import Foundation
import YTKit

/// `ytkit compare`: pide lo mismo por TV y por WEB y mide qué trae cada una (la tabla de NOTAS.md).
@MainActor
struct Compare {
    let service: YouTubeService
    let options: Options

    struct Coverage {
        var label: String
        var seconds: Double
        var rows = 0
        var items = 0
        var videos = 0
        var author = 0, channelId = 0, views = 0, published = 0, duration = 0, snippet = 0, avatar = 0, badges = 0
        var maxThumbWidth = 0
        var shorts = 0, channels = 0, playlists = 0, live = 0
        var pagination = ""

        init(label: String, seconds: Double, page: BrowsePage) {
            self.label = label
            self.seconds = seconds
            rows = page.groups.count
            let all = page.groups.flatMap(\.items)
            items = all.count
            for item in all {
                switch item.kind {
                case .channel: channels += 1
                case .playlist, .mix: playlists += 1
                case .video:
                    if item.isShort { shorts += 1; continue }
                    videos += 1
                    if item.isLive { live += 1 }
                    if item.author != nil { author += 1 }
                    if item.channelId != nil { channelId += 1 }
                    if item.viewCountText != nil { views += 1 }
                    if item.publishedText != nil { published += 1 }
                    if item.durationText != nil { duration += 1 }
                    if item.descriptionSnippet != nil { snippet += 1 }
                    if !item.authorThumbnails.isEmpty { avatar += 1 }
                    if !item.badges.isEmpty { badges += 1 }
                }
                maxThumbWidth = max(maxThumbWidth, item.thumbnails.compactMap(\.width).max() ?? 0)
            }
            let rowCont = page.groups.filter { $0.continuation != nil }.count
            pagination = "\(rowCont) filas" + (page.continuation != nil ? " + página" : "")
        }

        func pct(_ n: Int) -> String { videos == 0 ? "-" : "\(n * 100 / videos) %" }

        var row: String {
            "| \(label) | \(String(format: "%.1f", seconds)) s | \(rows) | \(items) | \(videos) / \(shorts) / \(channels) / \(playlists) | "
                + "\(pct(author)) | \(pct(channelId)) | \(pct(views)) | \(pct(published)) | \(pct(duration)) | \(pct(snippet)) | "
                + "\(pct(avatar)) | \(maxThumbWidth) px | \(pagination) |"
        }
    }

    static let header = """
        | Pedido | Tiempo | Filas | Elementos | Videos / Shorts / canales / listas | Autor | Id de canal | Vistas | Fecha | Duración | Extracto | Avatar | Miniatura máx. | Continuación |
        |---|---|---|---|---|---|---|---|---|---|---|---|---|---|
        """

    func measure(_ label: String, _ work: () async throws -> BrowsePage) async -> Coverage? {
        let start = Date()
        do {
            let page = try await work()
            return Coverage(label: label, seconds: Date().timeIntervalSince(start), page: page)
        } catch {
            print("| \(label) | error: \(error) |")
            return nil
        }
    }

    func run() async throws {
        let query = options.value("--query") ?? "lofi hip hop"
        let videoId = options.value("--video") ?? "rfscVS0vtbw"
        var rows: [Coverage] = []

        for surface in Surface.allCases {
            // Inicio real (sin el sustituto): ¿trae algo sin cuenta?
            let browseId = surface == .tv ? "default" : "FEwhat_to_watch"
            if let raw = try? await service.rawRequest("browse", surface: surface, fields: ["browseId": browseId]),
               let page = try? await YouTubeService.parsePage(raw, surface: surface, api: .browse, kind: .home) {
                print("Inicio real \(surface.rawValue): \(page.itemCount) elementos; aviso: \(page.notice ?? "-")")
            }
        }
        print("")
        for surface in Surface.allCases {
            if let c = await measure("Inicio sustituto \(surface.rawValue)", { try await service.home(surface: surface) }) { rows.append(c) }
        }
        for topic in [Topic.music, .news] {
            for surface in Surface.allCases {
                if let c = await measure("Tema \(topic.rawValue) \(surface.rawValue)", { try await service.topic(topic, surface: surface) }) {
                    rows.append(c)
                }
            }
        }
        for surface in Surface.allCases {
            if let c = await measure("Búsqueda «\(query)» \(surface.rawValue)", { try await service.search(query, surface: surface) }) {
                rows.append(c)
            }
        }
        for surface in Surface.allCases {
            if let c = await measure("Canal MrBeast, Inicio, \(surface.rawValue)", {
                try await service.channel("UCX6OQ3DkcsbYNE6H8uQQuVA", tab: .home, surface: surface).content
            }) { rows.append(c) }
        }
        print(Self.header)
        for row in rows { print(row.row) }
        print("\nPorcentajes sobre los videos que no son Shorts.\n")

        print("| next \(videoId) | Tiempo | Título | Canal (id, avatar, suscriptores) | Vistas exactas | Me gusta | Fecha | Descripción | Capítulos | Mapa de calor | Sugeridos | Siguiente | Comentarios |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for surface in Surface.allCases {
            let start = Date()
            do {
                let m = try await service.metadata(videoId: videoId, surface: surface)
                let suggestions = m.suggestions.reduce(0) { $0 + $1.items.count }
                let mark = { (b: Bool) in b ? "sí" : "no" }
                print("| \(surface.rawValue) | \(String(format: "%.1f", Date().timeIntervalSince(start))) s | \(mark(m.title != nil)) | "
                      + "\(mark(m.channelId != nil)), \(mark(!m.authorThumbnails.isEmpty)), \(mark(m.subscriberCountText != nil)) | "
                      + "\(m.viewCountText ?? "-") | \(m.likeCountText ?? "-") | \(m.publishedDate ?? "-") | \(m.description?.count ?? 0) car. | "
                      + "\(m.chapters.count) | \(m.heatMap.count) | \(m.suggestions.count) filas, \(suggestions) | \(m.nextVideoId ?? "-") | "
                      + "\(mark(m.commentsContinuation != nil)) |")
            } catch {
                print("| \(surface.rawValue) | error: \(error) |")
            }
        }
    }
}
