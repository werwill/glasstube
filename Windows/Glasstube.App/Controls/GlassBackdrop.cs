using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Glasstube.Controls;

/// <summary>
/// El fondo de la ventana: "vidrio" (acrílico del escritorio con poco tinte, para que se vea el color de lo que hay
/// detrás, como en las maquetas; el de serie, DesktopAcrylicBackdrop, lo tapa casi del todo), "mica" u "opaco" (el
/// mismo acrílico con el tinte entero). Es uno solo para toda la vida de la ventana y cambia de controlador por dentro:
/// cambiar Window.SystemBackdrop por otro (y el MicaBackdrop de serie) hacía que la app se cerrara al cambiar de tema
/// después (ArgumentException «target»).
/// </summary>
public sealed class GlassBackdrop : SystemBackdrop
{
    ISystemBackdropControllerWithTargets? controller;
    ICompositionSupportsSystemBackdrop? target;
    // Activa siempre: si no, Windows cambia el vidrio por un color liso en cuanto la ventana pierde el foco.
    readonly SystemBackdropConfiguration configuration = new() { IsInputActive = true };
    FrameworkElement? root;
    string mode;

    public GlassBackdrop(string mode) => this.mode = mode;

    public static bool IsSupported => DesktopAcrylicController.IsSupported() || MicaController.IsSupported();

    /// <summary>"vidrio", "mica" u "opaco". Sin acrílico (Windows 10) todo es Mica; sin Mica, todo acrílico.</summary>
    public string Mode
    {
        get => mode;
        set
        {
            if (value == mode) return;
            mode = value;
            Connect();
        }
    }

    bool UsesMica => mode == "mica" ? MicaController.IsSupported() : !DesktopAcrylicController.IsSupported();

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(target, xamlRoot);
        this.target = target;
        root = xamlRoot.Content as FrameworkElement;
        if (root != null) root.ActualThemeChanged += OnThemeChanged;
        Connect();
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop target)
    {
        base.OnTargetDisconnected(target);
        if (root != null) root.ActualThemeChanged -= OnThemeChanged;
        Disconnect();
        this.target = null;
    }

    // La configuración de serie (tema, foco) no se usa: va la nuestra. El método base, al cambiar el tema, lanza
    // ArgumentException («target») y cierra la app.
    protected override void OnDefaultSystemBackdropConfigurationChanged(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot) => Apply();

    void OnThemeChanged(FrameworkElement sender, object args) => Apply();

    /// <summary>Pone el controlador del modo (si cambió de tipo, quita el anterior) y le aplica el tema.</summary>
    void Connect()
    {
        if (target == null) return;
        if (UsesMica ? controller is not MicaController : controller is not DesktopAcrylicController)
        {
            Disconnect();
            controller = UsesMica ? new MicaController() : new DesktopAcrylicController();
            controller.AddSystemBackdropTarget(target);
            controller.SetSystemBackdropConfiguration(configuration);
        }
        Apply();
    }

    void Disconnect()
    {
        if (controller == null) return;
        if (target != null) controller.RemoveSystemBackdropTarget(target);
        controller.Dispose();
        controller = null;
    }

    void Apply()
    {
        var dark = root?.ActualTheme != ElementTheme.Light;
        configuration.Theme = dark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light;
        if (controller is not DesktopAcrylicController acrylic) return;
        var opaque = mode == "opaco";
        acrylic.TintColor = opaque
            ? dark ? Color.FromArgb(0xFF, 0x20, 0x20, 0x20) : Color.FromArgb(0xFF, 0xF3, 0xF3, 0xF3)
            : dark ? Color.FromArgb(0xFF, 0x18, 0x18, 0x1E) : Color.FromArgb(0xFF, 0xF3, 0xF3, 0xF6);
        // Con menos tinte y luminosidad se lee mal sobre una ventana blanca detrás (probado en oscuro).
        acrylic.TintOpacity = opaque ? 1 : dark ? 0.35f : 0.3f;
        acrylic.LuminosityOpacity = opaque ? 1 : dark ? 0.75f : 0.6f;
        acrylic.FallbackColor = dark ? Color.FromArgb(0xFF, 0x20, 0x20, 0x20) : Color.FromArgb(0xFF, 0xF3, 0xF3, 0xF3);
    }
}
