using System.Runtime.InteropServices;
using System.Text.Json;
using Glasstube.Models;

namespace Glasstube.Native;

// La cuenta en el reproductor: estado de me gusta y suscripción, votos de Return YouTube Dislike y las acciones
// (Account.swift en GlasstubeFFI).
public static partial class GlasstubeFFI
{
    [DllImport(Dll)] static extern unsafe void gt_video_account(byte* videoId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_set_like(byte* videoId, int status, int previous, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_subscribe(byte* channelId, int subscribe, byte* parameters, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_subscription_state(byte* channelId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);

    public static unsafe Task<VideoAccountInfo> VideoAccount(string videoId) => Call<VideoAccountInfo>(context =>
    {
        fixed (byte* id = Utf8(videoId)) gt_video_account(id, &OnReply, context);
    });

    /// <summary>Me gusta (1), no me gusta (-1) o ninguno (0); <paramref name="previous"/> es el que había.</summary>
    public static unsafe Task<JsonElement> SetLike(string videoId, int status, int previous) => Call<JsonElement>(context =>
    {
        fixed (byte* id = Utf8(videoId)) gt_set_like(id, status, previous, &OnReply, context);
    });

    public static unsafe Task<JsonElement> Subscribe(string channelId, bool subscribe, string? parameters) => Call<JsonElement>(context =>
    {
        fixed (byte* id = Utf8(channelId), p = Utf8(parameters))
            gt_subscribe(id, subscribe ? 1 : 0, parameters == null ? null : p, &OnReply, context);
    });

    public static unsafe Task<SubscriptionState> SubscriptionStateOf(string channelId) => Call<SubscriptionState>(context =>
    {
        fixed (byte* id = Utf8(channelId)) gt_subscription_state(id, &OnReply, context);
    });
}
