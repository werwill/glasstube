// mpvwin: prueba de libmpv en Windows x64 para PlaybackKit (fase de preparación, sin Swift todavía). Una ventana Win32
// que reproduce una URL (archivo, HLS de un directo) con la libmpv LGPL de Scripts/fetch-libmpv-windows.sh, en uno de
// los tres caminos de salida que se evalúan para la versión de Windows (ver README.md junto a este archivo):
//
//   --mode window        `wid` = un HWND hijo; mpv crea y presenta su swapchain D3D11 (vo=gpu-next). Es el equivalente
//                        de la salida Metal de macOS (`wid` = CAMetalLayer). Lo más simple, pero el video es otra
//                        ventana: la interfaz no se puede dibujar encima con XAML (problema de «airspace»).
//   --mode composition   `d3d11-output-mode=composition`: mpv crea una swapchain para composición sin ventana y la
//                        app la pone en un visual de DirectComposition (en WinUI 3 sería un SwapChainPanel). La
//                        interfaz se compone encima. mpv no se entera solo de los cambios de tamaño (ver WM_SIZE).
//   --mode render        API de render D3D11 (mpv 0.42, API cliente 2.6, render_d3d11.h): la app es dueña del
//                        dispositivo y de la swapchain y mpv dibuja en su textura, como la salida OpenGL de macOS
//                        (`MPVOpenGLView`). Solo si las cabeceras la traen.
//
//   mpvwin [--mode window|composition|render] [--live] [--hwdec H] [-o nombre=valor]… URL
//
// Teclas: espacio pausa, ←/→ ±10 s, V siguiente pista de video (calidad en un HLS), Esc sale. Cada 2 s escribe en la
// consola la posición, la caché, el decodificador y el tamaño de la salida.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00 // Windows 10: SetProcessDpiAwarenessContext, DirectComposition
#endif
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <dcomp.h>

#include <mpv/client.h>
#include <mpv/render.h>
#if MPV_CLIENT_API_VERSION >= MPV_MAKE_VERSION(2, 6)
#include <mpv/render_d3d11.h>
#define HAVE_RENDER_D3D11 1
#endif

#include <algorithm>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr UINT WM_MPV_WAKEUP = WM_APP + 1;
constexpr UINT_PTR STATS_TIMER = 1;

enum class Mode { window, composition, render };

template <class T> struct Com {
    T *p = nullptr;
    Com() = default;
    Com(const Com &) = delete;
    Com &operator=(const Com &) = delete;
    ~Com() { reset(); }
    void reset() { if (p) { p->Release(); p = nullptr; } }
    T **put() { reset(); return &p; }
    T *operator->() const { return p; }
    explicit operator bool() const { return p != nullptr; }
};

struct Options {
    Mode mode = Mode::window;
    bool live = false;
    std::string hwdec = "d3d11va,auto-safe";
    std::vector<std::pair<std::string, std::string>> extra;
    std::string url;
};

struct App {
    Options options;
    HWND window = nullptr;
    HWND video = nullptr; // hijo que ocupa todo el cliente: la «vista» del video
    mpv_handle *mpv = nullptr;

    // composition
    Com<IDCompositionDevice> dcomp;
    Com<IDCompositionTarget> dcompTarget;
    Com<IDCompositionVisual> dcompVisual;
    IDXGISwapChain *attachedSwapchain = nullptr; // sin referencia propia: el visual tiene una

#ifdef HAVE_RENDER_D3D11
    // render
    Com<ID3D11Device> device;
    Com<ID3D11DeviceContext> context;
    Com<IDXGISwapChain1> swapchain;
    mpv_render_context *render = nullptr;
    std::thread renderThread;
    std::mutex renderLock;
    std::condition_variable renderWake;
    bool renderPending = true;
    bool renderQuit = false;
    UINT pendingWidth = 0, pendingHeight = 0; // cambio de tamaño que aplica el hilo de render
#endif
};

App app;

void fail(const char *what, HRESULT hr = S_OK) {
    std::fprintf(stderr, "ERROR: %s (0x%08lx)\n", what, static_cast<unsigned long>(hr));
    std::exit(1);
}

