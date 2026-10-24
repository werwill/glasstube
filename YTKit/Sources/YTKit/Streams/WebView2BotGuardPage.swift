#if os(Windows)
import CWebView2
import Foundation

/// `BotGuardPage` sobre WebView2 (puente en C en CWebView2/GTWebView2.c). El WebView2 corre en su propio hilo; los
/// resultados vuelven por callbacks de C que reanudan continuaciones.
///
/// `callAsyncJavaScript` no existe en WebView2 (`ExecuteScript` no espera promesas), así que el cuerpo va dentro de una
/// función async con los argumentos como parámetros, y el resultado vuelve por `chrome.webview.postMessage` con un id.
@MainActor
final class WebView2BotGuardPage: BotGuardPage {
    let name = "WebView2"
    var onTerminate: (() -> Void)?
    private var handle: OpaquePointer?
    private let sink = EventSink()
    private var calls: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var nextCallId = 0

    init() {
        sink.page = self
    }

    func load(html: String, baseURL: URL, userAgent: String, log: @escaping (String) -> Void) async throws {
        close()
        // Carpeta de datos del WebView2 (en modo InPrivate no guarda la sesión); vacía = la del ejecutable.
        let folder = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { "\($0)\\Glasstube\\WebView2" } ?? ""
        let sinkContext = Unmanaged.passUnretained(sink).toOpaque()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ready = OneShot { status, text in
                if status == 0 { continuation.resume() } else { continuation.resume(throwing: Self.error(status, text)) }
            }
            handle = gt_webview2_create(folder, userAgent, sinkContext, eventCallback,
                                        Unmanaged.passRetained(ready).toOpaque(), oneShotCallback)
        }
        log("red de la página bloqueada (WebResourceRequested)")

        guard let handle else { throw PoTokenError("WebView2 no inicializado") }
        // La URL tal como la reporta WebView2 en WebResourceRequested (con la barra final).
        var url = baseURL.absoluteString
        if baseURL.path.isEmpty { url += "/" }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done = OneShot { status, text in
                if status == 0 { continuation.resume() } else { continuation.resume(throwing: Self.error(status, text)) }
            }
            gt_webview2_load_html(handle, url, html, Unmanaged.passRetained(done).toOpaque(), oneShotCallback)
        }
    }

    func callAsync(_ body: String, arguments: [String: Any]) async throws -> Any? {
        guard let handle else { throw PoTokenError("WebView2 no inicializado") }
        let names = arguments.keys.sorted()
        let values = String(decoding: try JSONSerialization.data(withJSONObject: names.map { arguments[$0]! }), as: UTF8.self)
        let id = nextCallId
        nextCallId += 1
        let script = """
            (async function(\(names.joined(separator: ", "))) {
            \(body)
            }).apply(null, \(values)).then(
                value => chrome.webview.postMessage(JSON.stringify({ id: \(id), ok: true, value: value === undefined ? null : value })),
                error => chrome.webview.postMessage(JSON.stringify({ id: \(id), ok: false, error: String((error && error.stack) || error) })))
            """
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                calls[id] = continuation
                // Si ExecuteScript falla, la promesa nunca llega a postMessage.
                let started = OneShot { [weak self] status, text in
                    guard status != 0 else { return }
                    Task { @MainActor in self?.finish(id, .failure(Self.error(status, text))) }
                }
                gt_webview2_execute_script(handle, script, Unmanaged.passRetained(started).toOpaque(), oneShotCallback)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }

    func close() {
        let pending = calls
        calls = [:]
        for continuation in pending.values { continuation.resume(throwing: PoTokenError("WebView2 cerrado")) }
        if let handle { gt_webview2_destroy(handle) }
        handle = nil
    }

    // MARK: - Eventos

    fileprivate func handle(event: Int32, text: String?) {
        switch event {
        case Int32(GTWebView2EventMessage):
            guard let text, let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let id = (message["id"] as? NSNumber)?.intValue else { return }
            if message["ok"] as? Bool == true {
                let value = message["value"]
                finish(id, .success(value is NSNull ? nil : value))
            } else {
                finish(id, .failure(PoTokenError("WebView2: \(message["error"] as? String ?? "error")")))
            }
        case Int32(GTWebView2EventProcessFailed):
            let pending = calls
            calls = [:]
            for continuation in pending.values { continuation.resume(throwing: PoTokenError("el proceso de WebView2 terminó")) }
            onTerminate?()
        default:
            break
        }
    }

    private func finish(_ id: Int, _ result: Result<Any?, Error>) {
        calls.removeValue(forKey: id)?.resume(with: result)
    }

    nonisolated private static func error(_ status: Int32, _ text: String?) -> PoTokenError {
        PoTokenError("WebView2: \(text ?? "error") (0x\(String(UInt32(bitPattern: status), radix: 16)))")
    }
}

/// Recibe los eventos del hilo de WebView2 y los pasa a la página en el actor principal. Vive lo mismo que la página,
/// que destruye el WebView2 (y espera a su hilo) antes de soltarlo.
private final class EventSink: @unchecked Sendable {
    weak var page: WebView2BotGuardPage?
}

/// Un callback de C que se llama una sola vez: el contexto es este objeto retenido, y la llamada lo suelta.
private final class OneShot: @unchecked Sendable {
    let body: (Int32, String?) -> Void
    init(_ body: @escaping (Int32, String?) -> Void) { self.body = body }
}

private let oneShotCallback: GTWebView2Callback = { context, status, text in
    guard let context else { return }
    let callback = Unmanaged<OneShot>.fromOpaque(context).takeRetainedValue()
    callback.body(status, text.map { String(cString: $0) })
}

private let eventCallback: GTWebView2Callback = { context, event, text in
    guard let context else { return }
    let sink = Unmanaged<EventSink>.fromOpaque(context).takeUnretainedValue()
    let text = text.map { String(cString: $0) }
    Task { @MainActor in sink.page?.handle(event: event, text: text) }
}
#endif
