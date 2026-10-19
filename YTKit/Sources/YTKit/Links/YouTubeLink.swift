import Foundation

/// Un enlace de YouTube o de Glasstube ya interpretado (fase 4): lo que se pega, se arrastra, llega por el menú
/// Servicios o abre `glasstube://`. SmartTube acepta lo mismo en su `intent-filter` (youtube.com, m.youtube.com,
/// youtu.be, `vnd.youtube:`) y lo resuelve en `IntentExtractor`.
public enum YouTubeLink: Sendable, Hashable {
    /// `start` en segundos (`t=`); `playlistId` si el enlace viene de una lista (`list=`).
    case video(id: String, start: Double? = nil, playlistId: String? = nil)
    case playlist(id: String)
    /// Id `UC…`, `@handle` o la URL completa de un canal (`/c/…`, `/user/…`): `channel(_:)` acepta las tres.
    case channel(String)
    case search(String)

    /// El esquema propio de la app.
    public static let scheme = "glasstube"

    /// Interpreta un texto: una URL sola o un texto con un enlace dentro (el primero que sirva).
    public static func parse(_ text: String) -> YouTubeLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let link = parse(url: trimmed) { return link }
        // Un texto con el enlace en medio («mira esto: https://youtu.be/…»).
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'«»()[]"))
        for word in trimmed.components(separatedBy: separators) where word.count > 8 {
            if let link = parse(url: word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))) { return link }
        }
        return nil
    }

    public static func parse(_ url: URL) -> YouTubeLink? { parse(url: url.absoluteString) }

    private static func parse(url raw: String) -> YouTubeLink? {
        var text = raw
        // `glasstube://@handle`: para URLComponents la «@» separa un usuario vacío del host.
        if text.lowercased().hasPrefix(Self.scheme + "://@") {
            let handle = text.dropFirst(Self.scheme.count + 3).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            return handle.count > 1 ? .channel(String(handle)) : nil
        }
        // `vnd.youtube:ID` y `vnd.youtube://ID` (los de Android).
        for prefix in ["vnd.youtube://", "vnd.youtube:"] where text.lowercased().hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count))
            let id = String(rest.prefix { $0 != "?" && $0 != "&" && $0 != "/" })
            return isVideoId(id) ? .video(id: id, start: nil, playlistId: nil) : nil
        }
        // Sin esquema: «youtube.com/watch?v=…», «youtu.be/…», «www.youtube.com/…».
        let lower = text.lowercased()
        if !lower.contains("://"), Self.hosts.contains(where: { lower.hasPrefix($0 + "/") || lower.hasPrefix("www." + $0 + "/") }) {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return parseWeb(components)
        case Self.scheme, "youtube":
            return parseApp(components)
        default:
            return nil
        }
    }

    static let hosts = ["youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "youtube-nocookie.com"]

    private static func isYouTubeHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return hosts.contains(host) || host == "www.youtube.com" || host == "www.youtube-nocookie.com" || host == "www.youtu.be"
    }

    /// `https://www.youtube.com/…`, `https://youtu.be/…`.
    private static func parseWeb(_ components: URLComponents) -> YouTubeLink? {
        guard let host = components.host, isYouTubeHost(host) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        let start = (value("t") ?? value("start") ?? value("time_continue")).flatMap(seconds)
        let list = value("list").flatMap { isPlaylistId($0) ? $0 : nil }

        if host.lowercased().hasSuffix("youtu.be") {
            guard let id = parts.first, isVideoId(id) else { return nil }
            return .video(id: id, start: start, playlistId: list)
        }
        guard let first = parts.first else {
            // La portada con `?v=` (enlaces viejos).
            if let id = value("v"), isVideoId(id) { return .video(id: id, start: start, playlistId: list) }
            return nil
        }
        switch first.lowercased() {
        case "watch":
            if let id = value("v"), isVideoId(id) { return .video(id: id, start: start, playlistId: list) }
            return list.map { .playlist(id: $0) }
        case "shorts", "live", "embed", "v", "e":
            guard parts.count > 1, isVideoId(parts[1]) else { return nil }
            return .video(id: parts[1], start: start, playlistId: list)
        case "playlist":
            return list.map { .playlist(id: $0) }
        case "channel":
            guard parts.count > 1, parts[1].hasPrefix("UC") else { return nil }
            return .channel(parts[1])
        case "c", "user":
            guard parts.count > 1 else { return nil }
            return .channel("https://www.youtube.com/\(first)/\(parts[1])")
        case "results", "search":
            return (value("search_query") ?? value("q")).map { .search(formText($0)) }
        case "attribution_link":
            // `attribution_link?u=/watch%3Fv%3D…`
            guard let target = value("u") else { return nil }
            return parse(url: "https://www.youtube.com" + (target.hasPrefix("/") ? target : "/" + target))
        default:
            if first.hasPrefix("@"), first.count > 1 { return .channel(first) }
            return nil
        }
    }

    /// `glasstube://watch?v=ID&t=90`, `glasstube://video/ID`, `glasstube://channel/UC…` o `/@handle`,
    /// `glasstube://@handle`, `glasstube://playlist?list=…` o `/ID`, `glasstube://search?q=…`,
    /// `glasstube://open?url=<enlace>` y `glasstube://www.youtube.com/watch?v=…` (cambiar `https` por `glasstube`).
    private static func parseApp(_ components: URLComponents) -> YouTubeLink? {
        let host = components.host ?? ""
        if isYouTubeHost(host) {
            var web = components
            web.scheme = "https"
            return parseWeb(web)
        }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        let parts = components.path.split(separator: "/").map(String.init)
        let start = (value("t") ?? value("start")).flatMap(seconds)
        let list = value("list").flatMap { isPlaylistId($0) ? $0 : nil }
        switch host.lowercased() {
        case "watch", "video", "play":
            if let id = value("v") ?? parts.first, isVideoId(id) { return .video(id: id, start: start, playlistId: list) }
            return list.map { .playlist(id: $0) }
        case "channel":
            guard let id = value("id") ?? parts.first else { return nil }
            return id.hasPrefix("UC") || id.hasPrefix("@") ? .channel(id) : .channel("@" + id)
        case "playlist", "list":
            if let id = list ?? parts.first, isPlaylistId(id) { return .playlist(id: id) }
            return nil
        case "search", "results":
            return (value("q") ?? value("search_query") ?? parts.first).map { .search(formText($0)) }
        case "open":
            return value("url").flatMap { parse(url: $0) }
        default:
            if host.hasPrefix("@"), host.count > 1 { return .channel(host) }
            if isVideoId(host) { return .video(id: host, start: start, playlistId: list) }
            return nil
        }
    }

    /// En las búsquedas de YouTube el espacio llega como «+» (formulario).
    private static func formText(_ text: String) -> String { text.replacingOccurrences(of: "+", with: " ") }

    /// `t=90`, `t=90s`, `t=1m30s`, `t=1h2m3s`, `t=1:30`.
    static func seconds(_ text: String) -> Double? {
        let text = text.lowercased()
        if let value = Double(text) { return value }
        if text.contains(":") {
            let numbers = text.split(separator: ":").compactMap { Double($0) }
            guard !numbers.isEmpty else { return nil }
            return numbers.reduce(0) { $0 * 60 + $1 }
        }
        var total = 0.0
        var number = ""
        var matched = false
        for character in text {
            if character.isNumber || character == "." {
                number.append(character)
            } else if let value = Double(number), let unit = ["h": 3600.0, "m": 60, "s": 1][String(character)] {
                total += value * unit
                number = ""
                matched = true
            } else {
                return nil
            }
        }
        if let value = Double(number) { total += value; matched = true }
        return matched ? total : nil
    }

    static func isVideoId(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func isPlaylistId(_ id: String) -> Bool {
        id.count >= 2 && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // MARK: - Direcciones

    /// El enlace público de YouTube.
    public var webURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        switch self {
        case .video(let id, let start, let list):
            components.path = "/watch"
            components.queryItems = [URLQueryItem(name: "v", value: id)]
                + (list.map { [URLQueryItem(name: "list", value: $0)] } ?? [])
                + (start.map { [URLQueryItem(name: "t", value: "\(Int($0))s")] } ?? [])
        case .playlist(let id):
            components.path = "/playlist"
            components.queryItems = [URLQueryItem(name: "list", value: id)]
        case .channel(let channel):
            if channel.hasPrefix("http"), let url = URL(string: channel) { return url }
            components.path = channel.hasPrefix("@") ? "/\(channel)" : "/channel/\(channel)"
        case .search(let query):
            components.path = "/results"
            components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        }
        return components.url!
    }

    /// El mismo destino con el esquema `glasstube://`.
    public var appURL: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .video(let id, let start, let list):
            components.host = "watch"
            components.queryItems = [URLQueryItem(name: "v", value: id)]
                + (list.map { [URLQueryItem(name: "list", value: $0)] } ?? [])
                + (start.map { [URLQueryItem(name: "t", value: String(Int($0)))] } ?? [])
        case .playlist(let id):
            components.host = "playlist"
            components.queryItems = [URLQueryItem(name: "list", value: id)]
        case .channel(let channel):
            if channel.hasPrefix("http") {
                components.host = "open"
                components.queryItems = [URLQueryItem(name: "url", value: channel)]
            } else {
                components.host = "channel"
                components.path = "/\(channel)"
            }
        case .search(let query):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        return components.url!
    }
}
