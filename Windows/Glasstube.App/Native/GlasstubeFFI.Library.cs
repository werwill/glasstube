using System.Runtime.InteropServices;
using System.Text.Json;
using Glasstube.Models;

namespace Glasstube.Native;

// Suscripciones, biblioteca local, Bandeja, detalles del video (capítulos y SponsorBlock) y búsqueda: la parte 0.2 de
// la API (Cards.swift, Subscriptions.swift, Details.swift y Search.swift en GlasstubeFFI).
public static partial class GlasstubeFFI
{
    [DllImport(Dll)] static extern unsafe void gt_subscriptions(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_subscriptions_more(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_library(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_library_record(byte* card, double position, double duration, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_library_save(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_saved_position(byte* videoId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_watch_later_toggle(byte* card, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_inbox_set(byte* videoId, int seen, int archived, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_video_details(byte* videoId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_search(byte* query, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_search_more(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);

    static byte[] CardJson(VideoCard card) => Utf8(JsonSerializer.Serialize(card, Outgoing));

    public static unsafe Task<SubscriptionsPage> Subscriptions() => Call<SubscriptionsPage>(context => gt_subscriptions(&OnReply, context));

    public static unsafe Task<FeedPage> SubscriptionsMore() => Call<FeedPage>(context => gt_subscriptions_more(&OnReply, context));

    public static unsafe Task<LibraryInfo> Library() => Call<LibraryInfo>(context => gt_library(&OnReply, context));

    /// <summary>Guarda la posición de un video en el historial local.</summary>
    public static unsafe Task<JsonElement> RecordPlayback(VideoCard card, double position, double duration) => Call<JsonElement>(context =>
    {
        fixed (byte* json = CardJson(card)) gt_library_record(json, position, duration, &OnReply, context);
    });

    /// <summary>Escribe la biblioteca en disco ya (al salir del reproductor o cerrar la app).</summary>
    public static unsafe Task<JsonElement> SaveLibrary() => Call<JsonElement>(context => gt_library_save(&OnReply, context));

    public static unsafe Task<SavedPosition> SavedPositionOf(string videoId) => Call<SavedPosition>(context =>
    {
        fixed (byte* id = Utf8(videoId)) gt_saved_position(id, &OnReply, context);
    });

    /// <summary>Pone o quita de Ver más tarde; devuelve si quedó dentro.</summary>
    public static async Task<bool> ToggleWatchLater(VideoCard card)
    {
        var reply = await ToggleWatchLaterRaw(card);
        return reply.GetProperty("inWatchLater").GetBoolean();
    }

    static unsafe Task<JsonElement> ToggleWatchLaterRaw(VideoCard card) => Call<JsonElement>(context =>
    {
        fixed (byte* json = CardJson(card)) gt_watch_later_toggle(json, &OnReply, context);
    });

    /// <summary>Visto / archivado en la Bandeja (null = no cambiar).</summary>
    public static unsafe Task<InboxFlags> SetInbox(string videoId, bool? seen = null, bool? archived = null) => Call<InboxFlags>(context =>
    {
        fixed (byte* id = Utf8(videoId))
            gt_inbox_set(id, seen is null ? -1 : seen.Value ? 1 : 0, archived is null ? -1 : archived.Value ? 1 : 0, &OnReply, context);
    });

    public static unsafe Task<VideoDetails> Details(string videoId) => Call<VideoDetails>(context =>
    {
        fixed (byte* id = Utf8(videoId)) gt_video_details(id, &OnReply, context);
    });

    public static unsafe Task<FeedPage> Search(string query) => Call<FeedPage>(context =>
    {
        fixed (byte* q = Utf8(query)) gt_search(q, &OnReply, context);
    });

    public static unsafe Task<FeedPage> SearchMore() => Call<FeedPage>(context => gt_search_more(&OnReply, context));
}
