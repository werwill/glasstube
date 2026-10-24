// WebView2 oculto para BotGuard: el equivalente en Windows del WKWebView de PoTokenProvider.swift.
//
// - Todo lo de WebView2 (COM, STA) vive en un hilo propio con su bucle de mensajes y una ventana sin bordes fuera de
//   pantalla, así no depende del bucle de la app ni del CLI. Las llamadas públicas solo encolan una tarea en esa
//   ventana (PostMessage) y los resultados vuelven por callbacks desde ese hilo.
// - La página se sirve desde WebResourceRequested: se navega a la URL base (https://www.youtube.com/) y a esa petición
//   se le responde con el HTML; las demás se bloquean con un 403, como `blockNetworkLoads` en Android y la regla de
//   contenido en macOS.
// - WebView2Loader.dll se carga en tiempo de ejecución (va junto al ejecutable); el entorno de ejecución de WebView2
//   (Evergreen) ya viene en Windows 10/11.
#ifdef _WIN32

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <shlwapi.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "WebView2.h"
#include "GTWebView2.h"

#ifdef _MSC_VER
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "uuid.lib")
#endif

#define GT_WM_TASK (WM_APP + 1)
static const wchar_t *const kWindowClass = L"GlasstubeBotGuardWindow";

// MARK: - Cadenas

static wchar_t *gt_wide(const char *utf8) {
    if (!utf8) return NULL;
    int count = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    wchar_t *wide = (wchar_t *)calloc((size_t)count + 1, sizeof(wchar_t));
    if (wide) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, count);
    return wide;
}

static char *gt_utf8(const wchar_t *wide) {
    if (!wide) return NULL;
    int count = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL);
    char *utf8 = (char *)calloc((size_t)count + 1, 1);
    if (utf8) WideCharToMultiByte(CP_UTF8, 0, wide, -1, utf8, count, NULL, NULL);
    return utf8;
}

static char *gt_copy(const char *text) {
    if (!text) return NULL;
    size_t length = strlen(text);
    char *copy = (char *)malloc(length + 1);
    if (copy) memcpy(copy, text, length + 1);
    return copy;
}

// MARK: - Estado

/// Un callback que se llama una sola vez: al completarse, o con E_ABORT al destruir el WebView2.
typedef struct GTPending {
    struct GTPending *next;
    void *context;
    GTWebView2Callback callback;
    bool done;
} GTPending;

struct GTWebView2 {
    HANDLE thread;
    HANDLE windowReady;
    HWND window;
    wchar_t *userDataFolder;
    wchar_t *userAgent;
    void *eventContext;
    GTWebView2Callback events;

    ICoreWebView2Environment *environment;
    ICoreWebView2Controller *controller;
    ICoreWebView2 *webView;

    /// Todos los callbacks creados; se liberan cuando termina el hilo.
    GTPending *pendings;
    GTPending *ready;
    GTPending *navigation;
    wchar_t *documentURL;
    char *html;
};

static GTPending *gt_pending(GTWebView2 *gt, void *context, GTWebView2Callback callback) {
    GTPending *pending = (GTPending *)calloc(1, sizeof(GTPending));
    if (!pending) return NULL;
    pending->context = context;
    pending->callback = callback;
    pending->next = gt->pendings;
    gt->pendings = pending;
    return pending;
}

static void gt_complete(GTPending *pending, int32_t status, const char *text) {
    if (!pending || pending->done) return;
    pending->done = true;
    if (pending->callback) pending->callback(pending->context, status, text);
}

// MARK: - Manejadores COM
//
// Todos los manejadores comparten la misma forma: vtable, cuenta de referencias, dueño y callback pendiente. Solo
// cambia la firma de Invoke, así que cada interfaz tiene su vtable con las tres funciones de IUnknown comunes.

typedef struct GTHandler {
    const void *lpVtbl;
    LONG references;
    const IID *iid;
    GTWebView2 *owner;
    GTPending *pending;
} GTHandler;

static HRESULT STDMETHODCALLTYPE gt_query_interface(GTHandler *self, REFIID riid, void **object) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, self->iid)) {
        *object = self;
        InterlockedIncrement(&self->references);
        return S_OK;
    }
    *object = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE gt_add_ref(GTHandler *self) {
    return (ULONG)InterlockedIncrement(&self->references);
}

