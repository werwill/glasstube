import Foundation

// Feeds RSS de canal (`RssService` + `YouTubeRssParser` de SmartTube): `https://www.youtube.com/feeds/videos.xml?
// channel_id=UC…`, sin cuenta ni Innertube. Cada feed trae los últimos 15 videos del canal con título, fecha,
// miniatura, vistas y descripción; los Shorts se reconocen por su enlace (`/shorts/<id>`). Lo usan las suscripciones
// locales y los grupos de canales de la app.

/// Lo que da el feed de un canal.
public struct RSSChannelFeed: Codable, Sendable, Hashable {
    public var channelId: String
    /// Nombre del canal (`<feed><title>`).
    public var title: String?
    public var items: [MediaItem]

    public init(channelId: String, title: String?, items: [MediaItem]) {
        self.channelId = channelId
        self.title = title
        self.items = items
    }
}

/// Lee el XML (Atom con los espacios `yt:` y `media:`) de un feed de canal.
public enum RSSFeedParser {
    public static func url(channelId: String) -> URL {
        var components = URLComponents(string: "https://www.youtube.com/feeds/videos.xml")!
        components.queryItems = [URLQueryItem(name: "channel_id", value: channelId)]
        return components.url!
    }

    /// `channelId`: el que se pidió (el `<yt:channelId>` del feed llega sin el prefijo `UC`).
    public static func parse(_ data: Data, channelId: String? = nil) throws -> RSSChannelFeed {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse(), delegate.sawFeed else {
            throw YTKitError.badResponse("feed RSS ilegible: \(parser.parserError.map { "\($0)" } ?? "no es un <feed>")")
        }
        let id = channelId ?? delegate.channelId ?? delegate.items.first?.channelId ?? ""
        return RSSChannelFeed(channelId: id, title: delegate.channelTitle, items: delegate.items)
    }

    /// Recorre el XML como `YouTubeRssParser` (sin espacios de nombres: las etiquetas llegan como `yt:videoId`).
    private final class Delegate: NSObject, XMLParserDelegate {
        var sawFeed = false
        var channelTitle: String?
        var channelId: String?
        var items: [MediaItem] = []

        private var path: [String] = []
        private var text = ""
        private var entry: Entry?

        private struct Entry {
            var videoId: String?
            var channelId: String?
            var title: String?
            var author: String?
            var link: String?
            var published: Date?
            var thumbnail: Thumbnail?
            var description: String?
            var views: Int?
        }

        private static let dates: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            path.append(name)
            text = ""
            switch name {
            case "feed" where path.count == 1:
                sawFeed = true
            case "entry":
                entry = Entry()
            case "link" where entry != nil && attributes["rel"] == "alternate":
                entry?.link = attributes["href"]
            case "link" where entry == nil && attributes["rel"] == "alternate":
                // `https://www.youtube.com/channel/UC…`: el id completo del canal.
                if let href = attributes["href"], let range = href.range(of: "/channel/") {
                    channelId = String(href[range.upperBound...])
                }
            case "media:thumbnail" where entry != nil:
                if let url = attributes["url"] {
                    entry?.thumbnail = Thumbnail(url: url, width: attributes["width"].flatMap(Int.init),
                                                 height: attributes["height"].flatMap(Int.init))
                }
            case "media:statistics" where entry != nil:
                entry?.views = attributes["views"].flatMap(Int.init)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = path.count >= 2 ? path[path.count - 2] : nil
            if entry != nil {
                switch name {
                case "yt:videoId": entry?.videoId = value
                case "yt:channelId": entry?.channelId = value
                case "title" where parent == "entry": entry?.title = value
                case "name" where parent == "author": entry?.author = value
                case "published": entry?.published = Self.dates.date(from: value)
                case "media:description": entry?.description = value
                case "entry":
                    if let item = entry.flatMap(Self.item) { items.append(item) }
                    entry = nil
                default: break
                }
            } else if name == "title", parent == "feed" {
                channelTitle = value
            }
            path.removeLast()
            text = ""
        }

