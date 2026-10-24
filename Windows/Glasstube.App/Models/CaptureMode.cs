namespace Glasstube.Models;

/// <summary>
/// `Glasstube.exe --capturas`: para las capturas públicas (docs/capturas/windows), como -GTSinPersonas y -GTAnonimo en
/// la app de Mac. No muestra la cuenta ni los canales suscritos, quien comenta sale como @personaN con un círculo en
/// lugar de su foto (el canal del video conserva su nombre), los controles del reproductor no se ocultan, no guarda
/// posiciones en el historial ni consulta versiones nuevas. Con `--desde S` el video empieza en ese segundo y con
/// `--panel descripcion|comentarios|sugeridos` abre el panel lateral en esa pestaña. Las capturas las rehace
/// Windows/Installer/capturas.ps1.
/// </summary>
public static class CaptureMode
{
    static readonly string[] Arguments = Environment.GetCommandLineArgs();
    static readonly Dictionary<string, int> people = [];

    public static bool Enabled { get; } = Arguments.Contains("--capturas");

    /// <summary>`--desde S`: segundo de inicio en lugar de donde se quedó.</summary>
    public static double? StartAt => Value("--desde") is { } text && double.TryParse(text,
        System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var seconds) ? seconds : null;

    /// <summary>`--panel descripcion|comentarios|sugeridos`.</summary>
    public static string? Panel => Value("--panel");

    /// <summary>El nombre que se muestra de quien comenta: siempre el mismo @personaN para la misma persona.</summary>
    public static string Person(string author)
    {
        if (!people.TryGetValue(author, out var number)) people[author] = number = people.Count + 1;
        return $"@persona{number}";
    }

    static string? Value(string name)
    {
        var index = Array.IndexOf(Arguments, name);
        return Enabled && index >= 0 && index + 1 < Arguments.Length ? Arguments[index + 1] : null;
    }
}
