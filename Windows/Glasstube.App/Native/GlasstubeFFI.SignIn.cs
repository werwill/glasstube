using System.Runtime.InteropServices;
using Glasstube.Models;

namespace Glasstube.Native;

// Iniciar y cerrar sesión: el código de youtube.com/activate, elegir cuenta y cerrar sesión (SignIn.swift en
// GlasstubeFFI).
public static partial class GlasstubeFFI
{
    [DllImport(Dll)] static extern unsafe void gt_accounts(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_sign_in_begin(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_sign_in_wait(delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern void gt_sign_in_cancel();
    [DllImport(Dll)] static extern unsafe void gt_select_account(byte* accountId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);
    [DllImport(Dll)] static extern unsafe void gt_sign_out(byte* accountId, delegate* unmanaged<IntPtr, int, byte*, void> callback, IntPtr context);

    public static unsafe Task<AccountList> Accounts() => Call<AccountList>(context => gt_accounts(&OnReply, context));

    /// <summary>Pide un código nuevo para youtube.com/activate.</summary>
    public static unsafe Task<SignInCode> BeginSignIn() => Call<SignInCode>(context => gt_sign_in_begin(&OnReply, context));

    /// <summary>Espera a que se apruebe el último código (falla si vence, lo rechazan o con <see cref="CancelSignIn"/>).</summary>
    public static unsafe Task<AccountList> WaitForSignIn() => Call<AccountList>(context => gt_sign_in_wait(&OnReply, context));

    public static void CancelSignIn() => gt_sign_in_cancel();

    public static unsafe Task<AccountList> SelectAccount(string accountId) => Call<AccountList>(context =>
    {
        fixed (byte* id = Utf8(accountId)) gt_select_account(id, &OnReply, context);
    });

    /// <summary>Cierra la sesión de Google de esa cuenta; null = todas.</summary>
    public static unsafe Task<AccountList> SignOut(string? accountId) => Call<AccountList>(context =>
    {
        fixed (byte* id = Utf8(accountId)) gt_sign_out(accountId == null ? null : id, &OnReply, context);
    });
}