        private static func item(_ entry: Entry) -> MediaItem? {
            guard let videoId = entry.videoId, !videoId.isEmpty else { return nil }
            var item = MediaItem(kind: .video, title: entry.title ?? "", renderer: "rss")
            item.videoId = videoId
            item.channelId = entry.channelId
            item.author = entry.author
            item.publishedAt = entry.published
            item.viewCount = entry.views
            item.isShort = entry.link?.contains("/shorts/") == true
            item.thumbnails = entry.thumbnail.map { [$0] } ?? []
            // Para la tarjeta vertical de los Shorts, una más grande (la de 640 recortada al centro).
            if item.isShort { item.thumbnails.append(Thumbnail(url: "https://i.ytimg.com/vi/\(videoId)/sddefault.jpg", width: 640, height: 480)) }
            if let description = entry.description, !description.isEmpty {
                item.descriptionSnippet = String(description.prefix(240))
            }
            return item
        }
    }
}

/// Feeds de varios canales en paralelo y con caché (`RssService.getFeed` de SmartTube, que los pide todos a la vez y
/// los ordena del más nuevo al más viejo). Cada canal se guarda en memoria y en disco
/// (`~/Library/Caches/Glasstube/rss`): dentro de `ttl` no se vuelve a pedir, y si YouTube no responde se usa la copia
/// que haya, aunque sea vieja.
public actor RSSFeedService {
    public struct Result: Sendable {
        /// Del más nuevo al más viejo (sin repetidos).
        public var items: [MediaItem] = []
        /// Nombre de cada canal según su feed (para completar los que se importaron solo con el id).
        public var channelTitles: [String: String] = [:]
        /// Canales que no respondieron y de los que no había copia.
        public var failed: [String] = []
        /// Canales que salieron de la caché (vigente, o vieja porque YouTube no respondió).
        public var cached = 0
        /// Canales que no se pidieron por pasar de `maxChannels`.
        public var skipped = 0

        public init() {}
    }

    /// GET de una URL: cuerpo y estado HTTP. Las pruebas pasan uno falso.
    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    /// SmartTube corta en 100 canales porque en las cajas de TV «sin límite tarda muchísimo y a veces se cae»; en la Mac,
    /// con 8 a la vez y la caché, 200 tardan unos segundos la primera vez.
    public static let maxChannels = 200

    private struct Cached: Codable {
        var date: Date
        var feed: RSSChannelFeed
    }

    private let ttl: TimeInterval
    private let maxConcurrent: Int
    private let usesDisk: Bool
    private let fetch: Fetch
    private var memory: [String: Cached] = [:]
    private var inFlight: [String: Task<Cached?, Never>] = [:]
    /// Cuántas veces se pidió un feed a la red (pruebas y registro).
    public private(set) var fetchCount = 0

    public init(ttl: TimeInterval = 15 * 60, maxConcurrent: Int = 8, usesDisk: Bool = true, fetch: Fetch? = nil) {
        self.ttl = ttl
        self.maxConcurrent = max(1, maxConcurrent)
        self.usesDisk = usesDisk
        self.fetch = fetch ?? { url in
            let (data, response) = try await HTTP.shared.request(url, timeout: 20)
            return (data, response.statusCode)
        }
    }

    /// Los videos nuevos de `channelIds`, juntos y ordenados por fecha. `refresh` ignora la caché vigente (Recargar).
    /// `publishedText` y `viewCountText` se escriben en el idioma de `locale` al momento de pedirlos.
    public func feed(channelIds: [String], refresh: Bool = false, locale: CatalogLocale = .current) async -> Result {
        var unique: [String] = []
        var seen = Set<String>()
        for id in channelIds where seen.insert(id).inserted { unique.append(id) }
        var result = Result()
        result.skipped = max(0, unique.count - Self.maxChannels)
        let ids = Array(unique.prefix(Self.maxChannels))

        let feeds = await withTaskGroup(of: (String, Cached?, Bool).self) { group -> [(String, Cached?, Bool)] in
            var collected: [(String, Cached?, Bool)] = []
            var next = 0
            func launch() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask { await self.channel(id, refresh: refresh) }
            }
            for _ in 0..<min(maxConcurrent, ids.count) { launch() }
            while let finished = await group.next() {
                collected.append(finished)
                launch()
            }
            return collected
        }

        var items: [MediaItem] = []
        var known = Set<String>()
        for (id, cached, fromCache) in feeds {
            guard let cached else {
                result.failed.append(id)
                continue
            }
            if fromCache { result.cached += 1 }
            if let title = cached.feed.title { result.channelTitles[id] = title }
            for item in cached.feed.items where known.insert(item.id).inserted { items.append(item) }
        }
        let now = Date()
        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale(identifier: locale.language)
        relative.unitsStyle = .full
        items = items.map { item in
            var item = item
            if let date = item.publishedAt { item.publishedText = relative.localizedString(for: min(date, now), relativeTo: now) }
            if let views = item.viewCount { item.viewCountText = Self.viewsText(views, language: locale.language) }
            return item
        }
        result.items = items.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        result.failed.sort()
        return result
    }

    /// "2,3 mil vistas", "1,2 M de vistas" (como las tarjetas de YouTube en español), "2.3K views".
    static func viewsText(_ views: Int, language: String) -> String {
        // ICU separa el número de «K»/«M» con un espacio duro; las tarjetas de YouTube usan uno normal.
        let number = views.formatted(.number.notation(.compactName).locale(Locale(identifier: language)))
            .replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        guard language.hasPrefix("es") else { return views == 1 ? "1 view" : "\(number) views" }
        if views == 1 { return "1 vista" }
        return number.hasSuffix("M") ? "\(number) de vistas" : "\(number) vistas"
    }

    /// Feed de un canal: memoria → disco → red (y, si la red falla, la copia vieja). El `Bool` dice si salió de la caché.
    private func channel(_ id: String, refresh: Bool) async -> (String, Cached?, Bool) {
        let stored = memory[id] ?? readDisk(id)
        if let stored, !refresh, Date().timeIntervalSince(stored.date) < ttl {
            memory[id] = stored
            return (id, stored, true)
        }
        // Dos páginas que piden el mismo canal a la vez comparten la petición.
        let task = inFlight[id] ?? Task { await self.download(id) }
        inFlight[id] = task
        let fresh = await task.value
        inFlight[id] = nil
        if let fresh { return (id, fresh, false) }
        return (id, stored, stored != nil)
    }

    private func download(_ id: String) async -> Cached? {
        let url = RSSFeedParser.url(channelId: id)
        for attempt in 0..<2 {
            fetchCount += 1
            do {
                let (data, status) = try await fetch(url)
                if status == 200 {
                    let cached = Cached(date: Date(), feed: try RSSFeedParser.parse(data, channelId: id))
                    memory[id] = cached
                    writeDisk(id, cached)
                    return cached
                }
                Log.debug("RSS \(id): HTTP \(status)")
                // 404: el canal no existe o no tiene videos; 5xx (YouTube los da a ratos en los feeds): un reintento.
                guard status >= 500, attempt == 0 else { return nil }
            } catch {
                Log.debug("RSS \(id): \(error)")
                guard attempt == 0, !Task.isCancelled else { return nil }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private func readDisk(_ id: String) -> Cached? {
        guard usesDisk, let data = try? Data(contentsOf: DiskCache.fileURL(section: "rss", key: id)) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    private func writeDisk(_ id: String, _ cached: Cached) {
        guard usesDisk, let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: DiskCache.fileURL(section: "rss", key: id), options: .atomic)
    }

    /// Olvida la caché en memoria (las pruebas y «Recargar» con `refresh` ya la ignoran).
    public func clearMemory() { memory.removeAll() }
}

extension YouTubeService {
    /// Videos nuevos de esos canales por RSS (`getRssFeed` de SmartTube), en el idioma del catálogo.
    public func rssFeed(channelIds: [String], refresh: Bool = false) async -> RSSFeedService.Result {
        await rss.feed(channelIds: channelIds, refresh: refresh, locale: locale)
    }
}
