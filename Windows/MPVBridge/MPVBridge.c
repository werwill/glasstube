#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define MPVB_BUILD
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mpv/client.h>
#include "MPVBridge.h"

// ISwapChainPanelNative de WinUI 3 (microsoft.ui.xaml.media.dxinterop.h). Se declara aquí para no depender de la cabecera.
typedef struct ISwapChainPanelNative ISwapChainPanelNative;
typedef struct ISwapChainPanelNativeVtbl {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(ISwapChainPanelNative *, REFIID, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(ISwapChainPanelNative *);
    ULONG(STDMETHODCALLTYPE *Release)(ISwapChainPanelNative *);
    HRESULT(STDMETHODCALLTYPE *SetSwapChain)(ISwapChainPanelNative *, IDXGISwapChain *);
} ISwapChainPanelNativeVtbl;
struct ISwapChainPanelNative { const ISwapChainPanelNativeVtbl *lpVtbl; };
static const IID IID_ISwapChainPanelNative_WinUI = {0x63aad0b8, 0x7c24, 0x40ff, {0x85, 0xa8, 0x64, 0x0d, 0x94, 0x4c, 0xc3, 0x25}};

// Propiedades observadas (el `reply_userdata` de cada una).
enum { P_TIME = 1, P_DURATION, P_PAUSE, P_VOLUME, P_IDLE, P_CACHE_PAUSE, P_CACHE_DURATION, P_EOF, P_HEIGHT, P_FPS };

static mpvb_logger logger;

MPVB_API void mpvb_set_logger(mpvb_logger callback) { logger = callback; }

// Al registro de la app (si hay) y a stderr.
static void say(const char *format, ...) {
    char line[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof line, format, args);
    va_end(args);
    if (logger) logger(line);
    fprintf(stderr, "[mpvb] %s\n", line);
}

struct mpvb_player {
    mpv_handle *mpv;
    ISwapChainPanelNative *panel;
    IDXGISwapChain *attached;
    float scale;
    mpvb_state state;
    char error[512];
    int32_t height; // mpvb_video_format
    double fps;
};

static void set_option(mpvb_player *p, const char *name, const char *value) {
    int r = mpv_set_option_string(p->mpv, name, value);
    if (r < 0) say("opcion %s=%s: %s", name, value, mpv_error_string(r));
}

// Una opción de lista (audio-files, http-header-fields) con un elemento por cadena: así las comas de las URLs no
// parten nada.
static int set_list(mpvb_player *p, const char *name, const char **values, int count) {
    mpv_node *items = calloc(count > 0 ? count : 1, sizeof(mpv_node));
    for (int i = 0; i < count; i++) { items[i].format = MPV_FORMAT_STRING; items[i].u.string = (char *)values[i]; }
    mpv_node_list list = {.num = count, .values = items};
    mpv_node node = {.format = MPV_FORMAT_NODE_ARRAY, .u.list = &list};
    int r = mpv_set_option(p->mpv, name, MPV_FORMAT_NODE, &node);
    if (r < 0) say("opcion %s: %s", name, mpv_error_string(r));
    free(items);
    return r;
}

MPVB_API mpvb_player *mpvb_create(void *panel, int32_t width, int32_t height, float scale) {
    mpvb_player *p = calloc(1, sizeof *p);
    p->scale = scale > 0 ? scale : 1.0f;
    p->state.volume = 100;
    p->state.idle = 1;
    IUnknown *unk = (IUnknown *)panel;
    HRESULT hr = unk->lpVtbl->QueryInterface(unk, &IID_ISwapChainPanelNative_WinUI, (void **)&p->panel);
    if (FAILED(hr)) { say("QI ISwapChainPanelNative: 0x%08lx", hr); free(p); return NULL; }

    p->mpv = mpv_create();
    if (!p->mpv) { p->panel->lpVtbl->Release(p->panel); free(p); return NULL; }
    char size[32];
    snprintf(size, sizeof size, "%dx%d", width > 0 ? width : 640, height > 0 ? height : 360);
    set_option(p, "vo", "gpu-next");
    set_option(p, "gpu-api", "d3d11");
    set_option(p, "gpu-context", "d3d11");
    set_option(p, "d3d11-output-mode", "composition");
    set_option(p, "d3d11-composition-size", size);
    set_option(p, "force-window", "yes");
    set_option(p, "hwdec", "d3d11va,auto-safe");
    set_option(p, "keep-open", "yes");
    set_option(p, "idle", "yes");
    set_option(p, "config", "no");
    set_option(p, "osc", "no");
    set_option(p, "ytdl", "no");
    set_option(p, "input-default-bindings", "no");
    set_option(p, "cache", "yes");
    set_option(p, "demuxer-max-bytes", "150MiB");
    set_option(p, "demuxer-readahead-secs", "30");
    set_option(p, "terminal", "yes");
    set_option(p, "msg-level", "all=warn");
    int r = mpv_initialize(p->mpv);
    if (r < 0) {
        say("mpv_initialize: %s", mpv_error_string(r));
        mpv_terminate_destroy(p->mpv);
        p->panel->lpVtbl->Release(p->panel);
        free(p);
        return NULL;
    }
    mpv_request_log_messages(p->mpv, "warn");
    mpv_observe_property(p->mpv, P_TIME, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(p->mpv, P_DURATION, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(p->mpv, P_PAUSE, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(p->mpv, P_VOLUME, "volume", MPV_FORMAT_DOUBLE);
    mpv_observe_property(p->mpv, P_IDLE, "idle-active", MPV_FORMAT_FLAG);
    mpv_observe_property(p->mpv, P_CACHE_PAUSE, "paused-for-cache", MPV_FORMAT_FLAG);
    mpv_observe_property(p->mpv, P_CACHE_DURATION, "demuxer-cache-duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(p->mpv, P_EOF, "eof-reached", MPV_FORMAT_FLAG);
    mpv_observe_property(p->mpv, P_HEIGHT, "height", MPV_FORMAT_INT64);
    mpv_observe_property(p->mpv, P_FPS, "container-fps", MPV_FORMAT_DOUBLE);
    return p;
}

MPVB_API int32_t mpvb_load(mpvb_player *p, const char *url, const char *audio_url, const char *user_agent,
                           const char *headers, double start_seconds) {
    if (!p || !url) return -1;
    if (user_agent && *user_agent) set_option(p, "user-agent", user_agent);
    if (headers && *headers) {
        // "Clave: valor\nClave: valor" → una entrada por línea.
        char *copy = _strdup(headers);
        const char *lines[32];
        int count = 0;
        for (char *line = strtok(copy, "\n"); line && count < 32; line = strtok(NULL, "\n"))
            if (*line) lines[count++] = line;
        set_list(p, "http-header-fields", lines, count);
        free(copy);
    }
    if (audio_url && *audio_url) set_list(p, "audio-files", &audio_url, 1);
    if (start_seconds > 0) {
        char start[32];
        snprintf(start, sizeof start, "%.3f", start_seconds);
        set_option(p, "start", start);
    }
    p->state.error = 0;
    p->state.ended = 0;
    p->error[0] = 0;
    const char *cmd[] = {"loadfile", url, NULL};
    int r = mpv_command(p->mpv, cmd);
    say("loadfile (%s audio aparte) -> %s", audio_url && *audio_url ? "con" : "sin", mpv_error_string(r));
    if (r < 0) snprintf(p->error, sizeof p->error, "loadfile: %s", mpv_error_string(r));
    return r;
}

// El SwapChainPanel muestra 1 píxel de la swapchain por DIP; con la swapchain en píxeles físicos hay que reducirla 1/escala.
static void apply_scale(mpvb_player *p) {
    if (!p->attached) return;
    IDXGISwapChain2 *chain2 = NULL;
    if (SUCCEEDED(IDXGISwapChain_QueryInterface(p->attached, &IID_IDXGISwapChain2, (void **)&chain2))) {
        DXGI_MATRIX_3X2_F m = {1.0f / p->scale, 0, 0, 1.0f / p->scale, 0, 0};
        IDXGISwapChain2_SetMatrixTransform(chain2, &m);
        IDXGISwapChain2_Release(chain2);
    }
}

static void attach_swapchain(mpvb_player *p) {
    int64_t address = 0;
    if (mpv_get_property(p->mpv, "display-swapchain", MPV_FORMAT_INT64, &address) < 0 || !address) return;
    IDXGISwapChain *chain = (IDXGISwapChain *)(intptr_t)address;
    if (chain == p->attached) return;
    HRESULT hr = p->panel->lpVtbl->SetSwapChain(p->panel, chain);
    if (SUCCEEDED(hr)) {
        p->attached = chain;
        p->state.has_video = 1;
        apply_scale(p);
    } else {
        say("SetSwapChain: 0x%08lx", hr);
    }
}

static void property_changed(mpvb_player *p, mpv_event *e) {
    mpv_event_property *prop = e->data;
    int has = prop->format != MPV_FORMAT_NONE && prop->data;
    double d = has && prop->format == MPV_FORMAT_DOUBLE ? *(double *)prop->data : 0;
    int flag = has && prop->format == MPV_FORMAT_FLAG ? *(int *)prop->data : 0;
    switch (e->reply_userdata) {
    case P_TIME: p->state.position = d; break;
    case P_DURATION: p->state.duration = d; break;
    case P_PAUSE: p->state.paused = flag; break;
    case P_VOLUME: if (has) p->state.volume = d; break;
    case P_IDLE: p->state.idle = flag; break;
    case P_CACHE_PAUSE: p->state.buffering = flag; break;
    case P_CACHE_DURATION: p->state.buffered = d; break;
    case P_EOF: p->state.ended = flag; break;
    case P_HEIGHT: p->height = has && prop->format == MPV_FORMAT_INT64 ? (int32_t)*(int64_t *)prop->data : 0; break;
    case P_FPS: p->fps = d; break;
    }
}

MPVB_API void mpvb_poll(mpvb_player *p, mpvb_state *state) {
    if (!p) return;
    for (;;) {
        mpv_event *e = mpv_wait_event(p->mpv, 0);
        if (e->event_id == MPV_EVENT_NONE) break;
        switch (e->event_id) {
        case MPV_EVENT_PROPERTY_CHANGE: property_changed(p, e); break;
        case MPV_EVENT_VIDEO_RECONFIG: attach_swapchain(p); break;
        case MPV_EVENT_START_FILE: p->state.buffering = 1; break;
        case MPV_EVENT_PLAYBACK_RESTART: p->state.buffering = 0; break;
        case MPV_EVENT_LOG_MESSAGE: {
            mpv_event_log_message *msg = e->data;
            char text[512];
            snprintf(text, sizeof text, "%s: %s", msg->prefix, msg->text);
            size_t n = strlen(text);
            if (n && text[n - 1] == '\n') text[n - 1] = 0;
            say("%s %s", msg->level, text);
            // Solo los errores quedan como "último error" (los avisos son ruido para la interfaz).
            // "Failed to query swap chain's output information" sale siempre con una swapchain de composición (no tiene
            // salida asociada) y no afecta a nada.
            if (msg->log_level <= MPV_LOG_LEVEL_ERROR && !strstr(text, "output information"))
                snprintf(p->error, sizeof p->error, "%s", text);
            break;
        }
        case MPV_EVENT_END_FILE: {
            mpv_event_end_file *end = e->data;
            say("end-file: razón %d, error %s", end->reason, mpv_error_string(end->error));
            if (end->reason == MPV_END_FILE_REASON_ERROR) {
                p->state.error = 1;
                if (!p->error[0]) snprintf(p->error, sizeof p->error, "%s", mpv_error_string(end->error));
            } else if (end->reason == MPV_END_FILE_REASON_EOF) {
                p->state.ended = 1;
            }
            break;
        }
        default: break;
        }
    }
    attach_swapchain(p); // por si la swapchain se recrea sin VIDEO_RECONFIG
    if (state) *state = p->state;
}

MPVB_API void mpvb_resize(mpvb_player *p, int32_t width, int32_t height, float scale) {
    if (!p || width <= 0 || height <= 0) return;
    p->scale = scale > 0 ? scale : 1.0f;
    apply_scale(p);
    char size[32];
    snprintf(size, sizeof size, "%dx%d", width, height);
    mpv_set_property_string(p->mpv, "d3d11-composition-size", size);
}

MPVB_API void mpvb_set_pause(mpvb_player *p, int32_t paused) {
    if (!p) return;
    int flag = paused ? 1 : 0;
    mpv_set_property_async(p->mpv, 0, "pause", MPV_FORMAT_FLAG, &flag);
}

MPVB_API void mpvb_seek(mpvb_player *p, double seconds) {
    if (!p) return;
    char target[32];
    snprintf(target, sizeof target, "%.3f", seconds < 0 ? 0 : seconds);
    const char *cmd[] = {"seek", target, "absolute", NULL};
    mpv_command_async(p->mpv, 0, cmd);
}

MPVB_API void mpvb_set_volume(mpvb_player *p, double volume) {
    if (!p) return;
    double v = volume < 0 ? 0 : volume > 100 ? 100 : volume;
    mpv_set_property_async(p->mpv, 0, "volume", MPV_FORMAT_DOUBLE, &v);
}

MPVB_API void mpvb_video_format(mpvb_player *p, int32_t *height, double *fps) {
    if (height) *height = p ? p->height : 0;
    if (fps) *fps = p ? p->fps : 0;
}

MPVB_API const char *mpvb_last_error(mpvb_player *p) { return p ? p->error : ""; }

MPVB_API void mpvb_destroy(mpvb_player *p) {
    if (!p) return;
    if (p->panel) { p->panel->lpVtbl->SetSwapChain(p->panel, NULL); p->panel->lpVtbl->Release(p->panel); }
    if (p->mpv) mpv_terminate_destroy(p->mpv);
    free(p);
}