void check(int code, const char *what) {
    if (code < 0) {
        std::fprintf(stderr, "ERROR: %s: %s\n", what, mpv_error_string(code));
        std::exit(1);
    }
}

std::string property(const char *name) {
    char *value = mpv_get_property_string(app.mpv, name);
    std::string text = value ? value : "-";
    mpv_free(value);
    return text;
}

SIZE clientSize(HWND hwnd) {
    RECT rect{};
    GetClientRect(hwnd, &rect);
    return {std::max<LONG>(1, rect.right - rect.left), std::max<LONG>(1, rect.bottom - rect.top)};
}

// MARK: - composition

/// Tras cada VIDEO_RECONFIG: si mpv ya creó la swapchain (`display-swapchain`), se pone en el visual.
void attachCompositionSwapchain() {
    int64_t address = 0;
    if (mpv_get_property(app.mpv, "display-swapchain", MPV_FORMAT_INT64, &address) < 0 || address == 0) return;
    auto *chain = reinterpret_cast<IDXGISwapChain *>(static_cast<intptr_t>(address));
    if (chain == app.attachedSwapchain) return;
    if (!app.dcomp) {
        Com<IDXGIDevice> dxgiDevice;
        HRESULT hr = chain->GetDevice(__uuidof(IDXGIDevice), reinterpret_cast<void **>(dxgiDevice.put()));
        if (FAILED(hr)) fail("GetDevice de la swapchain de mpv", hr);
        hr = DCompositionCreateDevice(dxgiDevice.p, __uuidof(IDCompositionDevice), reinterpret_cast<void **>(app.dcomp.put()));
        if (FAILED(hr)) fail("DCompositionCreateDevice", hr);
        hr = app.dcomp->CreateTargetForHwnd(app.video, TRUE, app.dcompTarget.put());
        if (FAILED(hr)) fail("CreateTargetForHwnd", hr);
        hr = app.dcomp->CreateVisual(app.dcompVisual.put());
        if (FAILED(hr)) fail("CreateVisual", hr);
        app.dcompTarget->SetRoot(app.dcompVisual.p);
    }
    app.dcompVisual->SetContent(chain); // el visual toma su propia referencia
    app.dcomp->Commit();
    app.attachedSwapchain = chain;
    std::fprintf(stderr, "composition: swapchain de mpv %p en el visual\n", static_cast<void *>(chain));
}

std::string compositionSwapchainSize() {
    if (!app.attachedSwapchain) return "-";
    DXGI_SWAP_CHAIN_DESC desc{};
    if (FAILED(app.attachedSwapchain->GetDesc(&desc))) return "?";
    return std::to_string(desc.BufferDesc.Width) + "x" + std::to_string(desc.BufferDesc.Height);
}

// MARK: - render (API D3D11)

#ifdef HAVE_RENDER_D3D11
void createRenderDevice() {
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT; // multihilo: d3d11va decodifica en él
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, nullptr, 0, D3D11_SDK_VERSION,
                                   app.device.put(), nullptr, app.context.put());
    if (FAILED(hr)) fail("D3D11CreateDevice", hr);
    Com<IDXGIDevice> dxgiDevice;
    Com<IDXGIAdapter> adapter;
    Com<IDXGIFactory2> factory;
    app.device->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void **>(dxgiDevice.put()));
    dxgiDevice->GetAdapter(adapter.put());
    adapter->GetParent(__uuidof(IDXGIFactory2), reinterpret_cast<void **>(factory.put()));
    SIZE size = clientSize(app.video);
    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = static_cast<UINT>(size.cx);
    desc.Height = static_cast<UINT>(size.cy);
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    // En WinUI 3 sería CreateSwapChainForComposition + ISwapChainPanelNative::SetSwapChain; para la prueba basta el HWND.
    hr = factory->CreateSwapChainForHwnd(app.device.p, app.video, &desc, nullptr, nullptr, app.swapchain.put());
    if (FAILED(hr)) fail("CreateSwapChainForHwnd", hr);
}

