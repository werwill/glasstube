using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>Resultados de búsqueda (solo videos) en la cuadrícula adaptable. El parámetro de navegación es el texto.</summary>
public sealed partial class SearchPage : Page
{
    public SearchPage() => InitializeComponent();

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        var query = e.Parameter as string ?? "";
        TitleText.Text = $"Resultados de «{query}»";
        if (e.NavigationMode == NavigationMode.Back && Results.ItemsSource != null) return;
        LoadingPanel.Visibility = Visibility.Visible;
        try
        {
            await App.Ready;
            var page = await GlasstubeFFI.Search(query);
            Results.ItemsSource = new FeedCollection(page.Items, page.HasMore, GlasstubeFFI.SearchMore);
            if (page.Items.Count == 0) ShowNotice(InfoBarSeverity.Informational, page.Notice ?? "Sin videos para esta búsqueda.");
        }
        catch (Exception error)
        {
            ShowNotice(InfoBarSeverity.Error, $"No se pudo buscar: {error.Message}");
        }
        finally
        {
            LoadingPanel.Visibility = Visibility.Collapsed;
        }
    }

    void ShowNotice(InfoBarSeverity severity, string message)
    {
        Notice.Severity = severity;
        Notice.Message = message;
        Notice.IsOpen = true;
    }

    void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is VideoCard video) App.Window?.Play(video);
    }
}
