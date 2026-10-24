using System.Numerics;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;

namespace Glasstube.Pages;

/// <summary>
/// Fondo de la portada en composición: la miniatura (UniformToFill) y un degradado oscuro desde la izquierda, los dos
/// con una máscara vertical que los deja transparentes abajo. Así la portada se funde con el acrílico de la ventana,
/// que cambia con lo que haya detrás; un degradado hacia un color fijo dejaría una costura.
/// </summary>
public sealed partial class HomePage
{
    SpriteVisual? heroImageVisual;
    CompositionSurfaceBrush? heroImageBrush;
    LoadedImageSurface? heroSurface;

    void SetHeroImage(string url, string? fallback)
    {
        EnsureHeroVisuals();
        heroSurface?.Dispose();
        heroSurface = LoadedImageSurface.StartLoadFromUri(new Uri(url));
        heroSurface.LoadCompleted += (surface, args) =>
        {
            // maxresdefault no existe en todos los videos: se cae a la miniatura normal.
            if (args.Status != LoadedImageSourceLoadStatus.Success && fallback != null && fallback != url)
                SetHeroImage(fallback, null);
        };
        heroImageBrush!.Surface = heroSurface;
    }

    void EnsureHeroVisuals()
    {
        if (heroImageVisual != null) return;
        var compositor = ElementCompositionPreview.GetElementVisual(HeroBackdrop).Compositor;

        // Máscara: opaco hasta el 60 % de la altura y transparente al final.
        CompositionLinearGradientBrush Fade()
        {
            var mask = compositor.CreateLinearGradientBrush();
            mask.StartPoint = new Vector2(0, 0);
            mask.EndPoint = new Vector2(0, 1);
            mask.ColorStops.Add(compositor.CreateColorGradientStop(0f, Colors.White));
            mask.ColorStops.Add(compositor.CreateColorGradientStop(0.6f, Colors.White));
            mask.ColorStops.Add(compositor.CreateColorGradientStop(1f, Colors.Transparent));
            return mask;
        }

        SpriteVisual Masked(CompositionBrush source)
        {
            var brush = compositor.CreateMaskBrush();
            brush.Source = source;
            brush.Mask = Fade();
            var sprite = compositor.CreateSpriteVisual();
            sprite.Brush = brush;
            sprite.RelativeSizeAdjustment = Vector2.One;
            return sprite;
        }

        heroImageBrush = compositor.CreateSurfaceBrush();
        heroImageBrush.Stretch = CompositionStretch.UniformToFill;
        heroImageBrush.HorizontalAlignmentRatio = 0.5f;
        heroImageBrush.VerticalAlignmentRatio = 0.35f;
        heroImageVisual = Masked(heroImageBrush);

        var shade = compositor.CreateLinearGradientBrush();
        shade.StartPoint = new Vector2(0, 0);
        shade.EndPoint = new Vector2(1, 0);
        shade.ColorStops.Add(compositor.CreateColorGradientStop(0f, Windows.UI.Color.FromArgb(0xE0, 0, 0, 0)));
        shade.ColorStops.Add(compositor.CreateColorGradientStop(0.35f, Windows.UI.Color.FromArgb(0xB0, 0, 0, 0)));
        shade.ColorStops.Add(compositor.CreateColorGradientStop(0.7f, Windows.UI.Color.FromArgb(0x30, 0, 0, 0)));
        shade.ColorStops.Add(compositor.CreateColorGradientStop(1f, Colors.Transparent));

        var container = compositor.CreateContainerVisual();
        container.RelativeSizeAdjustment = Vector2.One;
        container.Children.InsertAtTop(heroImageVisual);
        container.Children.InsertAtTop(Masked(shade));
        ElementCompositionPreview.SetElementChildVisual(HeroBackdrop, container);
    }
}
