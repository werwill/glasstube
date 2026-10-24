using System.Text.Json.Serialization;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Glasstube.Models;

// Lo que el reproductor recibe de la parte 0.3 de GlasstubeFFI (Quality.swift, Captions.swift, WatchNext.swift y
// Comments.swift).

/// <summary>Una altura que trae el cliente elegido ("1080p60").</summary>
public sealed record QualityOption(int Height, int? Fps, string Label);

/// <summary>Pista de audio de un video doblado.</summary>
public sealed record AudioTrackOption(string Id, string Name, bool IsDefault);

/// <summary>Pista de subtítulos (WebVTT).</summary>
public sealed record CaptionTrackInfo(string LanguageCode, string Name, string Title, bool IsAutomatic, string Url);

public sealed record CaptionsInfo(string VideoId, List<CaptionTrackInfo> Tracks);

/// <summary>Orden de los comentarios ("Principales", "Más recientes") con su token.</summary>
public sealed record CommentSortInfo(string Title, string Token, bool IsSelected);

public sealed record WatchNextInfo(string VideoId, List<VideoCard> Suggestions, VideoCard? Next, string? CommentsToken,
                                   string? CommentsCount, List<CommentSortInfo> CommentSorts);

public sealed record CommentInfo(string Id, string Author, string? AuthorChannelId, string? Avatar, string Text,
                                 string? Published, string? Likes, int? ReplyCount, string? ReplyCountText,
                                 string? RepliesToken, bool IsPinned, bool IsHearted, bool AuthorIsChannelOwner)
{
    [JsonIgnore]
    public BitmapImage? AvatarImage => Avatar == null ? null
        : new BitmapImage(new Uri(Avatar)) { DecodePixelWidth = 32, DecodePixelType = DecodePixelType.Logical };
}

public sealed record CommentPageInfo(List<CommentInfo> Comments, string? Continuation);