static ULONG STDMETHODCALLTYPE gt_release(GTHandler *self) {
    LONG references = InterlockedDecrement(&self->references);
    if (references == 0) free(self);
    return (ULONG)references;
}

/// Un manejador nuevo con una referencia, que pasa a quien lo registra (se suelta después de registrarlo).
static GTHandler *gt_handler(const void *vtable, const IID *iid, GTWebView2 *owner, GTPending *pending) {
    GTHandler *handler = (GTHandler *)calloc(1, sizeof(GTHandler));
    if (!handler) return NULL;
    handler->lpVtbl = vtable;
    handler->references = 1;
    handler->iid = iid;
    handler->owner = owner;
    handler->pending = pending;
    return handler;
}

#define GT_IUNKNOWN_ENTRIES (void *)gt_query_interface, (void *)gt_add_ref, (void *)gt_release

static void gt_controller_created(GTWebView2 *gt, HRESULT error, ICoreWebView2Controller *controller);

// Entorno creado → controlador (InPrivate si el entorno lo permite).
static HRESULT STDMETHODCALLTYPE gt_environment_completed(GTHandler *self, HRESULT error,
                                                          ICoreWebView2Environment *environment);
static const ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl kEnvironmentCompletedVtbl = {
    GT_IUNKNOWN_ENTRIES, (void *)gt_environment_completed,
};

static HRESULT STDMETHODCALLTYPE gt_controller_completed(GTHandler *self, HRESULT error,
                                                         ICoreWebView2Controller *controller) {
    gt_controller_created(self->owner, error, controller);
    return S_OK;
}
static const ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl kControllerCompletedVtbl = {
    GT_IUNKNOWN_ENTRIES, (void *)gt_controller_completed,
};

static HRESULT STDMETHODCALLTYPE gt_environment_completed(GTHandler *self, HRESULT error,
                                                          ICoreWebView2Environment *environment) {
    GTWebView2 *gt = self->owner;
    if (FAILED(error) || !environment) {
        gt_complete(gt->ready, FAILED(error) ? (int32_t)error : (int32_t)E_FAIL, "no se pudo crear el entorno de WebView2");
        return S_OK;
    }
    gt->environment = environment;
    ICoreWebView2Environment_AddRef(environment);

    GTHandler *handler = gt_handler(&kControllerCompletedVtbl, &IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
                                    gt, NULL);
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *completed =
        (ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *)handler;
    HRESULT result = E_NOINTERFACE;
    ICoreWebView2Environment10 *environment10 = NULL;
    if (SUCCEEDED(ICoreWebView2Environment_QueryInterface(environment, &IID_ICoreWebView2Environment10,
                                                          (void **)&environment10))) {
        ICoreWebView2ControllerOptions *options = NULL;
        if (SUCCEEDED(ICoreWebView2Environment10_CreateCoreWebView2ControllerOptions(environment10, &options))) {
            // Como `websiteDataStore = .nonPersistent()` en macOS.
            ICoreWebView2ControllerOptions_put_IsInPrivateModeEnabled(options, TRUE);
            result = ICoreWebView2Environment10_CreateCoreWebView2ControllerWithOptions(environment10, gt->window,
                                                                                         options, completed);
            ICoreWebView2ControllerOptions_Release(options);
        }
        ICoreWebView2Environment10_Release(environment10);
    }
    if (FAILED(result)) result = ICoreWebView2Environment_CreateCoreWebView2Controller(environment, gt->window, completed);
    gt_release(handler);
    if (FAILED(result)) gt_complete(gt->ready, (int32_t)result, "no se pudo crear el controlador de WebView2");
    return S_OK;
}

