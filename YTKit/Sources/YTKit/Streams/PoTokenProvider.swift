import AppKit
import Foundation
import WebKit

public struct PoTokenError: Error, CustomStringConvertible {
    public let description: String
    init(_ message: String) { description = message }
}

/// Port de `PoTokenWebView4.kt` (BotGuard en un WebView sin red) a WKWebView.
///
/// - El WKWebView vive en una ventana sin bordes fuera de pantalla (no suelto) para que WebKit no lo trate
///   como vista huérfana, y la generación corre dentro de `ProcessInfo.beginActivity` para que App Nap no
///   congele sus temporizadores (crítica, punto 2).
/// - La página es `po_token2.html` con baseURL https://www.youtube.com; las cargas de red de la página
///   se bloquean con una regla de contenido, como `blockNetworkLoads = true` en Android. El intérprete de
///   BotGuard lo descarga Swift y se ejecuta con `new Function(...)` dentro de la página.
/// - En lugar de `@JavascriptInterface`, se usa `callAsyncJavaScript`, que espera las promesas de la página.
@MainActor
public final class PoTokenWebViewProvider: NSObject, PoTokenSource, WKNavigationDelegate {
    // Constantes de PoTokenWebView4.kt
    /// Clave pública del servicio antibots de Google (BotGuard, `jnn-pa.googleapis.com`) que usa la web de YouTube; la
    /// usan también SmartTube, LibreTube y BgUtils. No es una credencial de este proyecto ni se puede rotar: es de
    /// Google. El escaneo de secretos de GitHub la marca por la forma `AIza…`.
    static let googleAPIKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    static let requestKey = "O43z0dpjhgX20SCx4KAo"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36(KHTML, like Gecko)"

    public struct Diagnostics: Sendable {
        public var challengeSource = ""
        public var hasYtcfg = false
        public var interpreterBytes = 0
        public var botguardSeconds: TimeInterval = 0
        public var integrityTTL: Int = 0
        public var steps: [String] = []
    }

    public private(set) var diagnostics = Diagnostics()
    private let catalog: ClientCatalog
    private var window: NSWindow?
    private var webView: WKWebView?
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var activity: NSObjectProtocol?
    private var minterReady = false
    private var expiresAt = Date.distantPast
    private var visitorData: String?
    private var streamingPoToken: String?
    private var consoleMessages: [String] = []

    public init(catalog: ClientCatalog) {
        self.catalog = catalog
    }

    nonisolated public func poToken(videoId: String) async throws -> PoTokenResult {
        try await mint(videoId: videoId)
    }

    /// `WebPoTokenProvider.getPoToken`: crea el generador si hace falta, mintea primero el token de sesión
    /// (visitorData, una sola vez) y luego el de contenido (videoId).
    public func mint(videoId: String) async throws -> PoTokenResult {
        let start = Date()
        if !minterReady || Date() > expiresAt || visitorData == nil {
            try await Self.retryingOnce({ self.step("reintento del minter web: \($0)") }) {
                try await self.initialize()
                guard let visitorData = self.visitorData else { throw PoTokenError("sin visitorData") }
                self.streamingPoToken = try await self.obtainPoToken(identifier: visitorData)
            }
        }
        let playerPot = try await obtainPoToken(identifier: videoId)
        return PoTokenResult(videoId: videoId, visitorData: visitorData!, playerPoToken: playerPot,
                             streamingPoToken: streamingPoToken!, expiresAt: expiresAt, elapsed: Date().timeIntervalSince(start))
    }

    /// `TvPoTokenProvider` + `TvPoTokenWebView4`: el cliente TV (TVHTML5 7.x) tiene su propio request key
    /// (`challengeRequestKey` de tv_config) y desafío (/att/get con el cliente TV). El token es de sesión, se mintea
    /// sobre `LIVING_ROOM_PO_TOKEN_ID` de /tv y se usa igual en el player y en el streaming.
    public func mintTV(tv: ClientProfile) async throws -> (result: PoTokenResult, livingRoomPoTokenId: String) {
        try await Self.retryingOnce({ self.step("reintento del minter de TV: \($0)") }) { try await self.mintTVOnce(tv: tv) }
    }

