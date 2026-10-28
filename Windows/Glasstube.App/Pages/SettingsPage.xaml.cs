using System.Diagnostics;
using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>Configuración: cuenta, tema, vista previa, reproductor, DeArrow, actualizaciones y datos de esta PC.</summary>
public sealed partial class SettingsPage : Page
{
    /// <summary>Mientras se rellenan los controles, sus eventos no guardan nada.</summary>
    bool loading;
    bool signedIn;

    public string Section => "settings";

    public SettingsPage() => InitializeComponent();

    static AppSettings Prefs => AppSettings.Shared;
    static PlayerSettings Player => PlayerSettings.Shared;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        loading = true;
        ThemeBox.SelectedItem = ThemeBox.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == Prefs.Theme)
                                ?? ThemeBox.Items[0];
        BackdropBox.SelectedItem = BackdropBox.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == Prefs.Backdrop)
                                   ?? BackdropBox.Items[0];
        HoverSwitch.IsOn = Prefs.HoverPreviews;
        QualityBox.SelectedItem = QualityBox.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == Player.Quality.ToString())
                                  ?? QualityBox.Items[0];
        CaptionsSwitch.IsOn = Player.CaptionsOn;
        AutoplaySwitch.IsOn = Player.Autoplay;
        DeArrowSwitch.IsOn = Prefs.DeArrowEnabled;
        DeArrowTitlesBox.IsChecked = Prefs.DeArrowTitles;
        DeArrowThumbnailsBox.IsChecked = Prefs.DeArrowThumbnails;
        DeArrowOptions.Opacity = Prefs.DeArrowEnabled ? 1 : 0.5;
        DeArrowOptions.IsHitTestVisible = Prefs.DeArrowEnabled;
        UpdatesSwitch.IsOn = Prefs.CheckForUpdates;
        VersionText.Text = $"Glasstube {UpdateCheck.Current.ToString(3)} para Windows";
        try { LogText.Text = Path.Combine(GlasstubeFFI.LogDirectory(), "glasstube.log"); }
        catch { LogText.Text = @"%LOCALAPPDATA%\Glasstube\logs"; }
        loading = false;
        _ = LoadAccount();
    }

    // MARK: Cuenta

    async Task LoadAccount()
    {
        AccountButton.IsEnabled = false;
        try
        {
            await App.Ready;
            var accounts = await GlasstubeFFI.Accounts();
            var account = accounts.Selected;
            signedIn = account != null;
            AccountName.Text = account?.Name ?? "Sin sesión";
            AccountByline.Text = account?.Byline
                ?? (account != null ? "" : "Con tu cuenta ves tu Inicio, tus suscripciones y los videos con restricción de edad.");
            AccountPicture.DisplayName = account?.Name ?? "";
            AccountPicture.ProfilePicture = account?.Avatar is { } avatar ? new BitmapImage(new Uri(avatar)) { DecodePixelWidth = 80 } : null;
            AccountButton.Content = signedIn ? "Cerrar sesión" : "Iniciar sesión";
            if (signedIn) AccountButton.ClearValue(StyleProperty);
            else AccountButton.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"configuración, cuenta: {error.Message}");
        }
        AccountButton.IsEnabled = true;
    }

    async void OnAccountClick(object sender, RoutedEventArgs e)
    {
        if (App.Window is not { } window) return;
        // Las dos vuelven al Inicio con la cuenta nueva (MainWindow.AccountChanged).
        if (signedIn) await window.SignOut();
        else await window.SignIn();
        if (window.CurrentPage == this) await LoadAccount();
    }

    // MARK: Apariencia

    void OnThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || ThemeBox.SelectedItem is not ComboBoxItem { Tag: string theme }) return;
        Prefs.Theme = theme;
        Prefs.Save();
        App.Window?.ApplyTheme();
    }

    void OnBackdropChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || BackdropBox.SelectedItem is not ComboBoxItem { Tag: string backdrop }) return;
        Prefs.Backdrop = backdrop;
        Prefs.Save();
        App.Window?.ApplyBackdrop();
    }

    void OnHoverToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        Prefs.HoverPreviews = HoverSwitch.IsOn;
        Prefs.Save();
    }

    // MARK: Reproductor

    void OnQualityChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || QualityBox.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        Player.Quality = int.Parse(tag);
        Player.Save();
    }

    void OnCaptionsToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        Player.CaptionsOn = CaptionsSwitch.IsOn;
        Player.Save();
    }

    void OnAutoplayToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        Player.Autoplay = AutoplaySwitch.IsOn;
        Player.Save();
    }

    // MARK: DeArrow

    void OnDeArrowToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        Prefs.DeArrowEnabled = DeArrowSwitch.IsOn;
        DeArrowOptions.Opacity = Prefs.DeArrowEnabled ? 1 : 0.5;
        DeArrowOptions.IsHitTestVisible = Prefs.DeArrowEnabled;
        Prefs.Save();
    }

    void OnDeArrowOptionClick(object sender, RoutedEventArgs e)
    {
        Prefs.DeArrowTitles = DeArrowTitlesBox.IsChecked == true;
        Prefs.DeArrowThumbnails = DeArrowThumbnailsBox.IsChecked == true;
        Prefs.Save();
    }

    // MARK: Actualizaciones

    void OnUpdatesToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        Prefs.CheckForUpdates = UpdatesSwitch.IsOn;
        Prefs.Save();
    }

    async void OnCheckNowClick(object sender, RoutedEventArgs e)
    {
        if (App.Window?.Content is not Grid root) return;
        CheckNowButton.IsEnabled = false;
        UpdateText.Text = "Buscando…";
        var found = await UpdateCheck.RunAsync(root, force: true);
        UpdateText.Text = found switch
        {
            true => "Hay una versión nueva: el aviso está abajo a la derecha.",
            false => "Tienes la versión más nueva.",
            null => "No se pudo consultar GitHub. Prueba más tarde.",
        };
        CheckNowButton.IsEnabled = true;
    }

    // MARK: Datos

    async void OnClearHistoryClick(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "¿Borrar el historial?",
            Content = "Se borra lo que viste en esta PC, también Continuar viendo. Tu historial de YouTube no cambia.",
            PrimaryButtonText = "Borrar", CloseButtonText = "Cancelar", DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try { await GlasstubeFFI.ClearHistory(); }
        catch (Exception error) { GlasstubeFFI.Log("app", $"borrar historial: {error.Message}"); }
    }

    void OnOpenLogsClick(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo { FileName = GlasstubeFFI.LogDirectory(), UseShellExecute = true }); }
        catch (Exception error) { GlasstubeFFI.Log("app", $"abrir el registro: {error.Message}"); }
    }
}
