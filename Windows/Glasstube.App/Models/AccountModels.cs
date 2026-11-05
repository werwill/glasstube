namespace Glasstube.Models;

// Lo que devuelve la parte de cuenta de GlasstubeFFI (Account.swift).

/// <summary>Estado de la cuenta en un video, con los votos de Return YouTube Dislike.</summary>
public sealed record VideoAccountInfo(string VideoId, bool SignedIn, string? LikeStatus, bool? IsSubscribed,
                                      string? SubscribeParams, string? ChannelId, string? Channel, string? ChannelAvatar,
                                      string? Subscribers, string? LikeCountText, int? Likes, int? Dislikes);

public sealed record SubscriptionState(bool SignedIn, bool? IsSubscribed, string? Params);

// Iniciar y cerrar sesión (SignIn.swift).

public sealed record SavedAccount(string Id, string Name, string? Byline, string? Avatar, bool IsBrand, bool IsSelected);

public sealed record AccountList(bool SignedIn, List<SavedAccount> Accounts)
{
    public SavedAccount? Selected => Accounts.FirstOrDefault(a => a.IsSelected);
}

/// <summary>El código que se escribe en <see cref="VerificationUrl"/> (youtube.com/activate); vence en <see cref="ExpiresIn"/> s.</summary>
public sealed record SignInCode(string UserCode, string VerificationUrl, int ExpiresIn);
