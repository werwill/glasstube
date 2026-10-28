import Foundation

/// Tokens de `WebPoTokenProvider.getPoToken`: visitorData usado al mintear, token de contenido (videoId)
/// para el player y para el parámetro `pot` de las URLs, y token de sesión (visitorData).
public struct PoTokenResult: Sendable {
    public let videoId: String
    public let visitorData: String
    public let playerPoToken: String
    public let streamingPoToken: String
    public let expiresAt: Date
    public let elapsed: TimeInterval
}

public protocol PoTokenSource: Sendable {
    func poToken(videoId: String) async throws -> PoTokenResult
}

/// Comprobación real de una URL de googlevideo: GET con Range al inicio (firma del contenedor) y a la mitad.
public struct URLCheck: Sendable {
    public var startStatus: Int?
    public var midStatus: Int?
    public var magic: String?
    public var speedKBps: Double?
    public var error: String?
    public var ok: Bool {
        [200, 206].contains(startStatus ?? 0) && [200, 206].contains(midStatus ?? 0) && magic != nil
    }
    public var summary: String {
        if let error { return "error: \(error)" }
        var parts = ["inicio \(startStatus.map(String.init) ?? "-")", "mitad \(midStatus.map(String.init) ?? "-")", magic ?? "sin cabecera reconocible"]
        if let speedKBps { parts.append(String(format: "%.0f KB/s", speedKBps)) }
        return parts.joined(separator: ", ")
    }
}

public struct ClientAttempt: Sendable {
    public let client: ClientProfile
    public var usedPoToken = false
    /// El player se pidió con la cuenta (`ResolveOptions.accountHeaders`).
    public var signedIn = false
    public var httpStatus: Int?
    public var elapsed: TimeInterval = 0
    public var playability: String?
    public var reason: String?
    public var title: String?
    public var author: String?
    public var isLive = false
    public var adaptiveCount = 0
    public var withURL = 0
    public var withCipher = 0
    public var withoutURL = 0
    public var sabrURL = false
    public var hlsURL = false
    /// El manifiesto HLS (directos; vía AVPlayer) respondió 200 con `#EXTM3U`.
    public var hlsOK: Bool?
    public var hlsManifestURL: String?
    /// `streamingData.expiresInSeconds`: vida de las URLs firmadas.
    public var expiresInSeconds: Int?
    public var playerURL: String?
    public var playerVariant: ClientProfile.PlayerVariant?
    public var signatureTimestamp: Int?
    public var solve: SolveResult?
    public var solverError: String?
    public var formats: [StreamFormat] = []
    public var video: StreamFormat?
    public var audio: StreamFormat?
    public var videoCheck: URLCheck?
    public var audioCheck: URLCheck?
    /// Formato combinado (itag 18, 360p) cuando trae URL: sirve para probar si un PoToken desbloquea la descarga.
    public var muxed: StreamFormat?
    public var muxedCheck: URLCheck?
    public var error: String?

    /// Solo SABR: hay `serverAbrStreamingUrl` y ningún formato adaptativo trae URL ni firma cifrada.
    public var sabrOnly: Bool { sabrURL && withURL == 0 && withCipher == 0 }
    public var nPresent: Int { formats.filter(\.nPresent).count }
    public var nSolved: Int { formats.filter(\.nSolved).count }
    public var sigNeeded: Int { formats.filter(\.hadCipher).count }
    public var sigSolved: Int { formats.filter(\.signatureSolved).count }

    /// Reproducible = estado OK, al menos un video y un audio con URL y, si se validó, ambas URLs responden.
    public var playable: Bool {
        guard playability == "OK", video != nil, audio != nil else { return false }
        if let videoCheck, !videoCheck.ok { return false }
        if let audioCheck, !audioCheck.ok { return false }
        return true
    }

    init(client: ClientProfile) { self.client = client }
}

public struct ResolveOptions: Sendable {
    public var startClient: String?
    public var onlyClient: String?
    public var allowPoToken = true
    public var validate = true
    public var measureSpeed = false
    public var maxHeight: Int?
    public var codecOrder: [Codec] = [.vp9, .avc, .av1]
    public var allowHDR = false
    /// Experimento: deja el parámetro `n` sin transformar para medir el estrangulamiento.
    public var rawN = false
    /// Qué token va en el parámetro `pot` de las URLs: el de contenido (videoId, como SmartTube) o el de sesión.
    public var urlPoTokenIsSession = false
    /// Cabeceras de la cuenta (`AccountManager.authorizationHeaders`), o vacías sin sesión. Si ningún cliente anónimo da
    /// el video (restricción de edad, «confirma que no eres un bot»), se piden y se prueba otra vez con ellas en los
    /// clientes de TV, que son los de la sesión. Nil = solo anónimo.
    public var accountHeaders: (@Sendable () async -> [String: String])?
    public init() {}
}