void renderLoop() {
    for (;;) {
        UINT width = 0, height = 0;
        {
            std::unique_lock<std::mutex> lock(app.renderLock);
            app.renderWake.wait(lock, [] { return app.renderPending || app.renderQuit; });
            if (app.renderQuit) return;
            app.renderPending = false;
            std::swap(width, app.pendingWidth);
            std::swap(height, app.pendingHeight);
        }
        if (width && height) {
            // Ninguna referencia al búfer trasero vive fuera de este hilo: se puede redimensionar aquí.
            HRESULT hr = app.swapchain->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0);
            if (FAILED(hr)) std::fprintf(stderr, "ResizeBuffers %ux%u: 0x%08lx\n", width, height, static_cast<unsigned long>(hr));
        }
        uint64_t flags = mpv_render_context_update(app.render);
        if (!(flags & MPV_RENDER_UPDATE_FRAME) && !(width && height)) continue;
        Com<ID3D11Texture2D> backbuffer;
        if (FAILED(app.swapchain->GetBuffer(0, __uuidof(ID3D11Texture2D), reinterpret_cast<void **>(backbuffer.put())))) continue;
        mpv_d3d11_fbo fbo{backbuffer.p};
        mpv_render_param params[] = {{MPV_RENDER_PARAM_D3D11_FBO, &fbo}, {MPV_RENDER_PARAM_INVALID, nullptr}};
        mpv_render_context_render(app.render, params);
        backbuffer.reset();
        app.swapchain->Present(1, 0);
        mpv_render_context_report_swap(app.render);
    }
}

void requestRender(UINT width = 0, UINT height = 0) {
    {
        std::lock_guard<std::mutex> lock(app.renderLock);
        app.renderPending = true;
        if (width && height) {
            app.pendingWidth = width;
            app.pendingHeight = height;
        }
    }
    app.renderWake.notify_one();
}

void startRender() {
    createRenderDevice();
    mpv_d3d11_init_params init{app.device.p};
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, const_cast<char *>(MPV_RENDER_API_TYPE_D3D11)},
        {MPV_RENDER_PARAM_D3D11_INIT_PARAMS, &init},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    check(mpv_render_context_create(&app.render, app.mpv, params), "mpv_render_context_create (d3d11)");
    // El aviso llega en un hilo de mpv: solo despierta al hilo de render (render.h prohíbe llamar a mpv desde ahí).
    mpv_render_context_set_update_callback(app.render, [](void *) { requestRender(); }, nullptr);
    app.renderThread = std::thread(renderLoop);
}

void stopRender() {
    if (!app.render) return;
    {
        std::lock_guard<std::mutex> lock(app.renderLock);
        app.renderQuit = true;
    }
    app.renderWake.notify_one();
    app.renderThread.join();
    mpv_render_context_free(app.render); // antes de mpv_terminate_destroy
    app.render = nullptr;
}
#endif

// MARK: - mpv

