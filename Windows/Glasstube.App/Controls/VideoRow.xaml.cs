using Glasstube.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Glasstube.Controls;

/// <summary>Fila horizontal de tarjetas con título ("Continuar viendo", "Nuevos de tus canales"…).</summary>
public sealed partial class VideoRow : UserControl
{
    bool hovering;

    public VideoRow()
    {
        InitializeComponent();
        // Clic o Intro en una tarjeta. ItemsRepeater no tiene ItemClick: se escucha en la fila.
        Items.AddHandler(TappedEvent, new TappedEventHandler((_, e) => Invoke(e.OriginalSource)), true);
        Items.AddHandler(KeyDownEvent, new KeyEventHandler((_, e) =>
        {
            if (e.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space) Invoke(e.OriginalSource);
        }), true);
    }

    public string Title
    {
        get => TitleText.Text;
        set => TitleText.Text = value;
    }

    /// <summary>Texto pequeño junto al título ("4 videos").</summary>
    public string Count
    {
        get => CountText.Text;
        set => CountText.Text = value;
    }

    public IReadOnlyList<VideoCard> Videos
    {
        set
        {
            Items.ItemsSource = value;
            Count = value.Count == 1 ? "1 video" : $"{value.Count} videos";
            DispatcherQueue.TryEnqueue(UpdateButtons);
        }
    }

    /// <summary>Se eligió una tarjeta.</summary>
    public event EventHandler<VideoCard>? VideoInvoked;

    void Invoke(object source)
    {
        for (var node = source as DependencyObject; node != null; node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node))
        {
            if (node is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase) return; // el enlace del canal va aparte
            if (node is VideoCardView { Video: { } video })
            {
                VideoInvoked?.Invoke(this, video);
                return;
            }
        }
    }

    /// <summary>Margen de las tarjetas a la izquierda (el panel lateral); la fila se sigue viendo hasta el borde.</summary>
    public Thickness ContentMargin
    {
        set
        {
            Header.Margin = new Thickness(value.Left, 0, value.Right, -8);
            // Arriba y abajo, sitio para la tarjeta que se levanta y su sombra.
            Items.Margin = new Thickness(value.Left, 8, value.Right, 12);
            PreviousButton.Margin = new Thickness(value.Left - 18, 72, 0, 0);
            NextButton.Margin = new Thickness(0, 72, Math.Max(8, value.Right - 18), 0);
        }
    }

    void Scroll(int direction)
    {
        var page = Math.Max(300, Scroller.ViewportWidth - 200);
        Scroller.ChangeView(Math.Max(0, Scroller.HorizontalOffset + direction * page), null, null);
    }

    void OnPrevious(object sender, RoutedEventArgs e) => Scroll(-1);
    void OnNext(object sender, RoutedEventArgs e) => Scroll(1);
    void OnViewChanged(object? sender, ScrollViewerViewChangedEventArgs e) => UpdateButtons();

    void OnPointerEntered(object sender, PointerRoutedEventArgs e)
    {
        hovering = true;
        UpdateButtons();
    }

    void OnPointerExited(object sender, PointerRoutedEventArgs e)
    {
        hovering = false;
        UpdateButtons();
    }

    /// <summary>Los botones salen al pasar el ratón, y solo si hay hacia dónde desplazarse.</summary>
    void UpdateButtons()
    {
        var canPrevious = Scroller.HorizontalOffset > 1;
        var canNext = Scroller.HorizontalOffset < Scroller.ScrollableWidth - 1;
        PreviousButton.Opacity = hovering && canPrevious ? 1 : 0;
        PreviousButton.IsHitTestVisible = hovering && canPrevious;
        NextButton.Opacity = hovering && canNext ? 1 : 0;
        NextButton.IsHitTestVisible = hovering && canNext;
    }
}
