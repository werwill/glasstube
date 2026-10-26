using System.Collections.ObjectModel;
using Glasstube.Controls;
using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>Historial de esta PC (gt_library): tarjetas con su progreso, quitar una o borrarlo todo.</summary>
public sealed partial class HistoryPage : Page
{
    readonly ObservableCollection<VideoCard> videos = [];

    public HistoryPage()
    {
        InitializeComponent();
        Results.ItemsSource = videos;
    }

    public string Section => "history";

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        try
        {
            await App.Ready;
            var library = await GlasstubeFFI.Library();
            videos.Clear();
            foreach (var video in library.History) videos.Add(video);
            Update();
        }
        catch (Exception error)
        {
            ShowNotice(InfoBarSeverity.Error, $"No se pudo leer el historial: {error.Message}");
        }
    }

    void Update()
    {
        MetaText.Text = videos.Count == 1 ? "1 video · en esta PC" : $"{videos.Count} videos · en esta PC";
        ClearButton.IsEnabled = videos.Count > 0;
        if (videos.Count == 0) ShowNotice(InfoBarSeverity.Informational, "Todavía no has visto nada. Lo que veas aparecerá aquí.");
        else Notice.IsOpen = false;
    }

    void ShowNotice(InfoBarSeverity severity, string message)
    {
        Notice.Severity = severity;
        Notice.Message = message;
        Notice.IsOpen = true;
    }

    void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is VideoCard video) App.Window?.Open(video);
    }

    void OnItemContext(object? sender, VideoContextEventArgs e)
    {
        var remove = new MenuFlyoutItem { Text = "Quitar del historial", Icon = new FontIcon { Glyph = "" } };
        remove.Click += async (_, _) => await Remove(e.Video);
        var channel = new MenuFlyoutItem { Text = "Ver el canal", Icon = new FontIcon { Glyph = "" }, IsEnabled = e.Video.ChannelId != null };
        channel.Click += (_, _) => App.Window?.OpenChannel(e.Video.ChannelId!, e.Video.Channel);
        var menu = new MenuFlyout { Items = { remove, channel } };
        menu.ShowAt(e.Target);
    }

    async Task Remove(VideoCard video)
    {
        try
        {
            await GlasstubeFFI.RemoveFromHistory(video.Id);
            videos.Remove(video);
            Update();
        }
        catch (Exception error)
        {
            ShowNotice(InfoBarSeverity.Error, $"No se pudo quitar: {error.Message}");
        }
    }

    async void OnClear(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "¿Borrar el historial?",
            Content = $"Se borrarán los {videos.Count} videos del historial de esta PC, con sus posiciones de «Continuar viendo». No se puede deshacer.",
            PrimaryButtonText = "Borrar historial", CloseButtonText = "Cancelar", DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            await GlasstubeFFI.ClearHistory();
            videos.Clear();
            Update();
        }
        catch (Exception error)
        {
            ShowNotice(InfoBarSeverity.Error, $"No se pudo borrar: {error.Message}");
        }
    }
}
