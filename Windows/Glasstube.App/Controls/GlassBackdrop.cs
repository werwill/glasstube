using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Glasstube.Controls;

/// <summary>
/// Fondo de la ventana con el acrílico del escritorio. "Vidrio" lleva poco tinte, para que se vea el color de lo que
/// hay detrás (el fondo de pantalla) como en las maquetas; el de serie (DesktopAcrylicBackdrop) lo tapa casi del todo.
/// Opaco es el mismo controlador con el tinte entero.
/// </summary>
public sealed class GlassBackdrop(bool opaque) : SystemBackdrop
{
    DesktopAcrylicController? controller;
    // Activa siempre: si no, Windows cambia el vidrio por un color liso en cuanto la ventana pierde el foco.
    readonly SystemBackdropConfiguration configuration = new() { IsInputActive = true };
    FrameworkElement? root;

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(target, xamlRoot);
        controller = new DesktopAcrylicController();
        controller.AddSystemBackdropTarget(target);
        controller.SetSystemBackdropConfiguration(configuration);
        root = xamlRoot.Content as FrameworkElement;
        if (root != null) root.ActualThemeChanged += OnThemeChanged;
        Apply();
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop target)
    {
        base.OnTargetDisconnected(target);
        if (root != null) root.ActualThemeChanged -= OnThemeChanged;
        controller?.RemoveSystemBackdropTarget(target);
        controller?.Dispose();
        controller = null;
    }

    void OnThemeChanged(FrameworkElement sender, object args) => Apply();

    void Apply()
    {
        if (controller == null) return;
        var dark = root?.ActualTheme != ElementTheme.Light;
        configuration.Theme = dark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light;
        controller.TintColor = opaque
            ? dark ? Color.FromArgb(0xFF, 0x20, 0x20, 0x20) : Color.FromArgb(0xFF, 0xF3, 0xF3, 0xF3)
            : dark ? Color.FromArgb(0xFF, 0x18, 0x18, 0x1E) : Color.FromArgb(0xFF, 0xF3, 0xF3, 0xF6);
        // Con menos tinte y luminosidad se lee mal sobre una ventana blanca detrás (probado en oscuro).
        controller.TintOpacity = opaque ? 1 : dark ? 0.35f : 0.3f;
        controller.LuminosityOpacity = opaque ? 1 : dark ? 0.75f : 0.6f;
        controller.FallbackColor = dark ? Color.FromArgb(0xFF, 0x20, 0x20, 0x20) : Color.FromArgb(0xFF, 0xF3, 0xF3, 0xF3);
    }
}
