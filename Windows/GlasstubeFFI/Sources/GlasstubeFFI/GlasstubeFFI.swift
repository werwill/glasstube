import CDispatchPump
import Foundation
import GlasstubeCore
import YTKit

// API en C de GlasstubeFFI.dll (cabecera: include/GlasstubeFFI.h).
//
// - Lo asíncrono responde por `GTCallback(context, status, json)`: status 0 = bien y `json` es el resultado; distinto
//   de 0 = error y `json` es {"error": "…"}. La cadena solo vale durante la llamada (el cliente la copia).
// - Los callbacks corren en el actor principal, es decir, dentro de `gt_pump()`: en el hilo de la interfaz.
// - `gt_version` devuelve una cadena propia del cliente, que se suelta con `gt_free`.

public typealias GTCallback = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void

/// Callback y contexto del cliente. El contexto es opaco: solo se devuelve.
struct Reply: @unchecked Sendable {
    let callback: GTCallback
    let context: UnsafeMutableRawPointer?

    func ok<T: Encodable>(_ value: T) { send(0, value) }

    func fail(_ error: Error) { fail("\(error)") }
    func fail(_ message: String) { send(1, ["error": message]) }

    private func send<T: Encodable>(_ status: Int32, _ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data(#"{"error":"JSON"}"#.utf8)
        var bytes = [UInt8](data)
        bytes.append(0)
        bytes.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { callback(context, status, $0.baseAddress) }
        }
    }
}

// MARK: - Motor

@MainActor
final class Engine {
    static var shared: Engine?

    let session: AccountManager
    let service: YouTubeService
    let poToken: PoTokenWebViewProvider
    /// Página siguiente del Inicio y los videos ya enviados (las filas de TV repiten videos entre sí).
    var homeContinuation: Continuation?
    var homeSeen: Set<String> = []

    init(locale: CatalogLocale) throws {
        let catalog = try ClientCatalog.load()
        session = try AccountManager(catalog: catalog, locale: locale)
        poToken = PoTokenWebViewProvider(catalog: catalog)
        service = try YouTubeService(catalog: catalog, locale: locale, poTokenSource: poToken, session: session)
    }

    static func require() throws -> Engine {
        guard let shared else { throw FFIError("gt_init no se ha llamado") }
        return shared
    }
}

struct FFIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Copia una cadena C (UTF-8) antes de saltar de hilo.
func string(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
}

// MARK: - Ciclo de vida

/// Crea el motor (catálogo de clientes, sesión del Administrador de credenciales y servicio). `language` y `region`
/// son los del catálogo ("es-419", "MX"); nulos = los del sistema.
@_cdecl("gt_init")
public func gt_init(_ language: UnsafePointer<CChar>?, _ region: UnsafePointer<CChar>?, _ callback: GTCallback,
                    _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    let current = CatalogLocale.current
    let locale = CatalogLocale(language: string(language) ?? current.language, region: string(region) ?? current.region)
    Task { @MainActor in
        do {
            if Engine.shared == nil { Engine.shared = try Engine(locale: locale) }
            reply.ok(["language": locale.language, "region": locale.region, "version": version])
        } catch {
            reply.fail(error)
        }
    }
}

/// Vacía la cola principal (los trabajos del actor principal, incluidos los callbacks). Desde el hilo de la interfaz,
/// a menudo (la app lo llama con un temporizador de ~15 ms).
@_cdecl("gt_pump")
public func gt_pump() {
    gt_dispatch_drain_main_queue()
}

@_cdecl("gt_shutdown")
public func gt_shutdown() {
    Task { @MainActor in Engine.shared = nil }
}

let version = "0.1.0"

@_cdecl("gt_version")
public func gt_version() -> UnsafeMutablePointer<CChar>? {
    #if os(Windows)
    _strdup("GlasstubeFFI \(version)")
    #else
    strdup("GlasstubeFFI \(version)")
    #endif
}

@_cdecl("gt_free")
public func gt_free(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}

// MARK: - Sesión

struct SessionPayload: Encodable {
    struct AccountPayload: Encodable {
        var name: String
        var byline: String?
        var avatar: String?
        var isBrand: Bool
    }

    var signedIn: Bool
    var selected: AccountPayload?
    var accountCount: Int
}

/// Lee la sesión guardada (Administrador de credenciales). Sin sesión responde `signedIn: false`, no un error.
@_cdecl("gt_load_session")
public func gt_load_session(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        do {
            let snapshot = try await Engine.require().session.load()
            reply.ok(SessionPayload(
                signedIn: snapshot.isSignedIn,
                selected: snapshot.selected.map {
                    .init(name: $0.name, byline: $0.byline, avatar: $0.avatar.best(forWidth: 88).map { absolute($0.url) },
                          isBrand: $0.isBrand)
                },
                accountCount: snapshot.accounts.count))
        } catch {
            reply.fail(error)
        }
    }
}

// MARK: - Inicio

struct VideoCard: Encodable {
    var id: String
    var title: String
    var channel: String?
    var channelId: String?
    var thumbnail: String?
    var duration: String?
    var views: String?
    var published: String?
    var subtitle: String
    var isLive: Bool
    var shelf: String?
}

