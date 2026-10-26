namespace Glasstube.Models;

// Lo que devuelve la parte de cuenta de GlasstubeFFI (Account.swift).

/// <summary>Estado de la cuenta en un video, con los votos de Return YouTube Dislike.</summary>
public sealed record VideoAccountInfo(string VideoId, bool SignedIn, string? LikeStatus, bool? IsSubscribed,
                                      string? SubscribeParams, string? ChannelId, string? Channel, string? ChannelAvatar,
                                      string? Subscribers, string? LikeCountText, int? Likes, int? Dislikes);

public sealed record SubscriptionState(bool SignedIn, bool? IsSubscribed, string? Params);
