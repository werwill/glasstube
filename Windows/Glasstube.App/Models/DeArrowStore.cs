using Glasstube.Native;
using Microsoft.UI.Dispatching;

namespace Glasstube.Models;

/// <summary>
/// Títulos y miniaturas de DeArrow para las tarjetas y el reproductor (como DeArrowStore en GlasstubeCore). Cada tarjeta
/// pide el de su video al pintarse; los pedidos se juntan 150 ms y van en una sola llamada. Con el ajuste apagado no se
/// pide nada.
/// </summary>
public sealed class DeArrowStore
{
    public static DeArrowStore Shared { get; } = new();

    readonly Dictionary<string, DeArrowItem> brandings = [];
    readonly HashSet<string> requested = [];
    readonly List<string> pending = [];
    DispatcherQueueTimer? flush;

    /// <summary>Llegó lo de DeArrow de estos videos.</summary>
    public event EventHandler<IReadOnlySet<string>>? Updated;

    static bool Active => AppSettings.Shared.DeArrowShowsTitles || AppSettings.Shared.DeArrowShowsThumbnails;

    /// <summary>Pide lo de un video (una vez por sesión). Desde el hilo de la interfaz.</summary>
    public void Request(string? videoId)
    {
        if (!Active || string.IsNullOrEmpty(videoId) || CaptureMode.Enabled || !requested.Add(videoId)) return;
        pending.Add(videoId);
        if (flush == null)
        {
            flush = DispatcherQueue.GetForCurrentThread().CreateTimer();
            flush.Interval = TimeSpan.FromMilliseconds(150);
            flush.IsRepeating = false;
            flush.Tick += async (_, _) => await Flush();
        }
        if (!flush.IsRunning) flush.Start();
    }

    async Task Flush()
    {
        while (pending.Count > 0)
        {
            // DeArrow acepta varios por consulta; de 50 en 50 para no hacer URLs enormes.
            var ids = pending.Take(50).ToList();
            pending.RemoveRange(0, ids.Count);
            try
            {
                await App.Ready;
                var info = await GlasstubeFFI.DeArrow(ids);
                foreach (var item in info.Items) brandings[item.VideoId] = item;
                if (info.Items.Count > 0) Updated?.Invoke(this, info.Items.Select(i => i.VideoId).ToHashSet());
            }
            catch (Exception error)
            {
                GlasstubeFFI.Log("app", $"DeArrow: {error.Message}");
            }
        }
    }

    /// <summary>El título que se muestra: el de la comunidad si está activado y lo hay; si no, el de YouTube.</summary>
    public string Title(string? videoId, string fallback) =>
        AppSettings.Shared.DeArrowShowsTitles && videoId != null && brandings.TryGetValue(videoId, out var item)
        && !string.IsNullOrWhiteSpace(item.Title) ? item.Title! : fallback;

    /// <summary>La miniatura de la comunidad (la genera el servidor de DeArrow), o null.</summary>
    public string? Thumbnail(string? videoId) =>
        AppSettings.Shared.DeArrowShowsThumbnails && videoId != null && brandings.TryGetValue(videoId, out var item)
            ? item.Thumbnail : null;
}
