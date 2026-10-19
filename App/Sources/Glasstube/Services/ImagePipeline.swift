import AppKit
import SwiftUI
import YTKit

/// Descarga y caché en memoria de miniaturas, avatares y hojas de storyboard.
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration)
    }()

    init() {
        cache.countLimit = 600
    }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func image(for url: URL) async -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        if let task = inFlight[url] { return await task.value }
        let session = session
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// La primera URL que responda (p. ej. `maxresdefault`, que no existe en todos los videos, y luego otras).
    func firstImage(from urls: [URL]) async -> NSImage? {
        for url in urls {
            if let image = await image(for: url) { return image }
        }
        return nil
    }
}

/// Imagen remota opaca que llena su marco. Mientras carga muestra un relleno neutro.
struct RemoteImage: View {
    let urls: [URL]
    var contentMode: ContentMode = .fill

    @ViewState private var image: NSImage?

    init(urls: [URL], contentMode: ContentMode = .fill) {
        self.urls = urls
        self.contentMode = contentMode
    }

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.init(urls: url.map { [$0] } ?? [], contentMode: contentMode)
    }

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: urls) {
                guard !urls.isEmpty else { return }
                let loaded = await ImagePipeline.shared.firstImage(from: urls)
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
    }
}

typealias YTThumbnail = YTKit.Thumbnail

/// URLs de imagen de un `MediaItem` según el uso.
enum MediaItemImages {
    static func urls(_ thumbnails: [YTThumbnail], width: Int) -> [URL] {
        let best = thumbnails.best(forWidth: width)
        let rest = thumbnails.sorted { ($0.width ?? 0) > ($1.width ?? 0) }
        return ([best].compactMap { $0 } + rest).compactMap { URL(string: $0.url) }.uniqued()
    }

    /// Tarjeta: la miniatura de YouTube que alcance el ancho y, si falla, las estándar 16:9 de i.ytimg.com.
    static func card(_ item: MediaItem, width: Int = 480) -> [URL] {
        var urls = urls(item.thumbnails, width: width)
        if let videoId = item.videoId {
            urls += ["hq720", "mqdefault"].compactMap { URL(string: "https://i.ytimg.com/vi/\(videoId)/\($0).jpg") }
        }
        return urls.uniqued()
    }

    /// Banner: la más grande (maxresdefault puede no existir).
    static func banner(_ item: MediaItem) -> [URL] {
        var urls: [URL] = []
        if let videoId = item.videoId {
            urls += ["maxresdefault", "hq720"].compactMap { URL(string: "https://i.ytimg.com/vi/\(videoId)/\($0).jpg") }
        }
        return (urls + card(item, width: 1280)).uniqued()
    }

    static func avatar(_ thumbnails: [YTThumbnail]) -> [URL] {
        urls(thumbnails, width: 88).map { url in
            // Los avatares de yt3.ggpht.com vienen a 68–88 px; se pide uno más grande para pantallas Retina.
            URL(string: url.absoluteString.replacingOccurrences(of: "=s88-", with: "=s176-")
                .replacingOccurrences(of: "=s68-", with: "=s176-")) ?? url
        }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