public struct ResolveReport: Sendable {
    public var attempts: [ClientAttempt] = []
    public var chosen: ClientAttempt? { attempts.last { $0.playable } }
    /// Algunos clientes (TVHTML5 5.x) no traen videoDetails.title; se toma de cualquier intento.
    public var title: String? { chosen?.title ?? attempts.lazy.compactMap(\.title).first }
    public var author: String? { chosen?.author ?? attempts.lazy.compactMap(\.author).first }
}

/// Máquina de fallback de `VideoInfoService.firstInfoWith` + `VideoInfoServiceBase.decipherFormats`.
public final class StreamResolver: @unchecked Sendable {
    public static let streamHeaders = ["Accept": "*/*", "Origin": "https://www.youtube.com", "Referer": "https://www.youtube.com/"]

    public let catalog: ClientCatalog
    let innertube = Innertube()
    let scripts = PlayerScriptStore.shared
    let solver = ChallengeSolver.shared
    let poTokenSource: PoTokenSource?

    public init(catalog: ClientCatalog, poTokenSource: PoTokenSource?) {
        self.catalog = catalog
        self.poTokenSource = poTokenSource
    }

    /// Primera pasada: rotación completa sin PoToken. Segunda (solo si nada funcionó): clientes web con PoToken de WKWebView.
    public func resolve(videoId: String, options: ResolveOptions) async -> ResolveReport {
        var report = ResolveReport()
        let clients: [ClientProfile]
        if let only = options.onlyClient, let profile = catalog.profile(only) {
            clients = [profile]
        } else {
            clients = catalog.rotation(startingAt: options.startClient ?? catalog.defaultStart)
        }

        for client in clients {
            let attempt = await self.attempt(videoId: videoId, client: client, poToken: nil, options: options)
            report.attempts.append(attempt)
            Log.info(Self.oneLine(attempt))
            if attempt.playable { return report }
        }

        // Con la cuenta: la restricción de edad solo se levanta con sesión, y la sesión es de la app de TV.
        let tvClients = clients.filter { $0.id.hasPrefix("TV") }
        if let accountHeaders = options.accountHeaders, !tvClients.isEmpty,
           report.attempts.contains(where: { $0.playability != nil && $0.playability != "OK" }),
           case let headers = await accountHeaders(), !headers.isEmpty {
            Log.info("Ningún cliente anónimo dio el video; probando los de TV con la cuenta…")
            for client in tvClients {
                var attempt = await self.attempt(videoId: videoId, client: client, poToken: nil, options: options,
                                                 headers: headers)
                attempt.signedIn = true
                report.attempts.append(attempt)
                Log.info(Self.oneLine(attempt))
                if attempt.playable { return report }
            }
        }

        guard options.allowPoToken, let poTokenSource else { return report }
        let webClients = clients.filter { $0.poToken == .web }
        guard !webClients.isEmpty else { return report }
        Log.info("Ningún cliente sin PoToken alcanzó; generando PoToken con WKWebView…")
        let pot: PoTokenResult
        do {
            pot = try await poTokenSource.poToken(videoId: videoId)
        } catch {
            Log.info("PoToken falló: \(error)")
            return report
        }
        for client in webClients {
            let attempt = await self.attempt(videoId: videoId, client: client, poToken: pot, options: options)
            report.attempts.append(attempt)
            Log.info(Self.oneLine(attempt))
            if attempt.playable { return report }
        }
        return report
    }

