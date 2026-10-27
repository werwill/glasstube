using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>
/// Inicio en estilo Cine: una portada a todo el ancho (el video más nuevo de Suscripciones, o el primero del Inicio)
/// detrás del panel y de la barra de título; debajo, filas de Continuar viendo, Nuevos de tus canales y En vivo ahora;
/// y "Para ti", el Inicio de la cuenta, como cuadrícula con carga incremental.
/// </summary>
public sealed partial class HomePage : Page, IFullBleedPage
{
    bool loaded;
    bool pastHero;
    VideoCard? hero;

    public HomePage()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            if (Feed.ScrollHost is { } scroller)
            {
                scroller.ViewChanged -= OnScrolled;
                scroller.ViewChanged += OnScrolled;
            }
        };
        SizeChanged += (_, _) => Hero.Height = Math.Clamp(ActualHeight * 0.62, 420, 640);
    }

    bool insetHooked;

    public bool HidesChrome => false;

    /// <summary>Clara sobre la portada; con acrílico cuando el contenido ya pasa por debajo.</summary>
    public TitleBarStyle InitialTitleBar => pastHero || Hero.Visibility != Visibility.Visible ? TitleBarStyle.Solid : TitleBarStyle.OverImage;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        // La primera página se crea dentro del constructor de MainWindow, antes de que exista App.Window.
        if (!insetHooked && App.Window is { } window)
        {
            window.ContentInsetChanged += (_, _) => ApplyInset();
            insetHooked = true;
        }
        ApplyInset();
        if (!loaded) _ = Load();
        else _ = LoadContinueWatching();
    }

    /// <summary>El contenido empieza a la derecha del panel; la portada sigue detrás de él.</summary>
    void ApplyInset()
    {
        var left = App.Window?.ContentInset.Left ?? 248;
        HeroContent.Margin = new Thickness(left + 48, 0, 48, 150);
        foreach (var row in new[] { ContinueRow, NewRow, LiveRow }) row.ContentMargin = new Thickness(left + 32, 0, 32, 0);
        ForYouHeader.Margin = Notice.Margin = new Thickness(left + 32, 0, 32, 0);
        Feed.ItemsMargin = new Thickness(left + 28, 4, 28, 24);
    }

    async Task Load(bool refresh = false)
    {
        loaded = true;
        LoadingPanel.Visibility = Visibility.Visible;
        Notice.IsOpen = false;
        Notice.Visibility = Visibility.Collapsed;
        RefreshButton.IsEnabled = false;
        try
        {
            await App.Ready;
            // Las mismas Suscripciones que el panel y la Bandeja.
            var subscriptions = SubscriptionsStore.Shared.LoadAsync(force: refresh);
            var continueWatching = LoadContinueWatching();
            var home = await GlasstubeFFI.Home();
            Feed.ItemsSource = new FeedCollection(home.Items, home.HasMore, GlasstubeFFI.HomeMore);
            if (home.Items.Count == 0 || home.Notice != null)
                ShowNotice(InfoBarSeverity.Informational, home.Notice ?? "YouTube no devolvió videos para el Inicio.");

            await subscriptions;
            var fresh = SubscriptionsStore.Shared.Items.ToList();
            var live = fresh.Concat(home.Items).Where(v => v.IsLive).DistinctBy(v => v.Id).ToList();
            ShowRow(NewRow, fresh.Where(v => !v.IsLive).Take(24).ToList());
            ShowRow(LiveRow, live);
            ShowHero(fresh.FirstOrDefault(v => !v.IsLive) ?? home.Items.FirstOrDefault(), fromSubscriptions: fresh.Count > 0);
            await continueWatching;
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
            App.Window?.SetTitleBarStyle(InitialTitleBar);
        }
    }

    static async Task<T?> Try<T>(Task<T> task, string what) where T : class
    {
        try { return await task; }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"Inicio sin {what}: {error.Message}");
            return null;
        }
    }

    /// <summary>"Continuar viendo" (se recarga al volver del reproductor).</summary>
    async Task LoadContinueWatching()
    {
        var library = await Try(GlasstubeFFI.Library(), "biblioteca");
        ShowRow(ContinueRow, library?.ContinueWatching ?? []);
    }

    static void ShowRow(Controls.VideoRow row, List<VideoCard> videos)
    {
        row.Visibility = videos.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (videos.Count > 0) row.Videos = videos;
    }

    void ShowHero(VideoCard? video, bool fromSubscriptions)
    {
        hero = video;
        Hero.Visibility = video == null ? Visibility.Collapsed : Visibility.Visible;
        if (video == null) return;
        if ((video.ThumbnailLarge ?? video.Thumbnail) is { } source) SetHeroImage(source, video.Thumbnail);
        var when = video.Published?.ToUpperInvariant();
        var who = (video.Channel ?? "").ToUpperInvariant();
        HeroEyebrow.Text = fromSubscriptions ? $"NUEVO DE {who}" + (when != null ? $" · {when}" : "")
            : string.Join(" · ", new[] { who, when }.Where(s => !string.IsNullOrEmpty(s)));
        HeroAvatar.DisplayName = video.Channel ?? "";
        HeroAvatar.ProfilePicture = video.Avatar == null ? null : new BitmapImage(new Uri(video.Avatar));
        HeroTitle.Text = video.Title;
        HeroMeta.Text = string.Join(" · ", new[] { DurationText(video), video.Views }.Where(s => !string.IsNullOrEmpty(s)));
        SetWatchLater(false);
    }

    /// <summary>"16 min" o "1 h 4 min" para la línea de la portada.</summary>
    static string? DurationText(VideoCard video)
    {
        if (video.DurationSeconds is not { } seconds || seconds <= 0) return video.Duration;
        var time = TimeSpan.FromSeconds(seconds);
        return time.TotalHours >= 1 ? $"{(int)time.TotalHours} h {time.Minutes} min" : $"{Math.Max(1, time.Minutes)} min";
    }

    void OnHeroPlay(object sender, RoutedEventArgs e)
    {
        if (hero != null) App.Window?.Play(hero);
    }

    async void OnHeroWatchLater(object sender, RoutedEventArgs e)
    {
        if (hero == null) return;
        try { SetWatchLater(await GlasstubeFFI.ToggleWatchLater(hero)); }
        catch (Exception error) { GlasstubeFFI.Log("app", $"Ver más tarde: {error.Message}"); }
    }

    void SetWatchLater(bool inList)
    {
        HeroLaterIcon.Glyph = inList ? "" : "";
        HeroLaterText.Text = inList ? "En Ver más tarde" : "Ver más tarde";
    }

    void OnScrolled(object? sender, ScrollViewerViewChangedEventArgs e)
    {
        if (sender is not ScrollViewer scroller) return;
        var past = Hero.Visibility != Visibility.Visible || scroller.VerticalOffset > Hero.ActualHeight - 120;
        if (past == pastHero) return;
        pastHero = past;
        App.Window?.SetTitleBarStyle(InitialTitleBar);
    }

    void ShowNotice(InfoBarSeverity severity, string message)
    {
        Notice.Severity = severity;
        Notice.Message = message;
        Notice.IsOpen = true;
        Notice.Visibility = Visibility.Visible;
    }

    void OnNoticeClosed(InfoBar sender, InfoBarClosedEventArgs args) => Notice.Visibility = Visibility.Collapsed;

    void OnRefresh(object sender, RoutedEventArgs e) => Reload();

    /// <summary>Todo de nuevo (también al cambiar de cuenta).</summary>
    public void Reload()
    {
        Feed.ItemsSource = null;
        _ = Load(refresh: true);
    }

    void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is VideoCard video) App.Window?.Play(video);
    }

    void OnRowVideo(object? sender, VideoCard video) => App.Window?.Play(video);
}