// Navegación terminada → `done` de gt_webview2_load_html.
static HRESULT STDMETHODCALLTYPE gt_navigation_completed(GTHandler *self, ICoreWebView2 *sender,
                                                         ICoreWebView2NavigationCompletedEventArgs *args) {
    GTWebView2 *gt = self->owner;
    BOOL success = FALSE;
    COREWEBVIEW2_WEB_ERROR_STATUS status = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
    ICoreWebView2NavigationCompletedEventArgs_get_IsSuccess(args, &success);
    if (!success) ICoreWebView2NavigationCompletedEventArgs_get_WebErrorStatus(args, &status);
    GTPending *navigation = gt->navigation;
    gt->navigation = NULL;
    gt_complete(navigation, success ? 0 : (int32_t)(status == 0 ? E_FAIL : status), success ? NULL : "la navegación falló");
    return S_OK;
}
static const ICoreWebView2NavigationCompletedEventHandlerVtbl kNavigationCompletedVtbl = {
    GT_IUNKNOWN_ENTRIES, (void *)gt_navigation_completed,
};

// Cada petición de la página: el documento recibe el HTML, lo demás un 403.
static HRESULT STDMETHODCALLTYPE gt_resource_requested(GTHandler *self, ICoreWebView2 *sender,
                                                       ICoreWebView2WebResourceRequestedEventArgs *args) {
    GTWebView2 *gt = self->owner;
    ICoreWebView2WebResourceRequest *request = NULL;
    LPWSTR uri = NULL;
    if (SUCCEEDED(ICoreWebView2WebResourceRequestedEventArgs_get_Request(args, &request)) && request) {
        ICoreWebView2WebResourceRequest_get_Uri(request, &uri);
        ICoreWebView2WebResourceRequest_Release(request);
    }
    bool isDocument = uri && gt->documentURL && gt->html && wcscmp(uri, gt->documentURL) == 0;
    if (uri) CoTaskMemFree(uri);

    ICoreWebView2WebResourceResponse *response = NULL;
    if (isDocument) {
        IStream *content = SHCreateMemStream((const BYTE *)gt->html, (UINT)strlen(gt->html));
        ICoreWebView2Environment_CreateWebResourceResponse(gt->environment, content, 200, L"OK",
                                                           L"Content-Type: text/html; charset=utf-8", &response);
        if (content) IStream_Release(content);
    } else {
        ICoreWebView2Environment_CreateWebResourceResponse(gt->environment, NULL, 403, L"Blocked", L"", &response);
    }
    if (response) {
        ICoreWebView2WebResourceRequestedEventArgs_put_Response(args, response);
        ICoreWebView2WebResourceResponse_Release(response);
    }
    return S_OK;
}
static const ICoreWebView2WebResourceRequestedEventHandlerVtbl kResourceRequestedVtbl = {
    GT_IUNKNOWN_ENTRIES, (void *)gt_resource_requested,
};

// `chrome.webview.postMessage` → evento GTWebView2EventMessage.
static HRESULT STDMETHODCALLTYPE gt_message_received(GTHandler *self, ICoreWebView2 *sender,
                                                     ICoreWebView2WebMessageReceivedEventArgs *args) {
    GTWebView2 *gt = self->owner;
    LPWSTR message = NULL;
    if (SUCCEEDED(ICoreWebView2WebMessageReceivedEventArgs_TryGetWebMessageAsString(args, &message)) && message) {
        char *text = gt_utf8(message);
        CoTaskMemFree(message);
        if (gt->events) gt->events(gt->eventContext, GTWebView2EventMessage, text);
        free(text);
    }
    return S_OK;
}
static const ICoreWebView2WebMessageReceivedEventHandlerVtbl kMessageReceivedVtbl = {
    GT_IUNKNOWN_ENTRIES, (void *)gt_message_received,
};

static HRESULT STDMETHODCALLTYPE gt_process_failed(GTHandler *self, ICoreWebView2 *sender,
                                                   ICoreWebView2ProcessFailedEventArgs *args) {
    GTWebView2 *gt = self->owner;
    if (gt->events) gt->events(gt->eventContext, GTWebView2EventProcessFailed, NULL);
    GTPending *navigation = gt->navigation;
    gt->navigation = NULL;
    gt_complete(navigation, (int32_t)E_FAIL, "el proceso de WebView2 terminó");
    return S_OK;
}
static const ICoreWebView2ProcessFailedEventHandlerVtbl kProcessFailedVtbl = {
    GT_IUNKNOWN_ENTRIES, (void *)gt_process_failed,
};

