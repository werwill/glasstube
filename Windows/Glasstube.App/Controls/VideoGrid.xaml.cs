using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Glasstube.Controls;

/// <summary>Cuadrícula de videos: tarjetas, columnas que llenan el ancho y carga incremental (FeedCollection).</summary>
public sealed partial class VideoGrid : UserControl
{
    /// <summary>Ancho mínimo de una tarjeta (DIP); las columnas se reparten el ancho que sobra.</summary>
    const double MinCardWidth = 260;

    public VideoGrid()
    {
        InitializeComponent();
        // Clic derecho, mantener pulsado, Mayús+F10 o la tecla de menú.
        Grid.ContextRequested += (_, e) =>
        {
            if (VideoContextEventArgs.Find(e.OriginalSource) is { } args)
            {
                e.Handled = true;
                ItemContextRequested?.Invoke(this, args);
            }
        };
    }

    public object? ItemsSource
    {
        get => Grid.ItemsSource;
        set
        {
            Grid.ItemsSource = value;
            UpdateColumns();
        }
    }

    /// <summary>Contenido encima de las tarjetas que se desplaza con ellas.</summary>
    public object? Header
    {
        get => Grid.Header;
        set => Grid.Header = value;
    }

    Thickness itemsMargin = new(28, 4, 28, 24);

    /// <summary>Margen alrededor de las tarjetas, sin tocar el Header (el Inicio deja sitio al panel lateral).</summary>
    public Thickness ItemsMargin
    {
        get => itemsMargin;
        set
        {
            itemsMargin = value;
            UpdateColumns();
        }
    }

    public event ItemClickEventHandler? ItemClick;

    /// <summary>Menú contextual pedido sobre una tarjeta (ratón, táctil o teclado).</summary>
    public event EventHandler<VideoContextEventArgs>? ItemContextRequested;

    /// <summary>El ScrollViewer de la cuadrícula (para saber cuánto se ha desplazado).</summary>
    public ScrollViewer? ScrollHost => FindScrollViewer(Grid);

    void OnItemClick(object sender, ItemClickEventArgs e) => ItemClick?.Invoke(this, e);

    void OnGridSizeChanged(object sender, SizeChangedEventArgs e) => UpdateColumns();

    void RetryColumns(object? sender, object e)
    {
        Grid.LayoutUpdated -= RetryColumns;
        if (Grid.ItemsPanelRoot != null) UpdateColumns();
    }

    void UpdateColumns()
    {
        // El panel de la cuadrícula aparece con los primeros elementos: hasta entonces, tras la siguiente pasada de diseño.
        if (Grid.ItemsPanelRoot is not ItemsWrapGrid panel)
        {
            if (Grid.ItemsSource != null) Grid.LayoutUpdated += RetryColumns;
            return;
        }
        panel.Margin = itemsMargin;
        var available = Grid.ActualWidth - itemsMargin.Left - itemsMargin.Right - 1;
        if (available <= 0) return;
        const double margin = 8; // 4 + 4 del contenedor
        var columns = Math.Max(1, (int)(available / (MinCardWidth + margin)));
        panel.ItemWidth = Math.Floor(available / columns);
    }

    static ScrollViewer? FindScrollViewer(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is ScrollViewer viewer) return viewer;
            if (FindScrollViewer(child) is { } found) return found;
        }
        return null;
    }
}

/// <summary>La tarjeta sobre la que se pidió el menú y su vista (para colocarlo).</summary>
public sealed class VideoContextEventArgs(Models.VideoCard video, FrameworkElement target) : EventArgs
{
    public Models.VideoCard Video { get; } = video;
    public FrameworkElement Target { get; } = target;

    public static VideoContextEventArgs? Find(object source)
    {
        for (var node = source as DependencyObject; node != null; node = VisualTreeHelper.GetParent(node))
        {
            if (node is VideoCardView { Video: { } video } view) return new VideoContextEventArgs(video, view);
            // Con el teclado (Mayús+F10, tecla de menú) el evento sale del contenedor del elemento, no de la tarjeta.
            if (node is ContentControl { Content: Models.VideoCard card } container) return new VideoContextEventArgs(card, container);
        }
        return null;
    }
}
