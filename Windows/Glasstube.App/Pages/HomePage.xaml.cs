using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

public sealed partial class HomePage : Page
{
    /// <summary>Ancho mínimo de una tarjeta (DIP); las columnas se reparten el ancho que sobra.</summary>
    const double MinCardWidth = 260;

    bool loaded;

    public HomePage() => InitializeComponent();

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        if (!loaded) _ = Load();
    }

    async Task Load()
    {
        loaded = true;
        LoadingPanel.Visibility = Visibility.Visible;
        Notice.IsOpen = false;
        RefreshButton.IsEnabled = false;
        try
        {
            await App.Ready;
            var page = await GlasstubeFFI.Home();
            Grid.ItemsSource = new FeedCollection(page.Items, page.HasMore, GlasstubeFFI.HomeMore);
            UpdateColumns();
            if (page.Items.Count == 0 || page.Notice != null)
                ShowNotice(InfoBarSeverity.Informational, page.Notice ?? "YouTube no devolvió videos para el Inicio.");
        }
        catch (Exception error)
        {
            ShowNotice(InfoBarSeverity.Error, $"No se pudo cargar el Inicio: {error.Message}");
            loaded = false;
        }
        finally
        {
            LoadingPanel.Visibility = Visibility.Collapsed;
            RefreshButton.IsEnabled = true;
        }
    }

    void ShowNotice(InfoBarSeverity severity, string message)
    {
        Notice.Severity = severity;
        Notice.Message = message;
        Notice.IsOpen = true;
    }

    void OnRefresh(object sender, RoutedEventArgs e)
    {
        Grid.ItemsSource = null;
        _ = Load();
    }

    void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is VideoCard video) App.Window?.Play(video);
    }

    /// <summary>Columnas que llenan el ancho: tantas de al menos <see cref="MinCardWidth"/> como quepan.</summary>
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
}
