using System.Globalization;
using Glasstube.Native;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Glasstube;

public partial class App : Application
{
    public static MainWindow? Window { get; private set; }

    /// <summary>Termina cuando el motor Swift está listo (catálogo, sesión y servicio).</summary>
    public static Task<Models.InitInfo> Ready { get; private set; } = new TaskCompletionSource<Models.InitInfo>().Task;

    DispatcherQueueTimer? pump;
    /// <summary>Mientras exista, el instalador de una actualización espera a que la app se cierre (Glasstube.iss).</summary>
    Mutex? running;

    public App()
    {
        InitializeComponent();
        // `Glasstube.exe --tema claro|oscuro`: fuerza el tema (capturas y pruebas); sin él, sigue al de Windows.
        var arguments = Environment.GetCommandLineArgs();
        var theme = Array.IndexOf(arguments, "--tema");
        if (theme >= 0 && theme + 1 < arguments.Length)
            RequestedTheme = arguments[theme + 1] == "oscuro" ? ApplicationTheme.Dark : ApplicationTheme.Light;
        UnhandledException += (_, e) => GlasstubeFFI.Log("app", $"excepción sin atrapar: {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => GlasstubeFFI.Log("app", $"excepción fatal: {e.ExceptionObject}");
        TaskScheduler.UnobservedTaskException += (_, e) => GlasstubeFFI.Log("app", $"tarea sin observar: {e.Exception}");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // El actor principal de Swift es la cola principal de libdispatch: la vacía este hilo (el principal del
        // proceso), así que los callbacks de GlasstubeFFI llegan aquí. La primera llamada a la DLL también es desde
        // aquí, para que libdispatch tome este hilo como el principal.
        running = new Mutex(false, "GlasstubeApp");
        pump = DispatcherQueue.GetForCurrentThread().CreateTimer();
        pump.Interval = TimeSpan.FromMilliseconds(15);
        pump.Tick += (_, _) => GlasstubeFFI.Pump();
        pump.Start();

        var (language, region) = CatalogLocale(CultureInfo.CurrentUICulture, RegionInfo.CurrentRegion);
        GlasstubeFFI.Log("app", $"arranque: {Environment.ProcessPath}, carpeta de trabajo {Environment.CurrentDirectory}");
        Ready = GlasstubeFFI.Init(language, region);

        Window = new MainWindow();
        Window.Closed += (_, _) => { SaveBeforeExit(); pump?.Stop(); GlasstubeFFI.Shutdown(); };
        Window.Activate();

        // `Glasstube.exe --abrir <videoId>`: abre ese video al arrancar (pruebas y enlaces).
        var arguments = Environment.GetCommandLineArgs();
        var index = Array.IndexOf(arguments, "--abrir");
        if (index >= 0 && index + 1 < arguments.Length)
            Window.Play(new Models.VideoCard { Id = arguments[index + 1], Title = arguments[index + 1] });
        if (arguments.Contains("--probar-ffi")) _ = ProbeFFI();
        // `--buscar <texto>`: abre esa búsqueda (capturas).
        var search = Array.IndexOf(arguments, "--buscar");
        if (search >= 0 && search + 1 < arguments.Length) Window.Search(arguments[search + 1]);
        // `--sin-aviso-de-versiones`: no consulta GitHub (capturas y pruebas).
        if (!arguments.Contains("--sin-aviso-de-versiones") && !Models.CaptureMode.Enabled
            && Window.Content is Microsoft.UI.Xaml.Controls.Grid root)
            _ = Models.UpdateCheck.RunAsync(root, force: arguments.Contains("--buscar-versiones")); // sin esperar un día
        // `--actualizar-desde <Setup.exe>`: instala ese instalador local como una actualización (pruebas).
        var local = Array.IndexOf(arguments, "--actualizar-desde");
        if (local >= 0 && local + 1 < arguments.Length) Models.UpdateCheck.InstallLocal(arguments[local + 1]);
    }

    /// <summary>`--probar-ffi`: llama a la API 0.2 (Suscripciones, biblioteca, detalles, búsqueda) y anota un resumen en el registro.</summary>
    static async Task ProbeFFI()
    {
        async Task Probe(string name, Func<Task<string>> call)
        {
            try { GlasstubeFFI.Log("prueba", $"{name}: {await call()}"); }
            catch (Exception error) { GlasstubeFFI.Log("prueba", $"{name} FALLÓ: {error.Message}"); }
        }
        await Ready;
        string? first = null;
        await Probe("suscripciones", async () =>
        {
            var page = await GlasstubeFFI.Subscriptions();
            first = page.Items.FirstOrDefault()?.Id;
            var top = page.Items.Take(3).Select(i => $"«{i.Title}» {i.Published} ({(i.PublishedAt is { } at ? DateTimeOffset.FromUnixTimeSeconds((long)at).LocalDateTime.ToString("g") : "sin fecha")}, avatar {(i.Avatar != null ? "sí" : "no")})");
            return $"{page.Items.Count} videos, más {page.HasMore}, {page.Channels.Count} canales ({page.Channels.Count(c => c.HasNew)} con nuevos), {page.Groups.Count} grupos; " + string.Join("; ", top);
        });
        await Probe("suscripciones (más)", async () => { var more = await GlasstubeFFI.SubscriptionsMore(); return $"{more.Items.Count} videos, más {more.HasMore}"; });
        await Probe("biblioteca", async () =>
        {
            var library = await GlasstubeFFI.Library();
            return $"historial {library.History.Count}, continuar {library.ContinueWatching.Count}, más tarde {library.WatchLater.Count}, vistos {library.Seen.Count}, archivados {library.Archived.Count}";
        });
        await Probe("detalles", async () =>
        {
            var details = await GlasstubeFFI.Details(first ?? "dQw4w9WgXcQ");
            return $"{details.VideoId} «{details.Title}», {details.Chapters.Count} capítulos ({string.Join(", ", details.Chapters.Take(3).Select(c => $"{c.Start:0}s {c.Title}"))}), {details.Segments.Count} tramos SponsorBlock, descripción {details.Description?.Length ?? 0} car.";
        });
        await Probe("detalles con capítulos y patrocinio", async () =>
        {
            var details = await GlasstubeFFI.Details("ESABTN4VtrA");
            return $"«{details.Title}», {details.Chapters.Count} capítulos, segmentos: {string.Join(", ", details.Segments.Select(s => $"{s.Category} {s.Start:0}-{s.End:0}"))}";
        });
        await Probe("búsqueda", async () => { var page = await GlasstubeFFI.Search("marques brownlee"); return $"{page.Items.Count} videos, más {page.HasMore}, primero «{page.Items.FirstOrDefault()?.Title}»"; });
    }

    /// <summary>
    /// Al cerrar: la posición del video abierto y la biblioteca a disco. La cola de Swift solo avanza con gt_pump, así
    /// que se vacía aquí mismo (hasta 1 s) antes de soltar el motor.
    /// </summary>
    static void SaveBeforeExit()
    {
        try
        {
            (Window?.CurrentPage as Pages.PlayerPage)?.RecordPosition();
            var saving = GlasstubeFFI.SaveLibrary();
            var until = DateTime.UtcNow.AddSeconds(1);
            while (!saving.IsCompleted && DateTime.UtcNow < until)
            {
                GlasstubeFFI.Pump();
                Thread.Sleep(5);
            }
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"guardar al cerrar: {error.Message}");
        }
    }

    /// <summary>"es-MX" → ("es-419", "MX"), como CatalogLocale.current en YTKit.</summary>
    static (string, string) CatalogLocale(CultureInfo culture, RegionInfo region)
    {
        var language = culture.TwoLetterISOLanguageName;
        var country = region.TwoLetterISORegionName;
        if (language == "es" && country != "ES") return ("es-419", country);
        return (language, country);
    }
}
