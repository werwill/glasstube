using System.Text.Json.Serialization;
using Glasstube.Native;
using Windows.Foundation;

namespace Glasstube.Models;

// Lo que devuelve Polish.swift: hojas de miniaturas, DeArrow, enlaces y filtros de búsqueda.

/// <summary>
/// Hojas de miniaturas de un video: cuadros de <see cref="Width"/>×<see cref="Height"/> en hojas de
/// <see cref="Columns"/>×<see cref="Rows"/>, repartidos a lo largo del video.
/// </summary>
public sealed record StoryboardInfo(string VideoId, int Width, int Height, int Count, int Columns, int Rows,
                                    double? Duration, List<string> Sheets)
{
    int PerSheet => Math.Max(1, Columns * Rows);

    /// <summary>La hoja y el recorte (píxeles de la hoja) del cuadro <paramref name="index"/>.</summary>
    public (string Sheet, Rect Crop)? Frame(int index)
    {
        if (Count <= 0 || Sheets.Count == 0) return null;
        index = Math.Clamp(index, 0, Count - 1);
        var sheet = Math.Min(Sheets.Count - 1, index / PerSheet);
        var inSheet = index % PerSheet;
        return (Sheets[sheet], new Rect(inSheet % Columns * Width, inSheet / Columns * Height, Width, Height));
    }

    /// <summary>El cuadro del segundo <paramref name="seconds"/> de un video de <paramref name="duration"/> segundos.</summary>
    public (string Sheet, Rect Crop)? FrameAt(double seconds, double duration) =>
        duration > 0 ? Frame((int)(seconds / duration * Count)) : null;
}

/// <summary>Guarda las hojas de cada video (las usan la vista previa de las tarjetas y la barra del reproductor).</summary>
public static class StoryboardCache
{
    static readonly Dictionary<string, Task<StoryboardInfo?>> cache = [];

    /// <summary>Las hojas del video, o null si no tiene o falló (no se vuelve a pedir en esta sesión).</summary>
    public static Task<StoryboardInfo?> Get(string videoId)
    {
        if (!cache.TryGetValue(videoId, out var task))
        {
            task = Load(videoId);
            cache[videoId] = task;
        }
        return task;
    }

    static async Task<StoryboardInfo?> Load(string videoId)
    {
        try
        {
            await App.Ready;
            return await GlasstubeFFI.Storyboard(videoId);
        }
        catch
        {
            return null;
        }
    }
}

public sealed record DeArrowItem(string VideoId, string? Title, string? Thumbnail);

public sealed record DeArrowInfo(List<DeArrowItem> Items);

/// <summary>Un enlace de YouTube: <see cref="Kind"/> "video", "playlist", "channel" o "search".</summary>
public sealed record LinkInfo(string Kind, string Id, double? Start, string? PlaylistId);

/// <summary>
/// Filtros de búsqueda (el SearchFilter de YTKit): los números son los de YouTube. Prioridad 0 = relevancia, 3 =
/// popularidad; fecha 2 hoy, 3 esta semana, 4 este mes, 5 este año; tipo 1 videos, 4 películas; duración 4 menos de
/// 3 min, 5 de 3 a 20, 2 más de 20; características 4 HD, 5 subtítulos, 6 Creative Commons, 8 en vivo, 14 4K, 25 HDR.
/// </summary>
public sealed class SearchFilterInfo
{
    public int Priority { get; set; }
    public int? UploadDate { get; set; }
    public int? Type { get; set; }
    public int? Duration { get; set; }
    public List<int> Features { get; set; } = [];

    [JsonIgnore]
    public bool IsEmpty => Priority == 0 && UploadDate == null && Type == null && Duration == null && Features.Count == 0;

    [JsonIgnore]
    public int ActiveCount => (Priority == 0 ? 0 : 1) + (UploadDate != null ? 1 : 0) + (Type != null ? 1 : 0)
                              + (Duration != null ? 1 : 0) + Features.Count;

    public SearchFilterInfo Copy() => new()
    {
        Priority = Priority, UploadDate = UploadDate, Type = Type, Duration = Duration, Features = [.. Features],
    };
}

/// <summary>Una búsqueda: el texto y sus filtros (parámetro de navegación de SearchPage).</summary>
public sealed record SearchRequest(string Query, SearchFilterInfo Filter);