static HRESULT STDMETHODCALLTYPE gt_script_completed(GTHandler *self, HRESULT error, LPCWSTR result) {
    char *text = gt_utf8(result);
    gt_complete(self->pending, (int32_t)error, text);
    free(text);
    return S_OK;
}
static const ICoreWebView2ExecuteScriptCompletedHandlerVtbl kScriptCompletedVtbl = {
    GT_IUNKNOWN_ENTRIES, (void *)gt_script_completed,
};

static void gt_controller_created(GTWebView2 *gt, HRESULT error, ICoreWebView2Controller *controller) {
    if (FAILED(error) || !controller) {
        gt_complete(gt->ready, FAILED(error) ? (int32_t)error : (int32_t)E_FAIL, "no se pudo crear el controlador de WebView2");
        return;
    }
    gt->controller = controller;
    ICoreWebView2Controller_AddRef(controller);
    if (FAILED(ICoreWebView2Controller_get_CoreWebView2(controller, &gt->webView)) || !gt->webView) {
        gt_complete(gt->ready, (int32_t)E_FAIL, "el controlador de WebView2 no tiene CoreWebView2");
        return;
    }
    RECT bounds = {0, 0, 640, 360};
    ICoreWebView2Controller_put_Bounds(controller, bounds);
    // Visible para el WebView2 (sin estrangular temporizadores), aunque la ventana esté fuera de pantalla.
    ICoreWebView2Controller_put_IsVisible(controller, TRUE);

    ICoreWebView2Settings *settings = NULL;
    if (SUCCEEDED(ICoreWebView2_get_Settings(gt->webView, &settings)) && settings) {
        ICoreWebView2Settings_put_AreDevToolsEnabled(settings, FALSE);
        ICoreWebView2Settings_put_AreDefaultContextMenusEnabled(settings, FALSE);
        ICoreWebView2Settings_put_IsWebMessageEnabled(settings, TRUE);
        ICoreWebView2Settings2 *settings2 = NULL;
        if (gt->userAgent &&
            SUCCEEDED(ICoreWebView2Settings_QueryInterface(settings, &IID_ICoreWebView2Settings2, (void **)&settings2))) {
            ICoreWebView2Settings2_put_UserAgent(settings2, gt->userAgent);
            ICoreWebView2Settings2_Release(settings2);
        }
        ICoreWebView2Settings_Release(settings);
    }

    EventRegistrationToken token;
    GTHandler *handler;
    handler = gt_handler(&kNavigationCompletedVtbl, &IID_ICoreWebView2NavigationCompletedEventHandler, gt, NULL);
    ICoreWebView2_add_NavigationCompleted(gt->webView, (ICoreWebView2NavigationCompletedEventHandler *)handler, &token);
    gt_release(handler);
    handler = gt_handler(&kResourceRequestedVtbl, &IID_ICoreWebView2WebResourceRequestedEventHandler, gt, NULL);
    ICoreWebView2_add_WebResourceRequested(gt->webView, (ICoreWebView2WebResourceRequestedEventHandler *)handler, &token);
    gt_release(handler);
    handler = gt_handler(&kMessageReceivedVtbl, &IID_ICoreWebView2WebMessageReceivedEventHandler, gt, NULL);
    ICoreWebView2_add_WebMessageReceived(gt->webView, (ICoreWebView2WebMessageReceivedEventHandler *)handler, &token);
    gt_release(handler);
    handler = gt_handler(&kProcessFailedVtbl, &IID_ICoreWebView2ProcessFailedEventHandler, gt, NULL);
    ICoreWebView2_add_ProcessFailed(gt->webView, (ICoreWebView2ProcessFailedEventHandler *)handler, &token);
    gt_release(handler);
    ICoreWebView2_AddWebResourceRequestedFilter(gt->webView, L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);

    gt_complete(gt->ready, 0, NULL);
}

// MARK: - Tareas en el hilo del WebView2

typedef enum { GTTaskLoad, GTTaskScript, GTTaskDestroy } GTTaskKind;

typedef struct GTTask {
    GTTaskKind kind;
    char *url;
    char *text;
    GTPending *pending;
} GTTask;

