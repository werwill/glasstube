using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Controls;

namespace Glasstube.Native;

/// <summary>Estado del reproductor que rellena <c>mpvb_poll</c> (MPVBridge.h).</summary>
[StructLayout(LayoutKind.Sequential)]
public struct MpvState
{
    public double Position;
    public double Duration;
    public double Buffered;
    public double Volume;
    public int Paused;
    public int Idle;
    public int Buffering;
    public int HasVideo;
    public int Ended;
    public int Error;
}

/// <summary>libmpv dentro de un SwapChainPanel (MPVBridge.dll). Todo desde el hilo de la interfaz.</summary>
public sealed unsafe class MpvPlayer : IDisposable
{
    const string Dll = "MPVBridge.dll";

    [DllImport(Dll)] static extern IntPtr mpvb_create(IntPtr panel, int width, int height, float scale);
    [DllImport(Dll)] static extern int mpvb_load(IntPtr player, [MarshalAs(UnmanagedType.LPUTF8Str)] string url,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? audioUrl, [MarshalAs(UnmanagedType.LPUTF8Str)] string? userAgent,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? headers, double startSeconds);
    [DllImport(Dll)] static extern void mpvb_poll(IntPtr player, out MpvState state);
    [DllImport(Dll)] static extern void mpvb_resize(IntPtr player, int width, int height, float scale);
    [DllImport(Dll)] static extern void mpvb_set_pause(IntPtr player, int paused);
    [DllImport(Dll)] static extern void mpvb_seek(IntPtr player, double seconds);
    [DllImport(Dll)] static extern void mpvb_set_volume(IntPtr player, double volume);
    [DllImport(Dll)] static extern IntPtr mpvb_last_error(IntPtr player);
    [DllImport(Dll)] static extern void mpvb_destroy(IntPtr player);
    [DllImport(Dll)] static extern unsafe void mpvb_set_logger(delegate* unmanaged<byte*, void> callback);

    [UnmanagedCallersOnly]
    static unsafe void OnLog(byte* line) => GlasstubeFFI.Log("mpv", Marshal.PtrToStringUTF8((IntPtr)line) ?? "");

    static unsafe MpvPlayer() => mpvb_set_logger(&OnLog);

    IntPtr handle;

    MpvPlayer(IntPtr handle) => this.handle = handle;

    /// <summary>Crea mpv sobre el panel. Tamaño en píxeles físicos.</summary>
    public static MpvPlayer? Create(SwapChainPanel panel, int width, int height, float scale)
    {
        // IInspectable* del panel (con una referencia nuestra; el puente se queda con la suya de ISwapChainPanelNative).
        var pointer = WinRT.MarshalInspectable<SwapChainPanel>.FromManaged(panel);
        try
        {
            var handle = mpvb_create(pointer, width, height, scale);
            return handle == IntPtr.Zero ? null : new MpvPlayer(handle);
        }
        finally
        {
            Marshal.Release(pointer);
        }
    }

    public int Load(string url, string? audioUrl, string? userAgent, IReadOnlyDictionary<string, string>? headers, double start = 0)
    {
        var lines = headers == null ? null
            : string.Join("\n", headers.Where(h => !h.Key.Equals("User-Agent", StringComparison.OrdinalIgnoreCase))
                                       .Select(h => $"{h.Key}: {h.Value}"));
        return mpvb_load(handle, url, audioUrl, userAgent, lines, start);
    }

    public MpvState Poll()
    {
        mpvb_poll(handle, out var state);
        return state;
    }

    public void Resize(int width, int height, float scale) => mpvb_resize(handle, width, height, scale);
    public void SetPause(bool paused) => mpvb_set_pause(handle, paused ? 1 : 0);
    public void Seek(double seconds) => mpvb_seek(handle, seconds);
    public void SetVolume(double volume) => mpvb_set_volume(handle, volume);
    public string LastError => Marshal.PtrToStringUTF8(mpvb_last_error(handle)) ?? "";

    public void Dispose()
    {
        if (handle == IntPtr.Zero) return;
        mpvb_destroy(handle);
        handle = IntPtr.Zero;
    }
}
