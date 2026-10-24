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
    Log.sink = { FileLog.shared.write("ytkit", $0) }
    log("gt_init \(version) · \(locale.language)-\(locale.region)")
    Task { @MainActor in
        do {
            if Engine.shared == nil { Engine.shared = try Engine(locale: locale) }
            reply.ok(["language": locale.language, "region": locale.region, "version": version])
        } catch {
            log("gt_init falló: \(error)")
            reply.fail(error)
        }
    }
}

/// Una línea en el registro de la app, de parte de `source` ("app", "mpv"…). Se puede llamar desde cualquier hilo.
@_cdecl("gt_log")
public func gt_log(_ source: UnsafePointer<CChar>?, _ message: UnsafePointer<CChar>?) {
    FileLog.shared.write(string(source) ?? "?", string(message) ?? "")
}

/// Carpeta del registro (%LOCALAPPDATA%\Glasstube\logs). Se libera con gt_free.
@_cdecl("gt_log_directory")
public func gt_log_directory() -> UnsafeMutablePointer<CChar>? {
    #if os(Windows)
    _strdup(FileLog.shared.directory.path)
    #else
    strdup(FileLog.shared.directory.path)
    #endif
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

let version = "0.2.0"

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

struct VideoCard: Codable {
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
    // Desde la 0.2 (Cards.swift). Todos opcionales: los clientes viejos los ignoran.
    /// Miniatura grande (hasta 1280 px) para la portada.
    var thumbnailLarge: String?
    /// Foto del canal, cuando se sabe (Suscripciones la saca de las pestañas de canal).
    var avatar: String?
    var durationSeconds: Int?
    /// Fecha aproximada de publicación (segundos Unix), sacada del texto relativo ("hace 3 horas").
    var publishedAt: Double?
    /// Posición guardada en la biblioteca local (segundos) y fracción vista (0–1).
    var position: Double?
    var progress: Double?
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
                cards.append(VideoCard(item, shelf: group.title))
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
            let feed = await engine.feed(try await engine.service.home())
            log("Inicio: \(feed.items.count) videos, más: \(feed.hasMore), sesión: \(feed.signedIn)")
            reply.ok(feed)
        } catch {
            log("Inicio falló: \(error)")
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
            log("Inicio (más) falló: \(error)")
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

/// Directos: el manifiesto HLS del cliente VISIONOS (sin desafíos), como `YouTubeLive.hlsManifest` en PlaybackKit.
@MainActor
func liveManifest(videoId: String, catalog: ClientCatalog) async throws -> (ClientProfile, String, String?) {
    guard let client = catalog.profile("VISIONOS") else { throw FFIError("clients.json no trae VISIONOS") }
    var request = Innertube.PlayerRequest(videoId: videoId, client: client)
    request.visitorData = try? await PlayerScriptStore.shared.appInfo().visitorData
    let reply = try await Innertube().player(request)
    guard reply.status == 200 else { throw FFIError("player HTTP \(reply.status)") }
    let response = try JSONDecoder().decode(PlayerResponse.self, from: reply.data)
    guard response.playabilityStatus?.status == "OK", let hls = response.streamingData?.hlsManifestUrl else {
        throw FFIError("VISIONOS: \(response.playabilityStatus?.status ?? "?") \(response.playabilityStatus?.reason ?? "sin HLS")")
    }
    return (client, hls, response.videoDetails?.title)
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
            log("resolver \(videoId) (hasta \(options.maxHeight ?? 0)p)…")
            let start = Date()
            let report = await engine.service.formatInfo(videoId: videoId, options: options)
            // Cada intento ya lo anota YTKit (`Log.info`), con su HTTP, playability y comprobación de URLs.
            let elapsed = String(format: "%.1f s", Date().timeIntervalSince(start))
            var headers = StreamResolver.streamHeaders
            // Un directo en curso va por HLS: sus formatos adaptativos son URLs de un solo segmento (`sq`) y mpv se
            // detiene a los pocos segundos.
            // TV_DOWNGRADED no marca `isLive` ni trae HLS; se nota en que sus formatos no tienen `contentLength`.
            let isLive = report.attempts.contains(where: \.isLive)
                || (report.chosen.map { $0.video?.contentLength == nil && $0.audio?.contentLength == nil } ?? false)
            if isLive {
                if let attempt = report.attempts.first(where: { $0.playability == "OK" && $0.hlsManifestURL != nil }),
                   let hls = attempt.hlsManifestURL {
                    headers["User-Agent"] = attempt.client.userAgent
                    log("resuelto \(videoId) en \(elapsed): \(attempt.client.id), directo por HLS")
                    return reply.ok(StreamPayload(
                        videoId: videoId, title: report.title, author: report.author, client: attempt.client.id, hls: hls,
                        userAgent: attempt.client.userAgent, headers: headers))
                }
                do {
                    let (client, hls, title) = try await liveManifest(videoId: videoId, catalog: engine.service.catalog)
                    headers["User-Agent"] = client.userAgent
                    log("resuelto \(videoId): directo por HLS de \(client.id)")
                    return reply.ok(StreamPayload(
                        videoId: videoId, title: title ?? report.title, author: report.author, client: client.id,
                        hls: hls, userAgent: client.userAgent, headers: headers))
                } catch {
                    log("directo \(videoId) sin HLS (\(error)); se prueba con los formatos adaptativos")
                }
            }
            if let chosen = report.chosen, let video = StreamPayload.Track(chosen.video),
               let audio = StreamPayload.Track(chosen.audio) {
                let duration = (chosen.video?.approxDurationMs ?? chosen.audio?.approxDurationMs).map { Double($0) / 1000 }
                headers["User-Agent"] = chosen.client.userAgent
                log("resuelto \(videoId) en \(elapsed): \(chosen.client.id), video \(video.itag) \(video.codec) \(video.label), audio \(audio.itag) \(audio.codec)")
                return reply.ok(StreamPayload(
                    videoId: videoId, title: report.title, author: report.author, client: chosen.client.id,
                    video: video, audio: audio, durationSeconds: duration, userAgent: chosen.client.userAgent,
                    headers: headers))
            }
            // Directos: el manifiesto HLS de cualquier intento que lo haya traído.
            if let attempt = report.attempts.first(where: { $0.playability == "OK" && $0.hlsManifestURL != nil }),
               let hls = attempt.hlsManifestURL {
                headers["User-Agent"] = attempt.client.userAgent
                log("resuelto \(videoId) en \(elapsed): \(attempt.client.id), HLS")
                return reply.ok(StreamPayload(
                    videoId: videoId, title: report.title, author: report.author, client: attempt.client.id, hls: hls,
                    userAgent: attempt.client.userAgent, headers: headers))
            }
            let reasons = report.attempts.map { "\($0.client.id): \($0.error ?? $0.reason ?? $0.playability ?? "?")" }
            log("sin streams para \(videoId) en \(elapsed)")
            // La razón que da YouTube (edad, región, privado…) va primero; los detalles, después.
            let reason = report.attempts.lazy.compactMap(\.reason).first
            reply.fail((reason.map { "YouTube: \($0)" } ?? "Ningún cliente de YouTube dio streams reproducibles.")
                       + "\n\nDetalles: " + reasons.joined(separator: "; "))
        } catch {
            log("resolver \(videoId) falló: \(error)")
            reply.fail(error)
        }
    }
}
