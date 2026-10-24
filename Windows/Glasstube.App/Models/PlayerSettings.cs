using System.Text.Json;
using Glasstube.Native;

namespace Glasstube.Models;

/// <summary>
/// Ajustes locales del reproductor en %LOCALAPPDATA%\Glasstube\reproductor.json: la última calidad elegida, los
/// subtítulos y la reproducción automática. Se guardan al cambiar.
/// </summary>
public sealed class PlayerSettings
{
    /// <summary>Altura máxima elegida (0 = Auto, hasta 1080p).</summary>
    public int Quality { get; set; }
    /// <summary>Idioma de los últimos subtítulos activados ("es", "en"…); null = el de la interfaz.</summary>
    public string? CaptionLanguage { get; set; }
    /// <summary>Si los subtítulos estaban activados al salir del último video.</summary>
    public bool CaptionsOn { get; set; }
    /// <summary>Reproducir el siguiente sugerido al terminar (con cuenta atrás).</summary>
    public bool Autoplay { get; set; } = true;

    static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Glasstube", "reproductor.json");

    static PlayerSettings? shared;

    public static PlayerSettings Shared => shared ??= Load();

    static PlayerSettings Load()
    {
        try
        {
            if (File.Exists(FilePath)) return JsonSerializer.Deserialize<PlayerSettings>(File.ReadAllText(FilePath)) ?? new();
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"ajustes del reproductor: {error.Message}");
        }
        return new();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"guardar ajustes del reproductor: {error.Message}");
        }
    }
}
