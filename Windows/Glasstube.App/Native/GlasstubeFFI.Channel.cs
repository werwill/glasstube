using System.Runtime.InteropServices;
using Glasstube.Models;

namespace Glasstube.Native;

// Canales, listas y páginas siguientes (Channel.swift en GlasstubeFFI).
public static partial class GlasstubeFFI
{
    [DllImport(Dll)] static extern unsafe void gt_channel(byte* channelId, byte* tab, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_playlist(byte* playlistId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_feed_more(byte* feed, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);

    /// <summary>Un canal con una pestaña ("videos", "shorts", "live", "playlists").</summary>
    public static unsafe Task<ChannelInfo> Channel(string channelId, string tab) => Call<ChannelInfo>(context =>
    {
        fixed (byte* id = Utf8(channelId), t = Utf8(tab)) gt_channel(id, t, &OnReply, context);
    });

    public static unsafe Task<PlaylistInfo> Playlist(string playlistId) => Call<PlaylistInfo>(context =>
    {
        fixed (byte* id = Utf8(playlistId)) gt_playlist(id, &OnReply, context);
    });

    public static unsafe Task<FeedMore> MoreOf(string feed) => Call<FeedMore>(context =>
    {
        fixed (byte* f = Utf8(feed)) gt_feed_more(f, &OnReply, context);
    });

    /// <summary>Una colección con carga incremental que sigue un <paramref name="feed"/> de la FFI.</summary>
    public static FeedCollection Collection(List<VideoCard> first, string? feed)
    {
        var next = feed;
        return new FeedCollection(first, next != null, async () =>
        {
            if (next == null) return new FeedPage([], false, null, false);
            var more = await MoreOf(next);
            next = more.Feed;
            return new FeedPage(more.Items, more.HasMore && next != null, null, false);
        });
    }
}
