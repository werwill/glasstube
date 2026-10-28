using System.Text.Json;
using Glasstube.Native;

namespace Glasstube.Models;

/// <summary>
/// Ajustes de la app en %LOCALAPPDATA%\Glasstube\ajustes.json (los del reproductor siguen en
/// <see cref="PlayerSettings"/>). Se guardan al cambiar desde Configuración.
/// </summary>
public sealed class AppSettings
{
    /// <summary>"sistema", "claro" u "oscuro".</summary>
    public string Theme { get; set; } = "sistema";
    /// <summary>Al dejar el ratón sobre una tarjeta, la miniatura pasa por los cuadros del video.</summary>
    public bool HoverPreviews { get; set; } = true;
    /// <summary>Títulos y miniaturas de la comunidad (DeArrow). Apagado por omisión, como en SmartTube y la app de Mac.</summary>
    public bool DeArrowEnabled { get; set; }
    public bool DeArrowTitles { get; set; } = true;
    public bool DeArrowThumbnails { get; set; } = true;
    /// <summary>Buscar versiones nuevas en GitHub al abrir (como mucho una vez al día).</summary>
    public bool CheckForUpdates { get; set; } = true;

    static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Glasstube", "ajustes.json");

    static AppSettings? shared;

    public static AppSettings Shared => shared ??= Load();

    /// <summary>Cambió un ajuste (las tarjetas vuelven a pintarse con DeArrow, el tema se aplica…).</summary>
    public static event EventHandler? Changed;

    static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new();
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"ajustes: {error.Message}");
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
            GlasstubeFFI.Log("app", $"guardar ajustes: {error.Message}");
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public bool DeArrowShowsTitles => DeArrowEnabled && DeArrowTitles;
    public bool DeArrowShowsThumbnails => DeArrowEnabled && DeArrowThumbnails;
}
