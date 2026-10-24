using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Glasstube.Controls;

/// <summary>Cuadrícula de videos: tarjetas, columnas que llenan el ancho y carga incremental (FeedCollection).</summary>
public sealed partial class VideoGrid : UserControl
{
    /// <summary>Ancho mínimo de una tarjeta (DIP); las columnas se reparten el ancho que sobra.</summary>
    const double MinCardWidth = 260;

    public VideoGrid() => InitializeComponent();

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

    /// <summary>Margen alrededor de las tarjetas (el Inicio lo cambia para dejar sitio al panel).</summary>
    public Thickness GridPadding
    {
        get => Grid.Padding;
        set
        {
            Grid.Padding = value;
            UpdateColumns();
        }
    }

    public event ItemClickEventHandler? ItemClick;

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
        var available = Grid.ActualWidth - Grid.Padding.Left - Grid.Padding.Right - 1;
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