void setUpMPV() {
    app.mpv = mpv_create();
    if (!app.mpv) fail("mpv_create");
    std::vector<std::pair<std::string, std::string>> options = {
        {"hwdec", app.options.hwdec},
        {"idle", "yes"},
        {"keep-open", "yes"},
        {"ytdl", "no"},
        {"config", "no"},
        {"load-scripts", "no"},
        {"osc", "no"},
        {"input-default-bindings", "no"},
        {"input-vo-keyboard", "no"},
        {"audio-client-name", "Glasstube"},
        {"cache", "yes"},
    };
    std::string wid = std::to_string(reinterpret_cast<intptr_t>(app.video));
    switch (app.options.mode) {
    case Mode::window:
        options.insert(options.end(), {{"vo", "gpu-next"}, {"gpu-api", "d3d11"}, {"gpu-context", "d3d11"}, {"wid", wid}});
        break;
    case Mode::composition: {
        SIZE size = clientSize(app.video);
        options.insert(options.end(), {
            {"vo", "gpu-next"}, {"gpu-api", "d3d11"}, {"gpu-context", "d3d11"}, {"d3d11-output-mode", "composition"},
            {"d3d11-composition-size", std::to_string(size.cx) + "x" + std::to_string(size.cy)},
            // La VO (y con ella la swapchain) sigue viva entre archivos: el visual no se queda con una swapchain vieja.
            {"force-window", "yes"},
        });
        break;
    }
    case Mode::render:
        options.push_back({"vo", "libmpv"});
        break;
    }
    if (app.options.live) {
        // Directo HLS: lo que hoy hace AVPlayer. mpv elige una variante al abrir (hls-bitrate, por omisión la de más
        // bitrate) y no cambia sola; la calidad es una pista de video más (`vid`).
        options.insert(options.end(), {{"demuxer-max-bytes", "64MiB"}, {"demuxer-max-back-bytes", "32MiB"}, {"demuxer-seekable-cache", "yes"}});
    }
    options.insert(options.end(), app.options.extra.begin(), app.options.extra.end());
    for (auto &[name, value] : options) {
        int code = mpv_set_option_string(app.mpv, name.c_str(), value.c_str());
        if (code < 0) std::fprintf(stderr, "opción %s=%s: %s\n", name.c_str(), value.c_str(), mpv_error_string(code));
    }
    check(mpv_initialize(app.mpv), "mpv_initialize");
    mpv_request_log_messages(app.mpv, "info");
    mpv_set_wakeup_callback(app.mpv, [](void *) { PostMessageW(app.window, WM_MPV_WAKEUP, 0, 0); }, nullptr);
#ifdef HAVE_RENDER_D3D11
    if (app.options.mode == Mode::render) startRender();
#endif
    const char *load[] = {"loadfile", app.options.url.c_str(), nullptr};
    check(mpv_command(app.mpv, load), "loadfile");
}

void drainEvents() {
    for (;;) {
        mpv_event *event = mpv_wait_event(app.mpv, 0);
        switch (event->event_id) {
        case MPV_EVENT_NONE:
            return;
        case MPV_EVENT_LOG_MESSAGE: {
            auto *log = static_cast<mpv_event_log_message *>(event->data);
            std::fprintf(stderr, "[%s] %s: %s", log->prefix, log->level, log->text);
            break;
        }
        case MPV_EVENT_VIDEO_RECONFIG:
            if (app.options.mode == Mode::composition) attachCompositionSwapchain();
            break;
        case MPV_EVENT_FILE_LOADED:
            std::fprintf(stderr, "cargado: %s, pistas %s\n", property("media-title").c_str(), property("track-list/count").c_str());
            break;
        case MPV_EVENT_END_FILE: {
            auto *end = static_cast<mpv_event_end_file *>(event->data);
            if (end->reason == MPV_END_FILE_REASON_ERROR) std::fprintf(stderr, "error al reproducir: %s\n", mpv_error_string(end->error));
            break;
        }
        case MPV_EVENT_SHUTDOWN:
            PostQuitMessage(0);
            return;
        default:
            break;
        }
    }
}

void printStats() {
    std::string output;
    switch (app.options.mode) {
    case Mode::window: output = "ventana " + property("osd-width") + "x" + property("osd-height"); break;
    case Mode::composition: output = "swapchain " + compositionSwapchainSize(); break;
    case Mode::render: output = "render " + property("osd-width") + "x" + property("osd-height"); break;
    }
    std::fprintf(stderr, "t=%s caché=%ss vid=%s %sx%s %s hwdec=%s caídos=%s/%s · %s\n", property("time-pos").c_str(),
                 property("demuxer-cache-duration").c_str(), property("vid").c_str(), property("width").c_str(),
                 property("height").c_str(), property("video-codec").c_str(), property("hwdec-current").c_str(),
                 property("frame-drop-count").c_str(), property("decoder-frame-drop-count").c_str(), output.c_str());
}

void command(std::initializer_list<const char *> args) {
    std::vector<const char *> list(args);
    list.push_back(nullptr);
    mpv_command_async(app.mpv, 0, list.data());
}

LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_SIZE: {
        UINT width = LOWORD(lParam), height = HIWORD(lParam);
        if (app.video && width && height) {
            MoveWindow(app.video, 0, 0, static_cast<int>(width), static_cast<int>(height), TRUE);
            // window: mpv sigue al HWND solo. composition: hay que decírselo; se registra si la swapchain lo sigue.
            if (app.mpv && app.options.mode == Mode::composition) {
                std::string size = std::to_string(width) + "x" + std::to_string(height);
                mpv_set_property_string(app.mpv, "d3d11-composition-size", size.c_str());
            }
#ifdef HAVE_RENDER_D3D11
            if (app.render) requestRender(width, height);
#endif
        }
        return 0;
    }
    case WM_MPV_WAKEUP:
        drainEvents();
        return 0;
    case WM_TIMER:
        if (wParam == STATS_TIMER) printStats();
        return 0;
    case WM_KEYDOWN:
        switch (wParam) {
        case VK_SPACE: command({"cycle", "pause"}); break;
        case VK_LEFT: command({"seek", "-10"}); break;
        case VK_RIGHT: command({"seek", "10"}); break;
        case 'V': command({"cycle", "vid"}); break;
        case VK_ESCAPE: DestroyWindow(hwnd); break;
        }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

Options parse(int argc, char **argv) {
    Options options;
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };
        if (arg == "--mode") {
            std::string mode = next();
            options.mode = mode == "composition" ? Mode::composition : mode == "render" ? Mode::render : Mode::window;
        } else if (arg == "--live") {
            options.live = true;
        } else if (arg == "--hwdec") {
            options.hwdec = next();
        } else if (arg == "-o") {
            std::string pair = next();
            size_t eq = pair.find('=');
            if (eq != std::string::npos) options.extra.push_back({pair.substr(0, eq), pair.substr(eq + 1)});
        } else {
            options.url = arg;
        }
    }
    return options;
}

} // namespace

int main(int argc, char **argv) {
    app.options = parse(argc, argv);
    if (app.options.url.empty()) {
        std::fprintf(stderr, "uso: mpvwin [--mode window|composition|render] [--live] [--hwdec H] [-o nombre=valor]... URL\n");
        return 2;
    }
#ifndef HAVE_RENDER_D3D11
    if (app.options.mode == Mode::render) {
        std::fprintf(stderr, "--mode render necesita las cabeceras de mpv 0.42 (API cliente 2.6, render_d3d11.h)\n");
        return 2;
    }
#endif
    std::fprintf(stderr, "libmpv API %lu.%lu\n", mpv_client_api_version() >> 16, mpv_client_api_version() & 0xffff);
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW windowClass{};
    windowClass.lpfnWndProc = windowProc;
    windowClass.hInstance = instance;
    windowClass.hCursor = LoadCursor(nullptr, IDC_ARROW);
    windowClass.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    windowClass.lpszClassName = L"GlasstubeMPV";
    RegisterClassW(&windowClass);
    // El hijo no pinta nada (mpv o la swapchain lo cubren) ni toma el teclado (va a la ventana principal).
    WNDCLASSW videoClass{};
    videoClass.lpfnWndProc = DefWindowProcW;
    videoClass.hInstance = instance;
    videoClass.lpszClassName = L"GlasstubeMPVVideo";
    RegisterClassW(&videoClass);

    DWORD exStyle = app.options.mode == Mode::composition ? WS_EX_NOREDIRECTIONBITMAP : 0;
    app.window = CreateWindowExW(exStyle, windowClass.lpszClassName, L"Glasstube · mpv", WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
                                 CW_USEDEFAULT, CW_USEDEFAULT, 1280, 760, nullptr, nullptr, instance, nullptr);
    SIZE size = clientSize(app.window);
    app.video = CreateWindowExW(0, videoClass.lpszClassName, L"", WS_CHILD | WS_VISIBLE | WS_DISABLED, 0, 0,
                                size.cx, size.cy, app.window, nullptr, instance, nullptr);
    ShowWindow(app.window, SW_SHOWDEFAULT);
    UpdateWindow(app.window);

    setUpMPV();
    SetTimer(app.window, STATS_TIMER, 2000, nullptr);

    MSG message;
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
#ifdef HAVE_RENDER_D3D11
    stopRender();
#endif
    mpv_terminate_destroy(app.mpv);
    return 0;
}