struct FeedPage: Encodable {
    var items: [VideoCard]
    var hasMore: Bool
    var notice: String?
    var signedIn: Bool
}

/// "//i.ytimg.com/…" → "https://i.ytimg.com/…".
func absolute(_ url: String) -> String { url.hasPrefix("//") ? "https:" + url : url }

extension Engine {
    /// Solo videos normales (sin Shorts, canales ni listas), sin repetir.
    func cards(_ page: BrowsePage) -> [VideoCard] {
        var cards: [VideoCard] = []
        for group in page.groups where !group.isShorts {
            for item in group.items where item.kind == .video && item.isPlayable && !item.isShort {
                guard let id = item.videoId, homeSeen.insert(id).inserted else { continue }
                let thumbnail = item.thumbnails.best(forWidth: 480) ?? item.standardThumbnails.dropFirst().first
                cards.append(VideoCard(
                    id: id, title: item.title, channel: item.author, channelId: item.channelId,
                    thumbnail: thumbnail.map { absolute($0.url) }, duration: item.durationBadge,
                    views: item.viewCountText, published: item.publishedText, subtitle: item.cardSubtitle,
                    isLive: item.isLive, shelf: group.title))
            }
        }
        return cards
    }

    func feed(_ page: BrowsePage) async -> FeedPage {
        homeContinuation = page.continuation
        return FeedPage(items: cards(page), hasMore: page.continuation != nil, notice: page.notice,
                        signedIn: session.knownSignedIn ?? false)
    }
}

/// Inicio: con sesión, las recomendaciones de la cuenta (por TV); sin ella, el Inicio anónimo.
@_cdecl("gt_home")
public func gt_home(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            _ = try? await engine.session.load()
            engine.homeSeen = []
            reply.ok(await engine.feed(try await engine.service.home()))
        } catch {
            reply.fail(error)
        }
    }
}

/// Más filas del Inicio (la continuación de la última página). Sin más, responde `items: []` y `hasMore: false`.
@_cdecl("gt_home_more")
public func gt_home_more(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            guard let continuation = engine.homeContinuation else {
                return reply.ok(FeedPage(items: [], hasMore: false, signedIn: engine.session.knownSignedIn ?? false))
            }
            reply.ok(await engine.feed(try await engine.service.continuePage(continuation)))
        } catch {
            reply.fail(error)
        }
    }
}

// MARK: - Streams

struct StreamPayload: Encodable {
    struct Track: Encodable {
        var url: String
        var itag: Int
        var codec: String
        var label: String
        var height: Int?
    }

    var videoId: String
    var title: String?
    var author: String?
    var client: String?
    /// Video y audio separados (lo normal) o, en directos, `hls` (un manifiesto con los dos).
    var video: Track?
    var audio: Track?
    var hls: String?
    var durationSeconds: Double?
    var userAgent: String
    var headers: [String: String]
}

extension StreamPayload.Track {
    init?(_ format: StreamFormat?) {
        guard let format, let url = format.url else { return nil }
        self.init(url: url, itag: format.itag, codec: format.codec.rawValue, label: format.label, height: format.height)
    }
}

/// URLs para mpv: la rotación de clientes de YTKit (firma, `n` y, si hace falta, PoToken de WebView2), hasta
/// `maxHeight` (0 = 1080).
@_cdecl("gt_resolve_stream")
public func gt_resolve_stream(_ videoId: UnsafePointer<CChar>?, _ maxHeight: Int32, _ callback: GTCallback,
                              _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let videoId = string(videoId) else { return reply.fail("falta el videoId") }
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            var options = ResolveOptions()
            options.maxHeight = maxHeight > 0 ? Int(maxHeight) : 1080
            options.codecOrder = [.vp9, .avc, .av1]
            let report = await engine.service.formatInfo(videoId: videoId, options: options)
            var headers = StreamResolver.streamHeaders
            if let chosen = report.chosen, let video = StreamPayload.Track(chosen.video),
               let audio = StreamPayload.Track(chosen.audio) {
                let duration = (chosen.video?.approxDurationMs ?? chosen.audio?.approxDurationMs).map { Double($0) / 1000 }
                headers["User-Agent"] = chosen.client.userAgent
                return reply.ok(StreamPayload(
                    videoId: videoId, title: report.title, author: report.author, client: chosen.client.id,
                    video: video, audio: audio, durationSeconds: duration, userAgent: chosen.client.userAgent,
                    headers: headers))
            }
            // Directos: el manifiesto HLS de cualquier intento que lo haya traído.
            if let attempt = report.attempts.first(where: { $0.playability == "OK" && $0.hlsManifestURL != nil }),
               let hls = attempt.hlsManifestURL {
                headers["User-Agent"] = attempt.client.userAgent
                return reply.ok(StreamPayload(
                    videoId: videoId, title: report.title, author: report.author, client: attempt.client.id, hls: hls,
                    userAgent: attempt.client.userAgent, headers: headers))
            }
            let reasons = report.attempts.map { "\($0.client.id): \($0.error ?? $0.reason ?? $0.playability ?? "?")" }
            reply.fail("ningún cliente dio streams reproducibles (\(reasons.joined(separator: "; ")))")
        } catch {
            reply.fail(error)
        }
    }
}
