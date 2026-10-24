using Glasstube.Native;

namespace Glasstube.Models;

/// <summary>
/// Suscripciones compartidas por el panel lateral (canales y contador de no vistos), la Bandeja y el Inicio: se piden
/// una vez a la FFI y se guardan aquí con el estado local de cada video (visto, archivado, Ver más tarde).
/// </summary>
public sealed class SubscriptionsStore
{
    public static SubscriptionsStore Shared { get; } = new();

    Task? loading;

    public List<VideoCard> Items { get; } = [];
    public List<SubscribedChannel> Channels { get; private set; } = [];
    public List<ChannelGroupInfo> Groups { get; private set; } = [];
    public List<VideoCard> WatchLater { get; private set; } = [];
    public HashSet<string> Seen { get; private set; } = [];
    public HashSet<string> Archived { get; private set; } = [];
    public bool HasMore { get; private set; }
    public bool IsLoaded { get; private set; }
    /// <summary>Por qué no hay suscripciones (sin sesión, error de red…), o null.</summary>
    public string? Error { get; private set; }

    /// <summary>Cambió algo (carga, más videos, visto/archivado/Ver más tarde).</summary>
    public event EventHandler? Changed;

    /// <summary>Carga si aún no se hizo (o de nuevo con <paramref name="force"/>).</summary>
    public Task LoadAsync(bool force = false)
    {
        if (loading == null || force || (loading.IsCompleted && !IsLoaded)) loading = Load();
        return loading;
    }

    async Task Load()
    {
        await App.Ready;
        var library = GlasstubeFFI.Library();
        try
        {
            var page = await GlasstubeFFI.Subscriptions();
            Items.Clear();
            Items.AddRange(page.Items);
            Channels = page.Channels;
            Groups = page.Groups;
            HasMore = page.HasMore;
            Error = null;
            IsLoaded = true;
        }
        catch (Exception error)
        {
            Error = error.Message;
            GlasstubeFFI.Log("app", $"Suscripciones: {error.Message}");
        }
        try
        {
            var info = await library;
            Seen = [.. info.Seen];
            Archived = [.. info.Archived];
            WatchLater = info.WatchLater;
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"biblioteca: {error.Message}");
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    bool loadingMore;

    /// <summary>La página siguiente de Suscripciones. Devuelve cuántos videos llegaron.</summary>
    public async Task<int> LoadMoreAsync()
    {
        if (!HasMore || loadingMore) return 0;
        loadingMore = true;
        try
        {
            var page = await GlasstubeFFI.SubscriptionsMore();
            var known = Items.Select(i => i.Id).ToHashSet();
            var fresh = page.Items.Where(i => known.Add(i.Id)).ToList();
            Items.AddRange(fresh);
            HasMore = page.HasMore;
            Changed?.Invoke(this, EventArgs.Empty);
            return fresh.Count;
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"Suscripciones (más): {error.Message}");
            HasMore = false;
            return 0;
        }
        finally
        {
            loadingMore = false;
        }
    }

    public bool IsSeen(VideoCard video) => Seen.Contains(video.Id);
    public bool IsArchived(VideoCard video) => Archived.Contains(video.Id);
    public bool IsInWatchLater(VideoCard video) => WatchLater.Any(v => v.Id == video.Id);

    /// <summary>Videos de la bandeja (sin archivar) de un canal o de todos (null).</summary>
    public IEnumerable<VideoCard> Inbox(Func<VideoCard, bool>? filter = null) =>
        Items.Where(v => !Archived.Contains(v.Id) && (filter?.Invoke(v) ?? true));

    public int UnseenCount(Func<VideoCard, bool>? filter = null) => Inbox(filter).Count(v => !Seen.Contains(v.Id));

    public async Task SetSeen(VideoCard video, bool seen)
    {
        if (Seen.Contains(video.Id) == seen) return;
        if (seen) Seen.Add(video.Id); else Seen.Remove(video.Id);
        Changed?.Invoke(this, EventArgs.Empty);
        try { await GlasstubeFFI.SetInbox(video.Id, seen: seen); }
        catch (Exception error) { GlasstubeFFI.Log("app", $"visto: {error.Message}"); }
    }

    public async Task SetArchived(VideoCard video, bool archived)
    {
        if (Archived.Contains(video.Id) == archived) return;
        if (archived) Archived.Add(video.Id); else Archived.Remove(video.Id);
        Changed?.Invoke(this, EventArgs.Empty);
        try { await GlasstubeFFI.SetInbox(video.Id, archived: archived); }
        catch (Exception error) { GlasstubeFFI.Log("app", $"archivar: {error.Message}"); }
    }

    /// <summary>Pone o quita de Ver más tarde; devuelve si quedó dentro.</summary>
    public async Task<bool> ToggleWatchLater(VideoCard video)
    {
        try
        {
            var inList = await GlasstubeFFI.ToggleWatchLater(video);
            if (inList) { if (!IsInWatchLater(video)) WatchLater.Insert(0, video); }
            else WatchLater.RemoveAll(v => v.Id == video.Id);
            Changed?.Invoke(this, EventArgs.Empty);
            return inList;
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"Ver más tarde: {error.Message}");
            return IsInWatchLater(video);
        }
    }
}
