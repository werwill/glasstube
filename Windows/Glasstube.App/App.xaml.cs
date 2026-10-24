using System.Globalization;
using Glasstube.Native;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Glasstube;

public partial class App : Application
{
    public static MainWindow? Window { get; private set; }

    /// <summary>Termina cuando el motor Swift está listo (catálogo, sesión y servicio).</summary>
    public static Task<Models.InitInfo> Ready { get; private set; } = Task.FromException<Models.InitInfo>(new InvalidOperationException());

    DispatcherQueueTimer? pump;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) => Console.Error.WriteLine($"[app] {e.Exception}");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // El actor principal de Swift es la cola principal de libdispatch: la vacía este hilo (el principal del
        // proceso), así que los callbacks de GlasstubeFFI llegan aquí. La primera llamada a la DLL también es desde
        // aquí, para que libdispatch tome este hilo como el principal.
        pump = DispatcherQueue.GetForCurrentThread().CreateTimer();
        pump.Interval = TimeSpan.FromMilliseconds(15);
        pump.Tick += (_, _) => GlasstubeFFI.Pump();
        pump.Start();

        var (language, region) = CatalogLocale(CultureInfo.CurrentUICulture, RegionInfo.CurrentRegion);
        Ready = GlasstubeFFI.Init(language, region);

        Window = new MainWindow();
        Window.Closed += (_, _) => { pump?.Stop(); GlasstubeFFI.Shutdown(); };
        Window.Activate();
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
