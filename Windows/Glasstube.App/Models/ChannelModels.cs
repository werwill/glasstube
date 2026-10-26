namespace Glasstube.Models;

// Canales, listas y páginas siguientes (Channel.swift y Search.swift en GlasstubeFFI).

/// <summary>Un canal y una de sus pestañas ("videos", "shorts", "live", "playlists").</summary>
public sealed record ChannelInfo(string ChannelId, string? Title, string? Handle, string? Description, string? Subscribers,
                                 string? VideoCount, string? Avatar, string? Banner, List<string> Tabs, string? Tab,
                                 List<VideoCard> Items, bool HasMore, string? Feed);

public sealed record PlaylistInfo(string PlaylistId, string? Title, List<VideoCard> Items, bool HasMore, string? Feed);

/// <summary>Más elementos de una página paginada; <see cref="Feed"/> sirve para la siguiente.</summary>
public sealed record FeedMore(List<VideoCard> Items, bool HasMore, string? Feed);

/// <summary>Un canal en los resultados de búsqueda.</summary>
public sealed record ChannelCard(string Id, string Title, string? Handle, string? Avatar, string? Subscribers);

public sealed record SearchFeed(List<VideoCard> Items, bool HasMore, string? Notice, bool SignedIn, List<ChannelCard>? Channels);

/// <summary>Lo que se pasa al navegar a la página de un canal o de una lista: el id y el nombre que ya se sabe.</summary>
public sealed record ChannelRef(string Id, string? Name);

public sealed record PlaylistRef(string Id, string? Title);

/// <summary>La Biblioteca de la cuenta: sus listas y su Ver más tarde (primera página y su feed).</summary>
public sealed record AccountLibrary(bool SignedIn, List<VideoCard> Playlists, List<VideoCard> WatchLater, string? WatchLaterFeed,
                                    string? Notice);
