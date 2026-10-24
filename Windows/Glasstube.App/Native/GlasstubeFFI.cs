using System.Runtime.InteropServices;
using System.Text.Json;
using Glasstube.Models;

namespace Glasstube.Native;

/// <summary>
/// P/Invoke a GlasstubeFFI.dll (Windows/GlasstubeFFI/include/GlasstubeFFI.h). Cada llamada asíncrona pasa un
/// GCHandle de su TaskCompletionSource como contexto; el callback llega dentro de <see cref="Pump"/>, en el hilo de la
/// interfaz, y la cadena JSON solo vale durante el callback (aquí se copia).
/// </summary>
public static partial class GlasstubeFFI
{
    const string Dll = "GlasstubeFFI.dll";

    [DllImport(Dll)] static extern unsafe void gt_init(byte* language, byte* region, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_pump();
    [DllImport(Dll)] static extern unsafe void gt_shutdown();
    [DllImport(Dll)] static extern unsafe byte* gt_version();
    [DllImport(Dll)] static extern unsafe void gt_free(byte* pointer);
    [DllImport(Dll)] static extern unsafe void gt_log(byte* source, byte* message);
    [DllImport(Dll)] static extern unsafe byte* gt_log_directory();
    [DllImport(Dll)] static extern unsafe void gt_load_session(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_home(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_home_more(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_resolve_stream(byte* videoId, int maxHeight, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);

    public static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

    [UnmanagedCallersOnly]
    static unsafe void OnReply(IntPtr context, int status, byte* json)
    {
        var handle = GCHandle.FromIntPtr(context);
        var source = (TaskCompletionSource<string>)handle.Target!;
        handle.Free();
        var text = json == null ? "{}" : Marshal.PtrToStringUTF8((IntPtr)json) ?? "{}";
        if (status == 0)
        {
            source.TrySetResult(text);
        }
        else
        {
            string message;
            try { message = JsonDocument.Parse(text).RootElement.GetProperty("error").GetString() ?? text; }
            catch { message = text; }
            source.TrySetException(new GlasstubeException(message));
        }
    }

    /// <summary>Para mandar objetos a la DLL (VideoCard): camelCase, como los lee Swift.</summary>
    static readonly JsonSerializerOptions Outgoing = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    /// <summary>Hace una llamada con callback y devuelve su JSON ya deserializado.</summary>
    static async Task<T> Call<T>(Action<IntPtr> start)
    {
        var source = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        start(GCHandle.ToIntPtr(GCHandle.Alloc(source)));
        var text = await source.Task;
        return JsonSerializer.Deserialize<T>(text, Json)!;
    }

    static byte[] Utf8(string? value) => value == null ? new byte[] { 0 } : System.Text.Encoding.UTF8.GetBytes(value + "\0");

    public static unsafe Task<InitInfo> Init(string? language, string? region) => Call<InitInfo>(context =>
    {
        fixed (byte* l = Utf8(language), r = Utf8(region)) gt_init(l, r, &OnReply, context);
    });

    /// <summary>Vacía la cola principal de Swift (y entrega los callbacks). Desde el hilo de la interfaz.</summary>
    public static void Pump() => gt_pump();

    public static void Shutdown() => gt_shutdown();

    public static unsafe string Version()
    {
        var pointer = gt_version();
        try { return Marshal.PtrToStringUTF8((IntPtr)pointer) ?? ""; }
        finally { gt_free(pointer); }
    }

    /// <summary>Una línea en %LOCALAPPDATA%\Glasstube\logs\glasstube.log (desde cualquier hilo).</summary>
    public static unsafe void Log(string source, string message)
    {
        try
        {
            fixed (byte* s = Utf8(source), m = Utf8(message)) gt_log(s, m);
        }
        catch
        {
            // Sin la DLL no hay registro; no es motivo para caerse.
        }
    }

    public static unsafe string LogDirectory()
    {
        var pointer = gt_log_directory();
        try { return Marshal.PtrToStringUTF8((IntPtr)pointer) ?? ""; }
        finally { gt_free(pointer); }
    }

    public static unsafe Task<SessionInfo> LoadSession() => Call<SessionInfo>(context => gt_load_session(&OnReply, context));

    public static unsafe Task<FeedPage> Home() => Call<FeedPage>(context => gt_home(&OnReply, context));

    public static unsafe Task<FeedPage> HomeMore() => Call<FeedPage>(context => gt_home_more(&OnReply, context));

    public static unsafe Task<StreamInfo> ResolveStream(string videoId, int maxHeight = 1080) => Call<StreamInfo>(context =>
    {
        fixed (byte* id = Utf8(videoId)) gt_resolve_stream(id, maxHeight, &OnReply, context);
    });
}

public sealed class GlasstubeException(string message) : Exception(message);