    public static func oneLine(_ a: ClientAttempt) -> String {
        let pot = (a.usedPoToken ? "+pot" : "") + (a.signedIn ? "+cuenta" : "")
        if let error = a.error { return "  \(a.client.id)\(pot): error — \(error)" }
        var s = "  \(a.client.id)\(pot): \(a.playability ?? "?")"
        if let reason = a.reason { s += " (\(reason))" }
        s += " · formatos \(a.adaptiveCount) [url \(a.withURL), cifrados \(a.withCipher), sin url \(a.withoutURL)]"
        if a.sabrURL { s += " · SABR" + (a.sabrOnly ? " (solo SABR)" : "") }
        if a.nPresent > 0 { s += " · n \(a.nSolved)/\(a.nPresent)" }
        if a.sigNeeded > 0 { s += " · firma \(a.sigSolved)/\(a.sigNeeded)" }
        if let v = a.videoCheck { s += " · video \(v.ok ? "OK" : "FALLA") (\(v.summary))" }
        if let au = a.audioCheck { s += " · audio \(au.ok ? "OK" : "FALLA") (\(au.summary))" }
        if let m = a.muxedCheck { s += " · itag \(a.muxed?.itag ?? 0) combinado \(m.ok ? "OK" : "FALLA") (\(m.summary))" }
        if a.playable { s += " → reproducible" }
        return s
    }

    // MARK: - Un cliente

    public func attempt(videoId: String, client: ClientProfile, poToken: PoTokenResult?, options: ResolveOptions,
                        headers: [String: String] = [:]) async -> ClientAttempt {
        var attempt = ClientAttempt(client: client)
        attempt.usedPoToken = poToken != nil

        // 1. Player JS y signatureTimestamp (necesarios para pedir formatos con firma cifrada)
        do {
            let (url, variant) = try await scripts.playerURL(for: client)
            attempt.playerURL = url
            attempt.playerVariant = variant
            attempt.signatureTimestamp = try await scripts.signatureTimestamp(for: url)
        } catch {
            attempt.solverError = "player JS: \(error)"
        }

        // 2. Petición al player
        var request = Innertube.PlayerRequest(videoId: videoId, client: client)
        request.signatureTimestamp = attempt.signatureTimestamp
        if let poToken {
            request.visitorData = poToken.visitorData
        } else {
            request.visitorData = try? await scripts.appInfo().visitorData
        }
        request.poToken = poToken?.playerPoToken
        request.extraHeaders = headers
        let response: PlayerResponse
        do {
            let reply = try await innertube.player(request)
            attempt.httpStatus = reply.status
            attempt.elapsed = reply.elapsed
            guard reply.status == 200 else {
                attempt.error = "HTTP \(reply.status): \(String(decoding: reply.data.prefix(200), as: UTF8.self))"
                return attempt
            }
            response = try JSONDecoder().decode(PlayerResponse.self, from: reply.data)
        } catch {
            attempt.error = "\(error)"
            return attempt
        }

        attempt.playability = response.playabilityStatus?.status
        attempt.reason = response.playabilityStatus?.reason
        attempt.title = response.videoDetails?.title
        attempt.author = response.videoDetails?.author
        attempt.isLive = response.videoDetails?.isLive ?? false
        attempt.sabrURL = response.streamingData?.serverAbrStreamingUrl != nil
        attempt.hlsURL = response.streamingData?.hlsManifestUrl != nil
        attempt.hlsManifestURL = response.streamingData?.hlsManifestUrl
        attempt.expiresInSeconds = response.streamingData?.expiresInSeconds.flatMap(Int.init)
        let adaptive = response.streamingData?.adaptiveFormats ?? []
        attempt.adaptiveCount = adaptive.count
        attempt.withURL = adaptive.filter { $0.url != nil }.count
        attempt.withCipher = adaptive.filter { $0.url == nil && ($0.signatureCipher ?? $0.cipher) != nil }.count
        attempt.withoutURL = adaptive.count - attempt.withURL - attempt.withCipher

        // 3. Firma y n (bulkSigExtract) sobre los formatos que traen URL o cifrado
        var formats: [StreamFormat] = []
        var sParams: [Int: (s: String, sp: String)] = [:]
        for (raw, kind) in response.rawFormats() {
            var format = StreamFormat(raw: raw, kind: kind)
            if format.url == nil, let cipher = raw.signatureCipher ?? raw.cipher,
               let components = URLComponents(string: "?" + cipher) {
                format.url = components.value("url")
                if let s = components.value("s") { sParams[formats.count] = (s, components.value("sp") ?? "signature") }
            }
            if let url = format.url, URLComponents(string: url)?.value("n") != nil { format.nPresent = true }
            formats.append(format)
        }

        let nValues = formats.compactMap { $0.url.flatMap { URLComponents(string: $0)?.value("n") } }
        let sValues = sParams.values.map(\.s)
        if (!nValues.isEmpty || !sValues.isEmpty), let playerURL = attempt.playerURL {
            do {
                let scripts = self.scripts
                let codeLoader: @Sendable () async throws -> String = { try await scripts.code(for: playerURL) }
                attempt.solve = attempt.playerVariant == .tcl
                    ? try await solver.solveTCL(playerURL: playerURL, playerCode: codeLoader, n: nValues)
                    : try await solver.solve(playerURL: playerURL, playerCode: codeLoader, n: nValues, sig: sValues)
            } catch {
                attempt.solverError = "\(error)"
            }
        }

        let solved = attempt.solve ?? SolveResult()
        for index in formats.indices {
            guard let url = formats[index].url, var components = URLComponents(string: url) else { continue }
            if let (s, sp) = sParams[index] {
                if let signature = solved.sig[s] {
                    components.set(sp, signature)
                    formats[index].signatureSolved = true
                } else {
                    formats[index].url = nil // sin firma la URL no sirve
                    continue
                }
            }
            if !options.rawN, let n = components.value("n"), let newN = solved.n[n], newN != n {
                components.set("n", newN)
                formats[index].nSolved = true
            }
            if let poToken {
                components.set("pot", options.urlPoTokenIsSession ? poToken.streamingPoToken : poToken.playerPoToken)
            }
            formats[index].url = components.url?.absoluteString
        }
        attempt.formats = formats

        // 4. Selección y validación de la mejor pista de video y de audio
        attempt.video = TrackSelector.bestVideo(formats, maxHeight: options.maxHeight, codecOrder: options.codecOrder, allowHDR: options.allowHDR)
            ?? TrackSelector.bestVideo(formats, maxHeight: options.maxHeight, codecOrder: Codec.allCases, allowHDR: true)
        attempt.audio = TrackSelector.bestAudio(formats)
        attempt.muxed = formats.filter { $0.kind == .muxed && $0.url != nil }.max { ($0.height ?? 0) < ($1.height ?? 0) }
        if options.validate, attempt.playability == "OK" {
            let video = attempt.video, audio = attempt.audio, muxed = attempt.muxed
            async let v = Self.checkIfPresent(video, userAgent: client.userAgent, speed: options.measureSpeed)
            async let a = Self.checkIfPresent(audio, userAgent: client.userAgent, speed: false)
            async let m = Self.checkIfPresent(muxed, userAgent: client.userAgent, speed: false)
            let (videoCheck, audioCheck, muxedCheck) = await (v, a, m)
            attempt.videoCheck = videoCheck
            attempt.audioCheck = audioCheck
            attempt.muxedCheck = muxedCheck
            if let hls = attempt.hlsManifestURL, let url = URL(string: hls) {
                let manifest = try? await HTTP.shared.string(url, headers: ["User-Agent": client.userAgent])
                attempt.hlsOK = manifest?.hasPrefix("#EXTM3U") ?? false
            }
        }
        return attempt
    }

