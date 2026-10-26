using System.Runtime.InteropServices;
using System.Text.Json;
using Glasstube.Models;

namespace Glasstube.Native;

// Historial y Biblioteca: quitar del historial local y la Biblioteca de la cuenta (LibraryPages.swift en GlasstubeFFI).
public static partial class GlasstubeFFI
{
    [DllImport(Dll)] static extern unsafe void gt_history_remove(byte* videoId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_history_clear(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_account_library(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);

    public static unsafe Task<JsonElement> RemoveFromHistory(string videoId) => Call<JsonElement>(context =>
    {
        fixed (byte* id = Utf8(videoId)) gt_history_remove(id, &OnReply, context);
    });

    public static unsafe Task<JsonElement> ClearHistory() => Call<JsonElement>(context => gt_history_clear(&OnReply, context));

    public static unsafe Task<AccountLibrary> AccountLibrary() => Call<AccountLibrary>(context => gt_account_library(&OnReply, context));
}