static void gt_post(GTWebView2 *gt, GTTaskKind kind, const char *url, const char *text, void *context,
                    GTWebView2Callback callback) {
    GTTask *task = (GTTask *)calloc(1, sizeof(GTTask));
    if (!task) {
        if (callback) callback(context, (int32_t)E_OUTOFMEMORY, NULL);
        return;
    }
    task->kind = kind;
    task->url = gt_copy(url);
    task->text = gt_copy(text);
    // El GTPending se crea en el hilo del WebView2 (ahí vive la lista); aquí solo viaja el callback.
    task->pending = (GTPending *)calloc(1, sizeof(GTPending));
    if (task->pending) {
        task->pending->context = context;
        task->pending->callback = callback;
    }
    if (!PostMessageW(gt->window, GT_WM_TASK, 0, (LPARAM)task)) {
        if (callback) callback(context, (int32_t)HRESULT_FROM_WIN32(GetLastError()), "el hilo de WebView2 no responde");
        free(task->url);
        free(task->text);
        free(task->pending);
        free(task);
    }
}

static void gt_abort_all(GTWebView2 *gt) {
    for (GTPending *pending = gt->pendings; pending; pending = pending->next) {
        gt_complete(pending, (int32_t)E_ABORT, "WebView2 cerrado");
    }
}

static void gt_run(GTWebView2 *gt, GTTask *task) {
    GTPending *pending = gt_pending(gt, task->pending ? task->pending->context : NULL,
                                    task->pending ? task->pending->callback : NULL);
    free(task->pending);
    switch (task->kind) {
    case GTTaskLoad: {
        if (!gt->webView) {
            gt_complete(pending, (int32_t)E_UNEXPECTED, "WebView2 sin inicializar");
            break;
        }
        gt_complete(gt->navigation, (int32_t)E_ABORT, "navegación reemplazada");
        free(gt->documentURL);
        free(gt->html);
        gt->documentURL = gt_wide(task->url);
        gt->html = task->text;
        task->text = NULL;
        gt->navigation = pending;
        HRESULT result = ICoreWebView2_Navigate(gt->webView, gt->documentURL);
        if (FAILED(result)) {
            gt->navigation = NULL;
            gt_complete(pending, (int32_t)result, "Navigate falló");
        }
        break;
    }
    case GTTaskScript: {
        if (!gt->webView) {
            gt_complete(pending, (int32_t)E_UNEXPECTED, "WebView2 sin inicializar");
            break;
        }
        wchar_t *script = gt_wide(task->text);
        GTHandler *handler = gt_handler(&kScriptCompletedVtbl, &IID_ICoreWebView2ExecuteScriptCompletedHandler, gt, pending);
        HRESULT result = ICoreWebView2_ExecuteScript(gt->webView, script,
                                                     (ICoreWebView2ExecuteScriptCompletedHandler *)handler);
        gt_release(handler);
        free(script);
        if (FAILED(result)) gt_complete(pending, (int32_t)result, "ExecuteScript falló");
        break;
    }
    case GTTaskDestroy:
        gt_abort_all(gt);
        if (gt->controller) ICoreWebView2Controller_Close(gt->controller);
        DestroyWindow(gt->window);
        break;
    }
    free(task->url);
    free(task->text);
    free(task);
}

static LRESULT CALLBACK gt_window_procedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    GTWebView2 *gt = (GTWebView2 *)GetWindowLongPtrW(window, GWLP_USERDATA);
    switch (message) {
    case GT_WM_TASK:
        if (gt) gt_run(gt, (GTTask *)lParam);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(window, message, wParam, lParam);
    }
}

typedef HRESULT(STDAPICALLTYPE *GTCreateEnvironment)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions *,
                                                      ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);

static void gt_start_environment(GTWebView2 *gt) {
    HMODULE loader = LoadLibraryW(L"WebView2Loader.dll");
    GTCreateEnvironment create = loader
        ? (GTCreateEnvironment)(void *)GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions")
        : NULL;
    if (!create) {
        gt_complete(gt->ready, (int32_t)HRESULT_FROM_WIN32(GetLastError()), "falta WebView2Loader.dll");
        return;
    }
    GTHandler *handler = gt_handler(&kEnvironmentCompletedVtbl,
                                    &IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, gt, NULL);
    HRESULT result = create(NULL, gt->userDataFolder, NULL,
                            (ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *)handler);
    gt_release(handler);
    if (FAILED(result)) gt_complete(gt->ready, (int32_t)result, "no hay entorno de ejecución de WebView2");
}

