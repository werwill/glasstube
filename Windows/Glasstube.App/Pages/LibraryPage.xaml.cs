using Glasstube.Controls;
using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>
/// Biblioteca: Ver más tarde de esta PC (gt_library) y, con sesión, el Ver más tarde y las listas de la cuenta
/// (gt_account_library). Las listas abren su página.
/// </summary>
public sealed partial class LibraryPage : Page
{
    public LibraryPage() => InitializeComponent();

    public string Section => "library";

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        Notice.IsOpen = false;
        await App.Ready;
        await LoadLocal();
        await LoadAccount();
    }

    async Task LoadLocal()
    {
        try
        {
            var library = await GlasstubeFFI.Library();
            LocalWatchLater.Videos = library.WatchLater;
            LocalWatchLater.Visibility = library.WatchLater.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            LocalEmpty.Visibility = library.WatchLater.Count > 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        catch (Exception error)
        {
            ShowNotice(InfoBarSeverity.Error, $"No se pudo leer la biblioteca local: {error.Message}");
        }
    }

    async Task LoadAccount()
    {
        // --capturas: sin la cuenta.
        if (CaptureMode.Enabled)
        {
            MetaText.Text = "En esta PC";
            return;
        }
        Loading.IsActive = true;
        try
        {
            var account = await GlasstubeFFI.AccountLibrary();
            if (!account.SignedIn)
            {
                MetaText.Text = "En esta PC · sin sesión de YouTube";
                return;
            }
            MetaText.Text = "En esta PC y en tu cuenta de YouTube";
            AccountWatchLater.Videos = account.WatchLater;
            if (account.WatchLaterFeed != null) AccountWatchLater.Count = $"{account.WatchLater.Count}+ videos";
            AccountWatchLaterSection.Visibility = account.WatchLater.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            AllWatchLater.Visibility = account.WatchLaterFeed != null ? Visibility.Visible : Visibility.Collapsed;
            Playlists.Videos = account.Playlists;
            Playlists.Count = account.Playlists.Count == 1 ? "1 lista" : $"{account.Playlists.Count} listas";
            Playlists.Visibility = account.Playlists.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            if (account.Notice != null) ShowNotice(InfoBarSeverity.Warning, $"YouTube no dio todo: {account.Notice}");
        }
        catch (Exception error)
        {
            ShowNotice(InfoBarSeverity.Error, $"No se pudo leer la biblioteca de la cuenta: {error.Message}");
        }
        finally
        {
            Loading.IsActive = false;
        }
    }

    void ShowNotice(InfoBarSeverity severity, string message)
    {
        Notice.Severity = severity;
        Notice.Message = message;
        Notice.IsOpen = true;
    }

    void OnVideoInvoked(object? sender, VideoCard card) => App.Window?.Open(card);

    void OnAllWatchLater(object sender, RoutedEventArgs e) => App.Window?.OpenPlaylist("WL", "Ver más tarde");

    void OnLocalContext(object? sender, VideoContextEventArgs e)
    {
        var remove = new MenuFlyoutItem { Text = "Quitar de Ver más tarde", Icon = new FontIcon { Glyph = "" } };
        remove.Click += async (_, _) =>
        {
            try
            {
                await GlasstubeFFI.ToggleWatchLater(e.Video);
                await LoadLocal();
            }
            catch (Exception error)
            {
                ShowNotice(InfoBarSeverity.Error, $"No se pudo quitar: {error.Message}");
            }
        };
        new MenuFlyout { Items = { remove } }.ShowAt(e.Target);
    }
}
