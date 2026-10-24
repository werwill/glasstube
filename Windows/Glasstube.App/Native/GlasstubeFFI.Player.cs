using System.Runtime.InteropServices;
using Glasstube.Models;

namespace Glasstube.Native;

// Calidad y pista de audio, subtítulos, sugeridos y comentarios del reproductor: la parte 0.3 de la API (Quality.swift,
// Captions.swift, WatchNext.swift y Comments.swift en GlasstubeFFI).
public static partial class GlasstubeFFI
{
    [DllImport(Dll)] static extern unsafe void gt_resolve_stream_with(byte* videoId, int maxHeight, byte* audioTrackId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_captions(byte* videoId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_watch_next(byte* videoId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_comments(byte* token, int replies, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);

    /// <summary>Como <see cref="ResolveStream"/> con una pista de audio (null = la predeterminada).</summary>
    public static unsafe Task<StreamInfo> ResolveStream(string videoId, int maxHeight, string? audioTrackId) => Call<StreamInfo>(context =>
    {
        fixed (byte* id = Utf8(videoId), audio = Utf8(audioTrackId))
            gt_resolve_stream_with(id, maxHeight, audioTrackId == null ? null : audio, &OnReply, context);
    });

    public static unsafe Task<CaptionsInfo> Captions(string videoId) => Call<CaptionsInfo>(context =>
    {
        fixed (byte* id = Utf8(videoId)) gt_captions(id, &OnReply, context);
    });

    public static unsafe Task<WatchNextInfo> WatchNext(string videoId) => Call<WatchNextInfo>(context =>
    {
        fixed (byte* id = Utf8(videoId)) gt_watch_next(id, &OnReply, context);
    });

    /// <summary>Una página de comentarios (o, con <paramref name="replies"/>, las respuestas de un comentario).</summary>
    public static unsafe Task<CommentPageInfo> Comments(string token, bool replies = false) => Call<CommentPageInfo>(context =>
    {
        fixed (byte* t = Utf8(token)) gt_comments(t, replies ? 1 : 0, &OnReply, context);
    });
}
