using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>
/// Página de un canal (gt_channel): cabecera y una pestaña a la vez, con carga incremental (gt_feed_more). Suscribirse
/// con la sesión guardada (gt_subscription_state y gt_subscribe). El parámetro de navegación es un <see cref="ChannelRef"/>.
/// </summary>
public sealed partial class ChannelPage : Page
{
    ChannelRef? channel;
    SubscriptionState? subscription;
    bool loading;
    bool busy;

    public ChannelPage() => InitializeComponent();

    /// <summary>"channel:UC…": la entrada del panel Canales que corresponde (si el canal está ahí).</summary>
    public string Section => channel == null ? "" : $"channel:{channel.Id}";

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is not ChannelRef target) return;
        // Volver atrás a la misma página (en caché) la deja como estaba.
        if (e.NavigationMode == NavigationMode.Back && channel?.Id == target.Id && Results.ItemsSource != null) return;
        channel = target;
        TitleText.Text = target.Name ?? "";
        MetaText.Text = DescriptionText.Text = "";
        Avatar.DisplayName = target.Name ?? "";
        Avatar.ProfilePicture = null;
        BannerHost.Visibility = Visibility.Collapsed;
        SubscribeButton.Visibility = Visibility.Collapsed;
        subscription = null;
        foreach (var tab in Tabs.Items) tab.Visibility = Visibility.Visible;
        if (Tabs.SelectedItem != VideosTab) Tabs.SelectedItem = VideosTab; // dispara la carga
        else _ = Load("videos");
        _ = LoadSubscription(target.Id);
    }

    async Task Load(string tab)
    {
        if (channel is not { } target || loading) return;
        loading = true;
        Notice.IsOpen = false;
        Loading.IsActive = true;
        Results.ItemsSource = null;
        try
        {
            await App.Ready;
            var info = await GlasstubeFFI.Channel(target.Id, tab);
            if (!ReferenceEquals(channel, target)) return; // se fue a otro canal mientras cargaba
            ShowHeader(info);
            Results.ItemsSource = GlasstubeFFI.Collection(info.Items, info.Feed);
            // YouTube devuelve otra pestaña si el canal no tiene la pedida.
            if (info.Tab != null && info.Tab != tab || info.Items.Count == 0)
                ShowNotice(InfoBarSeverity.Informational, "Este canal no tiene nada en esta pestaña.");
        }
        catch (Exception error)
        {
            ShowNotice(InfoBarSeverity.Error, $"No se pudo abrir el canal: {error.Message}");
        }
        finally
        {
            loading = false;
            Loading.IsActive = false;
        }
    }

    void ShowHeader(ChannelInfo info)
    {
        var title = info.Title ?? channel?.Name ?? "";
        TitleText.Text = title;
        Avatar.DisplayName = title;
        MetaText.Text = string.Join(" · ", new[] { info.Handle, info.Subscribers, info.VideoCount }.Where(s => !string.IsNullOrWhiteSpace(s)));
        DescriptionText.Text = info.Description?.Replace('\n', ' ').Trim() ?? "";
        if (info.Avatar != null) Avatar.ProfilePicture = new BitmapImage(new Uri(info.Avatar)) { DecodePixelWidth = 96 };
        if (info.Banner != null)
        {
            BannerImage.Source = new BitmapImage(new Uri(info.Banner));
            BannerHost.Visibility = Visibility.Visible;
        }
        // Solo las pestañas que tiene el canal (si YouTube las dio).
        if (info.Tabs.Count > 0)
            foreach (var tab in Tabs.Items)
                tab.Visibility = info.Tabs.Contains((string)tab.Tag) || tab.IsSelected ? Visibility.Visible : Visibility.Collapsed;
    }

    void ShowNotice(InfoBarSeverity severity, string message)
    {
        Notice.Severity = severity;
        Notice.Message = message;
        Notice.IsOpen = true;
    }

    void OnTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (sender.SelectedItem?.Tag is string tab) _ = Load(tab);
    }

    void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is VideoCard card) App.Window?.Open(card);
    }

    // MARK: Suscripción

    async Task LoadSubscription(string channelId)
    {
        try
        {
            await App.Ready;
            if (CaptureMode.Enabled) return; // --capturas: sin el estado de la cuenta
            var state = await GlasstubeFFI.SubscriptionStateOf(channelId);
            if (channel?.Id != channelId) return;
            subscription = state;
            UpdateSubscribe();
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"canal {channelId}: sin estado de suscripción: {error.Message}");
        }
    }

    void UpdateSubscribe()
    {
        if (subscription is not { SignedIn: true, IsSubscribed: { } subscribed })
        {
            SubscribeButton.Visibility = Visibility.Collapsed;
            return;
        }
        SubscribeButton.Visibility = Visibility.Visible;
        SubscribeText.Text = subscribed ? "Suscrito" : "Suscribirse";
        SubscribeIcon.Glyph = subscribed ? "" : "";
        SubscribeButton.Style = subscribed ? (Style)Application.Current.Resources["DefaultButtonStyle"]
                                           : (Style)Application.Current.Resources["AccentButtonStyle"];
        ToolTipService.SetToolTip(SubscribeButton, subscribed ? "Anular la suscripción" : "Suscribirse al canal");
    }

    async void OnSubscribeClick(object sender, RoutedEventArgs e)
    {
        if (channel == null || busy || subscription is not { IsSubscribed: { } subscribed }) return;
        if (subscribed)
        {
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot, Title = "¿Anular la suscripción?",
                Content = $"Dejarás de ver los videos de {TitleText.Text} en Suscripciones.",
                PrimaryButtonText = "Anular suscripción", CloseButtonText = "Cancelar", DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        }
        busy = true;
        try
        {
            await GlasstubeFFI.Subscribe(channel.Id, !subscribed, subscription.Params);
            subscription = subscription with { IsSubscribed = !subscribed };
            UpdateSubscribe();
            _ = SubscriptionsStore.Shared.LoadAsync(force: true);
        }
        catch (Exception error)
        {
            ShowNotice(InfoBarSeverity.Error, $"No se pudo cambiar la suscripción: {error.Message}");
        }
        finally
        {
            busy = false;
        }
    }
}
