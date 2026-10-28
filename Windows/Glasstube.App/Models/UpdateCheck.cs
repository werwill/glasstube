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
/// marcan como la última). Si es más nueva que esta, muestra un aviso abajo a la derecha con «Actualizar y reiniciar» y
/// «Ahora no». Actualizar baja el instalador de la Release, comprueba su SHA-256, lo corre en silencio y cierra la app;
/// el instalador la vuelve a abrir. Si algo falla, queda «Abrir la página». La consulta no lleva datos de quien la usa;
/// la fecha de la última va en %LOCALAPPDATA%\Glasstube\actualizaciones.json.
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

    /// <summary>El instalador de una Release: su URL y el SHA-256 que publica GitHub ("sha256:…") o su <c>.sha256</c>.</summary>
    sealed record Setup(string Name, string Url, long Size, string? Digest, string? DigestUrl);

    sealed record Release(Version Version, string Page, Setup? Setup);

    /// <summary>
    /// Consulta (si toca, o siempre con <paramref name="force"/>) y, si hay una versión más nueva, pone el aviso encima
    /// de <paramref name="root"/>. Devuelve si la hay (null si no se consultó o falló).
    /// </summary>
    public static async Task<bool?> RunAsync(Grid root, bool force = false)
    {
        try
        {
            var state = Load();
            if (!force && DateTimeOffset.Now - state.LastCheck < TimeSpan.FromDays(1)) return null;
            var latest = await Latest();
            state.LastCheck = DateTimeOffset.Now;
            Save(state);
            if (latest is not { } found || found.Version <= Current)
            {
                GlasstubeFFI.Log("app", $"versiones: {Current} es la más nueva");
                return false;
            }
            GlasstubeFFI.Log("app", $"versiones: hay {found.Version} (esta es {Current}), instalador {found.Setup?.Name ?? "no encontrado"}");
            Show(root, found);
            return true;
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"versiones: no se pudo consultar ({error.Message})");
            return null;
        }
    }

    static HttpClient Client(TimeSpan timeout)
    {
        var http = new HttpClient { Timeout = timeout };
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"Glasstube-Windows/{Current}");
        return http;
    }

    static async Task<Release?> Latest()
    {
        using var http = Client(TimeSpan.FromSeconds(15));
        http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        using var document = JsonDocument.Parse(await http.GetStringAsync(Releases));
        Release? best = null;
        foreach (var release in document.RootElement.EnumerateArray())
        {
            if (release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean()) continue;
            var tag = release.GetProperty("tag_name").GetString() ?? "";
            if (!tag.StartsWith(TagPrefix, StringComparison.Ordinal)) continue;
            if (!Version.TryParse(tag[TagPrefix.Length..], out var version)) continue;
            if (best != null && best.Version >= version) continue;
            best = new Release(version, release.GetProperty("html_url").GetString() ?? "", FindSetup(release));
        }
        return best;
    }

    /// <summary>"Glasstube-X.Y.Z-Windows-x64-Setup.exe" entre los archivos de la Release, con su suma.</summary>
    static Setup? FindSetup(JsonElement release)
    {
        if (!release.TryGetProperty("assets", out var assets)) return null;
        var files = assets.EnumerateArray().Select(a => (
            Name: a.GetProperty("name").GetString() ?? "",
            Url: a.GetProperty("browser_download_url").GetString() ?? "",
            Size: a.TryGetProperty("size", out var size) ? size.GetInt64() : 0,
            Digest: a.TryGetProperty("digest", out var digest) && digest.ValueKind == JsonValueKind.String ? digest.GetString() : null)).ToList();
        var setup = files.FirstOrDefault(f => f.Name.EndsWith("-Windows-x64-Setup.exe", StringComparison.OrdinalIgnoreCase));
        if (setup.Name is null or "") return null;
        var sum = files.FirstOrDefault(f => f.Name.Equals(setup.Name + ".sha256", StringComparison.OrdinalIgnoreCase));
        return new Setup(setup.Name, setup.Url, setup.Size, setup.Digest, sum.Name is null or "" ? null : sum.Url);
    }

    static void Show(Grid root, Release release)
    {
        var update = new Button
        {
            Content = release.Setup != null ? "Actualizar y reiniciar" : "Descargar",
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        var later = new Button { Content = "Ahora no" };
        var progress = new ProgressBar { Minimum = 0, Maximum = 1, Width = 240, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, 0, 12) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 12), Children = { update, later } };
        var bar = new InfoBar
        {
            Title = $"Glasstube {release.Version.ToString(3)} para Windows",
            Message = "Hay una versión nueva.",
            Severity = InfoBarSeverity.Informational,
            IsOpen = true,
            IsClosable = false,
            Content = new StackPanel { Children = { progress, buttons } },
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 16, 16),
            MaxWidth = 420,
            Background = (Brush)Application.Current.Resources["AcrylicInAppFillColorDefaultBrush"],
            CornerRadius = new CornerRadius(8),
        };
        var openPage = false;
        update.Click += async (_, _) =>
        {
            if (release.Setup == null || openPage)
            {
                if (Uri.TryCreate(release.Page, UriKind.Absolute, out var uri)) await Windows.System.Launcher.LaunchUriAsync(uri);
                root.Children.Remove(bar);
                return;
            }
            buttons.Visibility = Visibility.Collapsed;
            progress.Visibility = Visibility.Visible;
            bar.Message = "Descargando…";
            try
            {
                var file = await Download(release.Setup, fraction =>
                {
                    progress.Value = fraction;
                    bar.Message = $"Descargando… {fraction:P0}";
                });
                bar.Message = "Instalando. Glasstube se va a cerrar y abrir de nuevo.";
                progress.IsIndeterminate = true;
                Install(file);
            }
            catch (Exception error)
            {
                GlasstubeFFI.Log("app", $"actualización: {error.Message}");
                progress.Visibility = Visibility.Collapsed;
                buttons.Visibility = Visibility.Visible;
                bar.Severity = InfoBarSeverity.Warning;
                bar.Message = $"No se pudo actualizar ({error.Message}). Puedes bajarla desde su página.";
                update.Content = "Abrir la página";
                openPage = true;
            }
        };
        // Hasta la próxima consulta (mañana), como en la Mac.
        later.Click += (_, _) => root.Children.Remove(bar);
        root.Children.Add(bar);
    }

    static readonly string DownloadDirectory = Path.Combine(Path.GetTempPath(), "Glasstube-actualizacion");

    /// <summary>Baja el instalador a %TEMP% y comprueba su SHA-256 (sin suma conocida no se instala).</summary>
    static async Task<string> Download(Setup setup, Action<double> progress)
    {
        using var http = Client(TimeSpan.FromMinutes(30));
        var expected = setup.Digest is { } digest && digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)
            ? digest["sha256:".Length..]
            : setup.DigestUrl != null ? (await http.GetStringAsync(setup.DigestUrl)).Split(' ', 2)[0] : null;
        if (string.IsNullOrWhiteSpace(expected)) throw new InvalidOperationException("la versión no publica la suma SHA-256");

        Directory.CreateDirectory(DownloadDirectory);
        var path = Path.Combine(DownloadDirectory, Path.GetFileName(setup.Name));
        using (var response = await http.GetAsync(setup.Url, HttpCompletionOption.ResponseHeadersRead))
        {
            response.EnsureSuccessStatusCode();
            var total = response.Content.Headers.ContentLength ?? setup.Size;
            await using var source = await response.Content.ReadAsStreamAsync();
            await using var target = File.Create(path);
            var buffer = new byte[1 << 16];
            long done = 0;
            var lastReport = DateTime.MinValue;
            int read;
            while ((read = await source.ReadAsync(buffer)) > 0)
            {
                await target.WriteAsync(buffer.AsMemory(0, read));
                done += read;
                if (total > 0 && DateTime.UtcNow - lastReport > TimeSpan.FromMilliseconds(200))
                {
                    lastReport = DateTime.UtcNow;
                    progress((double)done / total);
                }
            }
        }
        progress(1);
        Verify(path, expected);
        GlasstubeFFI.Log("app", $"actualización: {setup.Name} descargado y verificado");
        return path;
    }

    static void Verify(string path, string expected)
    {
        using var stream = File.OpenRead(path);
        var actual = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream));
        if (!actual.Equals(expected.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            stream.Dispose();
            File.Delete(path);
            throw new InvalidOperationException("el archivo descargado no coincide con su suma SHA-256");
        }
    }

    /// <summary>
    /// `--actualizar-desde &lt;Setup.exe&gt;` (pruebas): instala ese instalador local como si viniera de una Release,
    /// comprobándolo con el <c>.sha256</c> que tiene al lado.
    /// </summary>
    public static void InstallLocal(string setup)
    {
        try
        {
            var sum = File.ReadAllText(setup + ".sha256").Split(' ', 2)[0];
            Verify(setup, sum);
            Install(setup);
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"actualización local: {error.Message}");
        }
    }

    /// <summary>
    /// Lanza el instalador en silencio y cierra la app. El instalador espera a que se cierre (el mutex de
    /// <see cref="App"/>), se instala encima, en la misma carpeta y para el mismo ámbito, y la vuelve a abrir.
    /// </summary>
    static void Install(string setup)
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var forAllUsers = AppContext.BaseDirectory.StartsWith(programFiles, StringComparison.OrdinalIgnoreCase);
        var arguments = $"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- {(forAllUsers ? "/ALLUSERS" : "/CURRENTUSER")} /RELANZAR=1";
        GlasstubeFFI.Log("app", $"actualización: {Path.GetFileName(setup)} {arguments}");
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(setup, arguments) { UseShellExecute = true });
        App.Window?.Close();
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
