using System.Runtime.InteropServices;
using Glasstube.Models;

namespace Glasstube.Native;

// Calidad y pista de audio y subtítulos del reproductor: la parte 0.3 de la API (Quality.swift y Captions.swift en
// GlasstubeFFI).
public static partial class GlasstubeFFI
{
    [DllImport(Dll)] static extern unsafe void gt_resolve_stream_with(byte* videoId, int maxHeight, byte* audioTrackId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_captions(byte* videoId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);

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
}
