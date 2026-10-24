namespace Glasstube.Models;

// Lo que el reproductor recibe de la parte 0.3 de GlasstubeFFI (Quality.swift y Captions.swift).

/// <summary>Una altura que trae el cliente elegido ("1080p60").</summary>
public sealed record QualityOption(int Height, int? Fps, string Label);

/// <summary>Pista de audio de un video doblado.</summary>
public sealed record AudioTrackOption(string Id, string Name, bool IsDefault);

/// <summary>Pista de subtítulos (WebVTT).</summary>
public sealed record CaptionTrackInfo(string LanguageCode, string Name, string Title, bool IsAutomatic, string Url);

public sealed record CaptionsInfo(string VideoId, List<CaptionTrackInfo> Tracks);

