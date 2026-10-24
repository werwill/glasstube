using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using Glasstube.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Glasstube.Models;

/// <summary>
/// Aviso de versiones nuevas, como el de la app de Mac: al abrirse, y como mucho una vez al día, pregunta a GitHub por
/// las Releases y busca la más nueva con etiqueta <c>windows-v…</c> (las de Windows van aparte de las de Mac y no se
/// marcan como la última). Si es más nueva que esta, muestra un aviso abajo a la derecha con «Descargar», que abre la
/// página de esa versión, y «Ahora no». No instala nada. La consulta no lleva datos de quien la usa; la fecha de la
/// última va en %LOCALAPPDATA%\Glasstube\actualizaciones.json.
/// </summary>
public static class UpdateCheck
{
    const string Releases = "https://api.github.com/repos/werwill/glasstube/releases?per_page=50";
    const string TagPrefix = "windows-v";

    static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Glasstube", "actualizaciones.json");

    sealed class State
    {
        public DateTimeOffset LastCheck { get; set; }
    }

    /// <summary>La versión de esta app (la pone build-installer.ps1 con -p:Version; en el csproj, la de desarrollo).</summary>
    public static Version Current
    {
        get
        {
            var version = Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(0, 0, 0);
            return new Version(version.Major, version.Minor, Math.Max(version.Build, 0));
        }
    }

    /// <summary>Consulta (si toca) y, si hay una versión más nueva, pone el aviso encima de <paramref name="root"/>.</summary>
    public static async Task RunAsync(Grid root)
    {
        try
        {
            var state = Load();
            if (DateTimeOffset.Now - state.LastCheck < TimeSpan.FromDays(1)) return;
            var latest = await Latest();
            state.LastCheck = DateTimeOffset.Now;
            Save(state);
            if (latest is not { } found || found.Version <= Current)
            {
                GlasstubeFFI.Log("app", $"versiones: {Current} es la más nueva");
                return;
            }
            GlasstubeFFI.Log("app", $"versiones: hay {found.Version} (esta es {Current})");
            Show(root, found.Version, found.Page);
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"versiones: no se pudo consultar ({error.Message})");
        }
    }

    static async Task<(Version Version, string Page)?> Latest()
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"Glasstube-Windows/{Current}");
        http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        using var document = JsonDocument.Parse(await http.GetStringAsync(Releases));
        (Version, string)? best = null;
        foreach (var release in document.RootElement.EnumerateArray())
        {
            if (release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean()) continue;
            var tag = release.GetProperty("tag_name").GetString() ?? "";
            if (!tag.StartsWith(TagPrefix, StringComparison.Ordinal)) continue;
            if (!Version.TryParse(tag[TagPrefix.Length..], out var version)) continue;
            if (best is { } current && current.Item1 >= version) continue;
            best = (version, release.GetProperty("html_url").GetString() ?? "");
        }
        return best;
    }

    static void Show(Grid root, Version version, string page)
    {
        var download = new Button { Content = "Descargar", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        var later = new Button { Content = "Ahora no" };
        var bar = new InfoBar
        {
            Title = $"Glasstube {version.ToString(3)} para Windows",
            Message = "Hay una versión nueva.",
            Severity = InfoBarSeverity.Informational,
            IsOpen = true,
            IsClosable = false,
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 12), Children = { download, later } },
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 16, 16),
            MaxWidth = 420,
            Background = (Brush)Application.Current.Resources["AcrylicInAppFillColorDefaultBrush"],
            CornerRadius = new CornerRadius(8),
        };
        download.Click += async (_, _) =>
        {
            if (Uri.TryCreate(page, UriKind.Absolute, out var uri)) await Windows.System.Launcher.LaunchUriAsync(uri);
            root.Children.Remove(bar);
        };
        // Hasta la próxima consulta (mañana), como en la Mac.
        later.Click += (_, _) => root.Children.Remove(bar);
        root.Children.Add(bar);
    }

    static State Load()
    {
        try
        {
            if (File.Exists(FilePath)) return JsonSerializer.Deserialize<State>(File.ReadAllText(FilePath)) ?? new();
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"versiones: {error.Message}");
        }
        return new();
    }

    static void Save(State state)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(state));
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"versiones: {error.Message}");
        }
    }
}
