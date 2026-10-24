// Un WebView2 oculto para BotGuard (PoToken) en Windows, con una API de C sin tipos de Win32 para llamarla desde
// Swift. Ver GTWebView2.c. En otras plataformas este módulo queda vacío.
#ifndef GT_WEBVIEW2_H
#define GT_WEBVIEW2_H

#ifdef _WIN32
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GTWebView2 GTWebView2;

/// `status` es 0 si todo salió bien, o un HRESULT / `COREWEBVIEW2_WEB_ERROR_STATUS` si no. `text` es UTF-8 y solo
/// vale durante la llamada (puede ser NULL). Los callbacks llegan desde el hilo del WebView2, nunca desde quien llama.
typedef void (*GTWebView2Callback)(void *context, int32_t status, const char *text);

enum {
    /// `chrome.webview.postMessage(texto)` desde la página; `text` es el mensaje.
    GTWebView2EventMessage = 1,
    /// El proceso del navegador o del renderizador terminó; el WebView2 ya no sirve.
    GTWebView2EventProcessFailed = 2,
};

/// Crea el WebView2 en un hilo STA propio, dentro de una ventana sin bordes fuera de pantalla, en modo InPrivate.
/// `ready` se llama una vez, cuando el WebView2 está listo o falló. `events` recibe `GTWebView2Event…` en `status`.
/// `userDataFolder` puede ser NULL o vacío (la carpeta del ejecutable). Carga WebView2Loader.dll en tiempo de ejecución.
GTWebView2 *gt_webview2_create(const char *userDataFolder, const char *userAgent,
                               void *eventContext, GTWebView2Callback events,
                               void *readyContext, GTWebView2Callback ready);

/// Navega a `url` y responde a esa petición con `html`; cualquier otra carga de la página se bloquea (403).
/// `done` al terminar la navegación.
void gt_webview2_load_html(GTWebView2 *webView, const char *url, const char *html,
                           void *context, GTWebView2Callback done);

/// `ExecuteScript`: `done` con el resultado como JSON.
void gt_webview2_execute_script(GTWebView2 *webView, const char *script, void *context, GTWebView2Callback done);

/// Cierra el WebView2 y su hilo. Los callbacks pendientes se llaman con E_ABORT. No usar `webView` después.
void gt_webview2_destroy(GTWebView2 *webView);

#ifdef __cplusplus
}
#endif

#endif // _WIN32
#endif // GT_WEBVIEW2_H
