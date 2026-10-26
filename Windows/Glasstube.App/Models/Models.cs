using System.Collections.ObjectModel;
using System.Text.Json.Serialization;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;

namespace Glasstube.Models;

// Lo que devuelve GlasstubeFFI en JSON (ver GlasstubeFFI.swift).

public sealed record InitInfo(string Language, string Region, string Version);

public sealed record AccountInfo(string Name, string? Byline, string? Avatar, bool IsBrand);

public sealed record SessionInfo(bool SignedIn, AccountInfo? Selected, int AccountCount);

public sealed class VideoCard
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public string? Channel { get; set; }
    public string? ChannelId { get; set; }
    public string? Thumbnail { get; set; }
    public string? Duration { get; set; }
    public string? Views { get; set; }
    public string? Published { get; set; }
    public string Subtitle { get; set; } = "";
    public bool IsLive { get; set; }
    public string? Shelf { get; set; }
    /// <summary>Miniatura grande (maxresdefault; puede no existir: caer a <see cref="Thumbnail"/>).</summary>
    public string? ThumbnailLarge { get; set; }
    /// <summary>Foto del canal, si se sabe.</summary>
    public string? Avatar { get; set; }
    public int? DurationSeconds { get; set; }
    /// <summary>Fecha aproximada de publicación (segundos Unix).</summary>
    public double? PublishedAt { get; set; }
    /// <summary>Posición guardada (segundos) y fracción vista (0–1).</summary>
    public double? Position { get; set; }
    public double? Progress { get; set; }
    /// <summary>Si es una lista (o mix), su id: se abre en lugar de reproducirse.</summary>
    public string? PlaylistId { get; set; }

    [JsonIgnore]
    public bool IsPlaylist => !string.IsNullOrEmpty(PlaylistId);

    BitmapImage? image;

    /// <summary>Miniatura decodificada al ancho de la tarjeta (se crea la primera vez que se dibuja).</summary>
    [JsonIgnore]
    public BitmapImage? ThumbnailImage => image ??= Thumbnail == null ? null
        : new BitmapImage(new Uri(Thumbnail)) { DecodePixelWidth = 480, DecodePixelType = DecodePixelType.Logical };

    /// <summary>"Vistas · fecha" bajo el canal.</summary>
    [JsonIgnore]
    public string Meta => string.Join(" · ", new[] { Views, Published }.Where(s => !string.IsNullOrWhiteSpace(s)));

    [JsonIgnore]
    public bool HasDuration => !string.IsNullOrEmpty(Duration);

    /// <summary>Nombre accesible de la tarjeta (lectores de pantalla y UI Automation).</summary>
    public override string ToString() => Title;
}

public sealed record FeedPage(List<VideoCard> Items, bool HasMore, string? Notice, bool SignedIn);

public sealed record SubscribedChannel(string Id, string Name, string? Avatar, bool HasNew);

public sealed record ChannelGroupInfo(string Id, string Title, List<string> Channels);

public sealed record SubscriptionsFeed(List<VideoCard> Items, bool HasMore, List<SubscribedChannel> Channels,
                                       List<ChannelGroupInfo> Groups, string? Notice, bool SignedIn);

public sealed record LibraryInfo(List<VideoCard> History, List<VideoCard> ContinueWatching, List<VideoCard> WatchLater,
                                 List<string> Seen, List<string> Archived);

public sealed record InboxFlags(bool Seen, bool Archived);

public sealed record SavedPosition(double Position, double Duration);

public sealed record ChapterInfo(string Title, double Start);

public sealed record SponsorSegmentInfo(double Start, double End, string Category, string Title);

public sealed record VideoDetails(string VideoId, string? Title, string? Description, string? Author, string? ChannelId,
                                  string? Avatar, string? Views, string? Published, List<ChapterInfo> Chapters,
                                  List<SponsorSegmentInfo> Segments);

public sealed record StreamTrack(string Url, int Itag, string Codec, string Label, int? Height);

public sealed record StreamInfo(string VideoId, string? Title, string? Author, string? Client, StreamTrack? Video,
                                StreamTrack? Audio, string? Hls, double? DurationSeconds, string UserAgent,
                                Dictionary<string, string> Headers, List<QualityOption>? Qualities = null,
                                List<AudioTrackOption>? AudioTracks = null, string? AudioTrackId = null);

/// <summary>
/// Inicio con carga incremental: GridView pide más al acercarse al final (ISupportIncrementalLoading) y esto llama a
/// <c>gt_home_more</c>.
/// </summary>
public sealed class FeedCollection : ObservableCollection<VideoCard>, ISupportIncrementalLoading
{
    readonly Func<Task<FeedPage>> loadMore;
    bool loading;

    public FeedCollection(IEnumerable<VideoCard> first, bool hasMore, Func<Task<FeedPage>> loadMore) : base(first)
    {
        HasMoreItems = hasMore;
        this.loadMore = loadMore;
    }

    public bool HasMoreItems { get; private set; }

    public IAsyncOperation<LoadMoreItemsResult> LoadMoreItemsAsync(uint count) => Load().AsAsyncOperation();

    async Task<LoadMoreItemsResult> Load()
    {
        if (loading || !HasMoreItems) return new LoadMoreItemsResult { Count = 0 };
        loading = true;
        try
        {
            var page = await loadMore();
            foreach (var item in page.Items) Add(item);
            HasMoreItems = page.HasMore;
            return new LoadMoreItemsResult { Count = (uint)page.Items.Count };
        }
        catch
        {
            HasMoreItems = false;
            return new LoadMoreItemsResult { Count = 0 };
        }
        finally
        {
            loading = false;
        }
    }
}