static DWORD WINAPI gt_thread_main(LPVOID parameter) {
    GTWebView2 *gt = (GTWebView2 *)parameter;
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);

    WNDCLASSEXW windowClass = {0};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.lpfnWndProc = gt_window_procedure;
    windowClass.hInstance = GetModuleHandleW(NULL);
    windowClass.lpszClassName = kWindowClass;
    RegisterClassExW(&windowClass); // falla sin daño si ya estaba registrada
    // Ventana sin bordes fuera de pantalla, como la NSWindow de macOS: visible para WebView2, no para la persona.
    gt->window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kWindowClass, L"Glasstube BotGuard", WS_POPUP,
                                 -20000, -20000, 640, 360, NULL, NULL, windowClass.hInstance, NULL);
    if (gt->window) {
        SetWindowLongPtrW(gt->window, GWLP_USERDATA, (LONG_PTR)gt);
        ShowWindow(gt->window, SW_SHOWNOACTIVATE);
    }
    SetEvent(gt->windowReady);
    if (!gt->window) {
        gt_complete(gt->ready, (int32_t)HRESULT_FROM_WIN32(GetLastError()), "no se pudo crear la ventana de WebView2");
        CoUninitialize();
        return 1;
    }

    gt_start_environment(gt);
    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    // Tareas que llegaron después de cerrar la ventana no se entregan; lo pendiente ya se abortó en GTTaskDestroy.
    gt_abort_all(gt);
    if (gt->webView) ICoreWebView2_Release(gt->webView);
    if (gt->controller) ICoreWebView2Controller_Release(gt->controller);
    if (gt->environment) ICoreWebView2Environment_Release(gt->environment);
    CoUninitialize();
    return 0;
}

// MARK: - API pública

GTWebView2 *gt_webview2_create(const char *userDataFolder, const char *userAgent,
                               void *eventContext, GTWebView2Callback events,
                               void *readyContext, GTWebView2Callback ready) {
    GTWebView2 *gt = (GTWebView2 *)calloc(1, sizeof(GTWebView2));
    if (!gt) {
        if (ready) ready(readyContext, (int32_t)E_OUTOFMEMORY, NULL);
        return NULL;
    }
    gt->userDataFolder = userDataFolder && *userDataFolder ? gt_wide(userDataFolder) : NULL;
    gt->userAgent = gt_wide(userAgent);
    gt->eventContext = eventContext;
    gt->events = events;
    gt->ready = gt_pending(gt, readyContext, ready);
    gt->windowReady = CreateEventW(NULL, TRUE, FALSE, NULL);
    gt->thread = CreateThread(NULL, 0, gt_thread_main, gt, 0, NULL);
    if (!gt->thread) {
        gt_complete(gt->ready, (int32_t)HRESULT_FROM_WIN32(GetLastError()), "no se pudo crear el hilo de WebView2");
    } else {
        WaitForSingleObject(gt->windowReady, INFINITE);
    }
    return gt;
}

void gt_webview2_load_html(GTWebView2 *webView, const char *url, const char *html, void *context,
                           GTWebView2Callback done) {
    gt_post(webView, GTTaskLoad, url, html, context, done);
}

void gt_webview2_execute_script(GTWebView2 *webView, const char *script, void *context, GTWebView2Callback done) {
    gt_post(webView, GTTaskScript, NULL, script, context, done);
}

void gt_webview2_destroy(GTWebView2 *gt) {
    if (!gt) return;
    if (gt->thread) {
        if (gt->window) gt_post(gt, GTTaskDestroy, NULL, NULL, NULL, NULL);
        WaitForSingleObject(gt->thread, INFINITE);
        CloseHandle(gt->thread);
    }
    gt_abort_all(gt);
    for (GTPending *pending = gt->pendings; pending;) {
        GTPending *next = pending->next;
        free(pending);
        pending = next;
    }
    if (gt->windowReady) CloseHandle(gt->windowReady);
    free(gt->userDataFolder);
    free(gt->userAgent);
    free(gt->documentURL);
    free(gt->html);
    free(gt);
}

#endif // _WIN32
