import Foundation
import YTKit

/// Salida legible (o JSON con `--json`) de páginas, canales y metadatos.
struct Printer {
    let rows: Int
    let items: Int
    let json: Bool

    func dumpJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
    }

    func page(_ page: BrowsePage, header: Bool = true) {
        if json { return dumpJSON(page) }
        if header {
            var line = "\(page.title ?? "Página") [\(page.surface.rawValue)]: \(page.groups.count) filas, \(page.itemCount) elementos"
            if page.continuation != nil { line += ", más filas por continuación" }
            if page.isFallback { line += " — SUSTITUTO" }
            print(line)
            if let notice = page.notice { print("  aviso de YouTube: \(notice)") }
        }
        for group in page.groups.prefix(rows) {
            var line = "\n▸ \(group.title ?? "(sin título)") — \(group.items.count) [\(group.renderer)]"
            if group.continuation != nil { line += " +continuación" }
            if group.isShorts { line += " · Shorts" }
            print(line)
            self.items(group.items)
        }
        if page.groups.count > rows { print("\n… y \(page.groups.count - rows) filas más (--rows)") }
        stats(page.stats)
    }

    func items(_ list: [MediaItem]) {
        for (index, item) in list.prefix(items).enumerated() {
            print("   \(index + 1). \(describe(item))")
        }
        if list.count > items { print("   … \(list.count - items) más") }
    }

    func describe(_ item: MediaItem) -> String {
        var flags: [String] = []
        if item.isLive { flags.append("EN VIVO") }
        if item.isUpcoming { flags.append("PRÓXIMO") }
        if item.isShort { flags.append("Short") }
        var parts = ["[\(item.kind.rawValue)] \(item.title.prefix(70))"]
        if let duration = item.durationText { parts.append(duration) }
        if !flags.isEmpty { parts.append(flags.joined(separator: ",")) }
        var detail: [String] = []
        switch item.kind {
        case .video:
            if let author = item.author { detail.append(author) }
            if let views = item.viewCountText { detail.append(views) }
            if let published = item.publishedText { detail.append(published) }
        case .channel:
            if let handle = item.handle { detail.append(handle) }
            if let subscribers = item.subscriberCountText { detail.append(subscribers) }
        case .playlist, .mix:
            if let author = item.author { detail.append(author) }
            if let count = item.videoCountText { detail.append(count) }
        }
        let id = item.id
        var line = parts.joined(separator: " · ") + "\n      \(id)"
        if !detail.isEmpty { line += " · " + detail.joined(separator: " · ") }
        if let channel = item.channelId, item.kind != .channel { line += " · canal \(channel)" }
        if let thumbnail = item.thumbnails.best(forWidth: 10_000) { line += " · miniatura \(thumbnail.width ?? 0)x\(thumbnail.height ?? 0)" }
        return line
    }

    func stats(_ stats: ParseStats) {
        let ignored = stats.ignored.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        let failed = stats.failed.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        let dropped = stats.dropped.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        if !ignored.isEmpty { print("\n  ignorados a propósito: \(ignored.joined(separator: ", "))") }
        if !failed.isEmpty { print("  FALLARON al decodificar: \(failed.joined(separator: ", "))") }
        if !dropped.isEmpty { print("  descartados (sin título o id): \(dropped.joined(separator: ", "))") }
    }

    func channel(_ page: ChannelPage, requested: ChannelTab.Kind) {
        if json { return dumpJSON(page) }
        print("\(page.title ?? page.channelId) \(page.handle ?? "") [\(page.content.surface.rawValue)]")
        print("  id \(page.channelId) · \(page.subscriberCountText ?? "-") · \(page.videoCountText ?? "-")")
        if let description = page.description {
            print("  \(description.replacingOccurrences(of: "\n", with: " ").prefix(160))")
        }
        print("  avatar \(page.avatar.best(forWidth: 10_000)?.width ?? 0) px · banner \(page.banner.best(forWidth: 10_000)?.width ?? 0) px")
        if !page.tabs.isEmpty {
            let tabs = page.tabs.map { ($0.isSelected ? "*" : "") + "\($0.title) (\($0.kind.rawValue))" }
            print("  pestañas: \(tabs.joined(separator: ", "))")
        }
        if let selected = page.selectedTab, selected != requested {
            print("  aviso: se pidió «\(requested.rawValue)» y YouTube devolvió «\(selected.rawValue)» (el canal no tiene esa pestaña)")
        }
        print("")
        self.page(page.content, header: true)
    }

    func metadata(_ meta: MediaItemMetadata) {
        if json { return dumpJSON(meta) }
        print("\(meta.title ?? meta.videoId) [\(meta.surface.rawValue)]")
        print("  canal: \(meta.author ?? "-") (\(meta.channelId ?? "-")) · \(meta.subscriberCountText ?? "-") · avatar \(meta.authorThumbnails.count)")
        print("  \(meta.viewCountText ?? "-") · corto \(meta.shortViewCountText ?? "-") · me gusta \(meta.likeCountText ?? "-")")
        print("  publicado \(meta.publishedDate ?? "-") · \(meta.relativeDate ?? "-")\(meta.isLive ? " · EN VIVO" : "")")
        if !meta.badges.isEmpty { print("  insignias: \(meta.badges.joined(separator: ", "))") }
        if let description = meta.description {
            print("  descripción (\(description.count) car.): \(description.replacingOccurrences(of: "\n", with: " ").prefix(200))")
        }
        print("  capítulos: \(meta.chapters.count) · mapa de calor: \(meta.heatMap.count) tramos · comentarios: \(meta.commentsContinuation == nil ? "sin token" : "token") \(meta.commentsCountText ?? "") · chat: \(meta.liveChatContinuation == nil ? "no" : "sí")")
        for chapter in meta.chapters.prefix(items + 2) {
            let start = chapter.startMs / 1000
            print(String(format: "     %d:%02d:%02d %@%@", start / 3600, start / 60 % 60, start % 60, chapter.title,
                         chapter.durationMs.map { " (\($0 / 1000) s)" } ?? ""))
        }
        if meta.chapters.count > items + 2 { print("     … \(meta.chapters.count - items - 2) más") }
        if let next = meta.nextVideoId {
            print("  siguiente (autoplay): \(next)\(meta.nextVideo.map { " — \($0.title)" } ?? "")")
        }
        let total = meta.suggestions.reduce(0) { $0 + $1.items.count }
        print("\nSugeridos: \(meta.suggestions.count) filas, \(total) elementos\(meta.suggestionsContinuation != nil ? ", más filas por continuación" : "")")
        for group in meta.suggestions.prefix(rows) {
            print("\n▸ \(group.title ?? "(sin título)") — \(group.items.count) [\(group.renderer)]\(group.continuation != nil ? " +continuación" : "")")
            items(group.items)
        }
        stats(meta.stats)
    }

    /// Comentarios sin datos de quien comenta: inicial del nombre, fecha, me gusta, respuestas y el principio del texto.
    func comments(_ comments: [Comment]) {
        if json { return dumpJSON(comments) }
        for comment in comments.prefix(items + 2) {
            let replies = comment.replyCount.map { " · \($0) resp." } ?? ""
            print("   \(comment.author.prefix(2))… · \(comment.publishedText ?? "-") · \(comment.likeCountText ?? "0") me gusta\(replies)\(comment.likeAction != nil ? " · acción me gusta" : "")\(comment.replyParams != nil ? " · responder" : "")")
            print("      \(comment.text.replacingOccurrences(of: "\n", with: " ").prefix(90))")
        }
        if comments.count > items + 2 { print("   … \(comments.count - items - 2) más") }
    }
}