    // MARK: - Validación de URLs

    static func checkIfPresent(_ format: StreamFormat?, userAgent: String, speed: Bool) async -> URLCheck? {
        guard let format else { return nil }
        return await check(format, userAgent: userAgent, speed: speed)
    }

    public static func check(_ format: StreamFormat, userAgent: String, speed: Bool) async -> URLCheck {
        var check = URLCheck()
        guard let string = format.url, let url = URL(string: string) else {
            check.error = "sin URL"
            return check
        }
        var headers = streamHeaders
        headers["User-Agent"] = userAgent
        do {
            headers["Range"] = "bytes=0-65535"
            let (head, response) = try await HTTP.shared.request(url, headers: headers, timeout: 20)
            check.startStatus = response.statusCode
            check.magic = containerMagic(head)

            let length = format.contentLength ?? 0
            let mid = length > 200_000 ? length / 2 : 0
            let span: Int64 = speed ? 4 * 1024 * 1024 : 65_535
            headers["Range"] = "bytes=\(mid)-\(mid + span)"
            let start = Date()
            let (body, midResponse) = try await HTTP.shared.request(url, headers: headers, timeout: 60)
            check.midStatus = midResponse.statusCode
            if speed, midResponse.statusCode == 206 {
                check.speedKBps = Double(body.count) / 1024 / max(Date().timeIntervalSince(start), 0.001)
            }
        } catch {
            check.error = "\(error.localizedDescription)"
        }
        return check
    }

    static func containerMagic(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] { return "MP4 (ftyp)" }
        if bytes.count >= 4, bytes[0...3] == [0x1A, 0x45, 0xDF, 0xA3] { return "WebM (EBML)" }
        return nil
    }
}
