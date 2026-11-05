using System.Runtime.InteropServices;
using System.Text.Json;
using Glasstube.Models;

namespace Glasstube.Native;

// Hojas de miniaturas, DeArrow, enlaces pegados y búsqueda con filtros (Polish.swift en GlasstubeFFI, app 0.4.0).
public static partial class GlasstubeFFI
{
    [DllImport(Dll)] static extern unsafe void gt_storyboard(byte* videoId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_dearrow(byte* ids, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_parse_link(byte* text, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_search_filtered(byte* query, byte* filter, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);

    public static unsafe Task<StoryboardInfo> Storyboard(string videoId) => Call<StoryboardInfo>(context =>
    {
        fixed (byte* id = Utf8(videoId)) gt_storyboard(id, &OnReply, context);
    });

    public static unsafe Task<DeArrowInfo> DeArrow(IReadOnlyCollection<string> videoIds) => Call<DeArrowInfo>(context =>
    {
        fixed (byte* ids = Utf8(JsonSerializer.Serialize(videoIds))) gt_dearrow(ids, &OnReply, context);
    });

    /// <summary>El enlace de YouTube que hay en un texto (falla si no hay).</summary>
    public static unsafe Task<LinkInfo> ParseLink(string text) => Call<LinkInfo>(context =>
    {
        fixed (byte* t = Utf8(text)) gt_parse_link(t, &OnReply, context);
    });

    /// <summary>Como <see cref="Search"/>, con filtros (null o vacío = sin filtros).</summary>
    public static unsafe Task<SearchFeed> Search(string query, SearchFilterInfo? filter) => Call<SearchFeed>(context =>
    {
        var json = filter is { IsEmpty: false } ? JsonSerializer.Serialize(filter, Outgoing) : null;
        fixed (byte* q = Utf8(query), f = Utf8(json)) gt_search_filtered(q, json == null ? null : f, &OnReply, context);
    });
}
