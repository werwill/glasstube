import Foundation
#if canImport(WebKit) && canImport(AppKit)
import AppKit
import WebKit
#endif

/// La página web oculta donde corre BotGuard para `PoTokenWebViewProvider`: WKWebView en macOS, WebView2 en Windows.
@MainActor
protocol BotGuardPage: AnyObject {
    /// Nombre para el diagnóstico y los errores ("WKWebView", "WebView2").
    var name: String { get }
    /// Se llama si el proceso de la página termina; el minter deja de servir.
    var onTerminate: (() -> Void)? { get set }
    /// Carga `html` con origen `baseURL` y bloquea toda subcarga de la página.
    func load(html: String, baseURL: URL, userAgent: String, log: @escaping (String) -> Void) async throws
    /// `callAsyncJavaScript`: `body` es el cuerpo de una función async, cada argumento es una variable con su valor
    /// (convertible a JSON) y el resultado es el valor de la promesa (texto, números, arreglos…).
    func callAsync(_ body: String, arguments: [String: Any]) async throws -> Any?
    func close()
}

enum BotGuardPages {
    @MainActor
    static func make() throws -> BotGuardPage {
        #if canImport(WebKit) && canImport(AppKit)
        WKWebViewBotGuardPage()
        #elseif os(Windows)
        WebView2BotGuardPage()
        #else
        throw PoTokenError("PoToken: no hay WebView en esta plataforma")
        #endif
    }
}

#if canImport(WebKit) && canImport(AppKit)
/// WKWebView en una ventana sin bordes fuera de pantalla (visible para WebKit, invisible para el usuario), con una
/// regla de contenido que bloquea la red de la página.
@MainActor
final class WKWebViewBotGuardPage: NSObject, BotGuardPage, WKNavigationDelegate {
    let name = "WKWebView"
    var onTerminate: (() -> Void)?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    func load(html: String, baseURL: URL, userAgent: String, log: @escaping (String) -> Void) async throws {
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
                log("red de la página bloqueada (regla de contenido)")
            }
        } catch {
            log("no se pudo compilar la regla de bloqueo: \(error)")
        }

        let frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.customUserAgent = userAgent
        webView.navigationDelegate = self
        // Ventana sin bordes fuera de pantalla: visible para WebKit, invisible para el usuario.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        self.window = window
        self.webView = webView

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func callAsync(_ body: String, arguments: [String: Any]) async throws -> Any? {
        guard let webView else { throw PoTokenError("WKWebView no inicializado") }
        return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }

    func close() {
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        window?.close()
        webView = nil
        window = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onTerminate?()
    }
}
#endif