    /// BotGuard a veces termina sin `webPoSignalOutput` ("webPoSignalOutput is empty", visto en la app el 16-oct-2026,
    /// 1 de 3 arranques) y sin PoToken no arranca el video. Un segundo intento, con página y desafío nuevos, basta.
    static func retryingOnce<T>(_ log: (Error) -> Void, _ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log(error)
            return try await work()
        }
    }

    private func mintTVOnce(tv: ClientProfile) async throws -> (result: PoTokenResult, livingRoomPoTokenId: String) {
        let start = Date()
        close()
        diagnostics = Diagnostics()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Glasstube: BotGuard / PoToken TV")

        let config = try await HTTP.shared.string(
            URL(string: "https://www.youtube.com/tv_config?action_get_config=true&client=lb4&theme=cl")!,
            headers: ["User-Agent": tv.userAgent])
        guard let requestKey = config.firstMatch(#""challengeRequestKey":"(.*?)""#) else {
            throw PoTokenError("tv_config sin challengeRequestKey")
        }
        step("tv_config: request key \(requestKey)")

        // El id y el visitorData deben venir de la misma página /tv (la que usa también el player).
        let appInfo = try await PlayerScriptStore.shared.appInfo()
        guard let livingRoomId = appInfo.livingRoomPoTokenId, let tvVisitor = appInfo.visitorData else {
            throw PoTokenError("/tv sin LIVING_ROOM_PO_TOKEN_ID o visitorData")
        }

        // FORCE_ATT_CHALLENGE = true en SmartTube: el programa sale de /att/get con el cliente TV.
        let body = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": tv.clientName, "clientVersion": tv.clientVersion]],
            "engagementType": "ENGAGEMENT_TYPE_UNBOUND",
        ])
        let text = try await botguardRequest("https://www.youtube.com/youtubei/v1/att/get?prettyPrint=false", body: body,
                                             extraHeaders: ["Content-Type": "application/json"])
        diagnostics.challengeSource = "/att/get (TV)"
        try await startMinter(challenge: try await descrambledChallenge(text), ytcfg: nil, requestKey: requestKey)

        let pot = try await obtainPoToken(identifier: livingRoomId)
        visitorData = nil // el minter quedó con la config de TV: el próximo mint() web reinicia
        minterReady = false
        let result = PoTokenResult(videoId: "", visitorData: tvVisitor, playerPoToken: pot, streamingPoToken: pot,
                                   expiresAt: expiresAt, elapsed: Date().timeIntervalSince(start))
        return (result, livingRoomId)
    }

    public func close() {
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        window?.close()
        webView = nil
        window = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        minterReady = false
    }

    // MARK: - Inicialización (loadHtmlAndObtainBotguard → downloadAndRunBotguard → onRunBotguardResult)

    private func initialize() async throws {
        close()
        diagnostics = Diagnostics()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Glasstube: BotGuard / PoToken")

        // visitorData de /youtubei/v1/visitor_id (VisitorService), con el cliente WEB
        guard let web = catalog.profile("WEB") else { throw PoTokenError("falta el perfil WEB") }
        visitorData = try await Innertube().fetchVisitorData(web: web)
        step("visitorData: \(visitorData?.prefix(16) ?? "nil")…")

        // Desafío: página de inicio (ytcfg + window.ytAtN) o /att/get como respaldo
        let (challenge, ytcfg) = try await challengeData(web: web)
        try await startMinter(challenge: challenge, ytcfg: ytcfg, requestKey: Self.requestKey)
    }

    /// BotGuard → GenerateIT → minter, común al PoToken web y al de TV (solo cambian desafío y request key).
    private func startMinter(challenge: [String: Any], ytcfg: Any?, requestKey: String) async throws {
        try await loadPage()
        step("po_token2.html cargado en WKWebView")

        let bgStart = Date()
        let script = """
            if (ytcfg) { window.yt = { config_: ytcfg } }
            const result = await runBotGuard(challenge)
            window.webPoSignalOutput = result.webPoSignalOutput
            if (!window.webPoSignalOutput.length) throw new Error("webPoSignalOutput is empty")
            return result.botguardResponse
            """
        let botguardResponse = try await callJS(script, arguments: ["challenge": challenge, "ytcfg": ytcfg ?? NSNull()])
        guard let botguardResponse = botguardResponse as? String else { throw PoTokenError("botguardResponse no es texto") }
        diagnostics.botguardSeconds = Date().timeIntervalSince(bgStart)
        step("BotGuard respondió (\(botguardResponse.count) caracteres) en \(String(format: "%.2f", diagnostics.botguardSeconds)) s")

        // GenerateIT → integrityToken
        let body = try JSONSerialization.data(withJSONObject: [requestKey, botguardResponse])
        let text = try await botguardRequest("https://www.youtube.com/api/jnn/v1/GenerateIT", body: body)
        guard let array = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              let integrityToken = array.first as? String else {
            throw PoTokenError("GenerateIT ilegible: \(text.prefix(200))")
        }
        let ttl = (array.count > 1 ? (array[1] as? NSNumber)?.intValue : nil) ?? 0
        diagnostics.integrityTTL = ttl
        expiresAt = Date().addingTimeInterval(TimeInterval(ttl - 600)) // 10 minutos de margen, como SmartTube
        step("integrityToken recibido, vigencia \(ttl) s")

        let mintScript = """
            window.getMinter = window.webPoSignalOutput[0]
            window.mintCallback = await window.getMinter(new Uint8Array(integrityTokenBytes))
            if (typeof window.mintCallback === 'undefined') throw new Error("mintCallback is not defined")
            window.webPoSignalOutput = null
            window.getMinter = null
            return true
            """
        _ = try await callJS(mintScript, arguments: ["integrityTokenBytes": Self.base64ToByteArray(integrityToken)])
        minterReady = true
        step("minter listo")
    }

    private func obtainPoToken(identifier: String) async throws -> String {
        let script = """
            const u8 = obtainPoToken(new TextEncoder().encode(identifier))
            return Array.from(u8)
            """
        guard let bytes = try await callJS(script, arguments: ["identifier": identifier]) as? [NSNumber] else {
            throw PoTokenError("obtainPoToken no devolvió bytes")
        }
        // u8ToBase64: base64 con '+' → '-' y '/' → '_'
        return Data(bytes.map { $0.uint8Value }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - Desafío de BotGuard

    private func challengeData(web: ClientProfile) async throws -> (challenge: [String: Any], ytcfg: Any?) {
        if let fromHomepage = try? await challengeFromHomepage() {
            diagnostics.challengeSource = "página de inicio (ytAtN)"
            return fromHomepage
        }
        step("sin desafío en la página de inicio; probando /att/get")
        let body = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": web.clientName, "clientVersion": web.clientVersion]],
            "engagementType": "ENGAGEMENT_TYPE_UNBOUND",
        ])
        let text = try await botguardRequest("https://www.youtube.com/youtubei/v1/att/get?prettyPrint=false", body: body,
                                             extraHeaders: ["Content-Type": "application/json"])
        diagnostics.challengeSource = "/att/get"
        return (try await descrambledChallenge(text), nil)
    }

    /// PATCH(unstem 2026-08) de SmartTube: el par (ytcfg, ytAtN) de la página de inicio.
    private func challengeFromHomepage() async throws -> (challenge: [String: Any], ytcfg: Any?) {
        let page = try await HTTP.shared.string(URL(string: "https://www.youtube.com")!, headers: [
            "Accept": "*/*", "Accept-Language": "en-US,en;q=0.7", "User-Agent": Self.userAgent,
        ])
        var ytcfg: Any?
        if let raw = page.firstMatch(#"ytcfg\.set\((\{.+?\})\);"#, options: [.dotMatchesLineSeparators]),
           let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) {
            ytcfg = object
            diagnostics.hasYtcfg = true
        }
        guard let rawAtt = page.firstMatch(#"window\.ytAtN\(\s*(\{[\s\S]*?\})\s*\)"#) else {
            throw PoTokenError("sin ytAtN en la página")
        }
        let att = try Self.parseLooseJSON(rawAtt)
        guard let r = att["R"] as? String, r.contains("bgChallenge"), r.contains("program"), r.contains("interpreterUrl") else {
            throw PoTokenError("ytAtN sin bgChallenge")
        }
        return (try await descrambledChallenge(r), ytcfg)
    }

    /// `parseDescrambledChallengeData`: descarga el intérprete y arma el objeto que espera `runBotGuard`.
    private func descrambledChallenge(_ raw: String) async throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let bg = root["bgChallenge"] as? [String: Any],
              let interpreterURL = (bg["interpreterUrl"] as? [String: Any])?["privateDoNotAccessOrElseTrustedResourceUrlWrappedValue"] as? String
        else { throw PoTokenError("bgChallenge ilegible") }
        let interpreter = try await HTTP.shared.string(URL(string: "https:" + interpreterURL)!)
        diagnostics.interpreterBytes = interpreter.utf8.count
        step("intérprete de BotGuard descargado (\(interpreter.utf8.count) B)")
        return [
            "interpreterJavascript": [
                "privateDoNotAccessOrElseSafeScriptWrappedValue": interpreter,
                "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue": interpreterURL,
            ],
            "interpreterHash": bg["interpreterHash"] ?? "",
            "program": bg["program"] ?? "",
            "globalName": bg["globalName"] ?? "",
            "clientExperimentsStateBlob": bg["clientExperimentsStateBlob"] ?? "",
        ]
    }

    /// `parseLooseJSON` (BgUtils): el literal de ytAtN no es JSON estricto.
    static func parseLooseJSON(_ loose: String) throws -> [String: Any] {
        var text = loose
        // \xNN → carácter
        let hex = try NSRegularExpression(pattern: #"\\x([0-9A-Fa-f]{2})"#)
        for match in hex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let range = Range(match.range, in: text)!
            let code = UInt8(text[Range(match.range(at: 1), in: text)!], radix: 16)!
            text.replaceSubrange(range, with: String(UnicodeScalar(code)))
        }
        // comas finales
        text = text.replacingOccurrences(of: #",\s*([\]}])"#, with: "$1", options: .regularExpression)
        // 'cadenas' → "cadenas"
        let single = try NSRegularExpression(pattern: #"'((?:[^'\\]|\\[\s\S])*)'"#)
        for match in single.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let range = Range(match.range, in: text)!
            let inner = String(text[Range(match.range(at: 1), in: text)!]).replacingOccurrences(of: "\\'", with: "'")
            let quoted = String(decoding: try JSONSerialization.data(withJSONObject: [inner]), as: UTF8.self).dropFirst().dropLast()
            text.replaceSubrange(range, with: quoted)
        }
        // claves sin comillas
        text = text.replacingOccurrences(of: #"([{,]\s*)([a-zA-Z0-9_$]+)\s*:"#, with: "$1\"$2\":", options: .regularExpression)
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw PoTokenError("ytAtN no es un objeto")
        }
        return object
    }

    // MARK: - Red (makeBotguardServiceRequest)

    private func botguardRequest(_ url: String, body: Data?, extraHeaders: [String: String] = [:]) async throws -> String {
        var headers = [
            "User-Agent": Self.userAgent,
            "Accept": "application/json",
            "Content-Type": "application/json+protobuf",
            "x-goog-api-key": Self.googleAPIKey,
            "x-user-agent": "grpc-web-javascript/0.1",
        ]
        headers.merge(extraHeaders) { _, new in new }
        return try await HTTP.shared.string(URL(string: url)!, method: body == nil ? "GET" : "POST", headers: headers, body: body)
    }

    // MARK: - WKWebView

    private func loadPage() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // blockNetworkLoads: bloquea toda subcarga de la página (el documento se inyecta con loadHTMLString)
        let rules = """
            [{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","raw","svg-document","media","popup","ping","fetch","websocket","other"]},"action":{"type":"block"}}]
            """
        do {
            if let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "glasstube-block-all", encodedContentRuleList: rules) {
                configuration.userContentController.add(ruleList)
                step("red de la página bloqueada (regla de contenido)")
            }
        } catch {
            step("no se pudo compilar la regla de bloqueo: \(error)")
        }

        let frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        // Ventana sin bordes fuera de pantalla: visible para WebKit, invisible para el usuario.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        self.window = window
        self.webView = webView

        let url = Bundle.module.url(forResource: "po_token2", withExtension: "html", subdirectory: "potoken")!
        let html = try String(contentsOf: url, encoding: .utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com")!)
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        minterReady = false
        step("el proceso WebContent terminó")
    }

    /// `callAsyncJavaScript` espera la promesa del cuerpo; con límite de tiempo como el `latch.await` de Android.
    private func callJS(_ body: String, arguments: [String: Any], timeout: TimeInterval = 20) async throws -> Any? {
        guard let webView else { throw PoTokenError("WKWebView no inicializado") }
        return try await withThrowingTaskGroup(of: Any?.self) { group in
            group.addTask { @MainActor in
                try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw PoTokenError("tiempo agotado (\(Int(timeout)) s) en WKWebView")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func step(_ message: String) {
        diagnostics.steps.append(message)
        Log.debug("PoToken: \(message)")
    }

    /// `base64ToU8` con el alfabeto de YouTube ('-' '_' '.').
    static func base64ToByteArray(_ base64: String) -> [Int] {
        var s = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: ".", with: "=")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s).map { $0.map(Int.init) } ?? []
    }
}
