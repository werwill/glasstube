using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>Una lista de reproducción (de un canal o de la cuenta). El parámetro de navegación es un <see cref="PlaylistRef"/>.</summary>
public sealed partial class PlaylistPage : Page
{
    public PlaylistPage() => InitializeComponent();

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is not PlaylistRef playlist) return;
        TitleText.Text = playlist.Title ?? "Lista";
        Loading.IsActive = true;
        try
        {
            await App.Ready;
            var info = await GlasstubeFFI.Playlist(playlist.Id);
            if (!string.IsNullOrWhiteSpace(info.Title)) TitleText.Text = info.Title;
            MetaText.Text = info.HasMore ? $"{info.Items.Count}+ videos" : info.Items.Count == 1 ? "1 video" : $"{info.Items.Count} videos";
            Results.ItemsSource = GlasstubeFFI.Collection(info.Items, info.Feed);
            if (info.Items.Count == 0)
            {
                Notice.Severity = Microsoft.UI.Xaml.Controls.InfoBarSeverity.Informational;
                Notice.Message = "Esta lista está vacía.";
                Notice.IsOpen = true;
            }
        }
        catch (Exception error)
        {
            Notice.Severity = Microsoft.UI.Xaml.Controls.InfoBarSeverity.Error;
            Notice.Message = $"No se pudo abrir la lista: {error.Message}";
            Notice.IsOpen = true;
        }
        finally
        {
            Loading.IsActive = false;
        }
    }

    void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is VideoCard card) App.Window?.Open(card);
    }
}
