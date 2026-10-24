using Glasstube.Native;
using Glasstube.Pages;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1440, 900));
        Nav.SelectedItem = HomeItem;
        _ = LoadAccount();
    }

    async Task LoadAccount()
    {
        try
        {
            await App.Ready;
            var session = await GlasstubeFFI.LoadSession();
            if (session.Selected is not { } account) return;
            AccountName.Text = account.Name;
            AccountByline.Text = account.Byline ?? (session.AccountCount > 1 ? $"{session.AccountCount} cuentas" : "");
            AccountPicture.DisplayName = account.Name;
            if (account.Avatar != null) AccountPicture.ProfilePicture = new BitmapImage(new Uri(account.Avatar));
            AccountPanel.Visibility = Visibility.Visible;
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"sesión: {error.Message}");
        }
    }

    void OnSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var tag = (args.SelectedItem as NavigationViewItem)?.Tag as string ?? "home";
        if (tag == CurrentTag) return;
        if (tag == "home")
            ContentFrame.Navigate(typeof(HomePage), null, new EntranceNavigationTransitionInfo());
        else
            ContentFrame.Navigate(typeof(PlaceholderPage), tag, new EntranceNavigationTransitionInfo());
    }

    /// <summary>Sección del panel que corresponde a la página visible (null en el reproductor).</summary>
    string? CurrentTag => ContentFrame.Content switch
    {
        HomePage => "home",
        PlaceholderPage placeholder => placeholder.Section,
        _ => null,
    };

    void OnBackRequested(NavigationView sender, NavigationViewBackRequestedEventArgs args) => GoBack();

    public void GoBack()
    {
        if (ContentFrame.CanGoBack) ContentFrame.GoBack();
    }

    /// <summary>Abre el reproductor de un video.</summary>
    public void Play(Models.VideoCard video) =>
        ContentFrame.Navigate(typeof(PlayerPage), video, new DrillInNavigationTransitionInfo());

    void OnNavigated(object sender, NavigationEventArgs e)
    {
        // Al volver de un reproductor, la selección del panel sigue a la página.
        var tag = e.SourcePageType == typeof(HomePage) ? "home"
            : e.SourcePageType == typeof(PlaceholderPage) ? e.Parameter as string : null;
        if (tag == null) return;
        foreach (var item in Nav.MenuItems.OfType<NavigationViewItem>())
            if ((string)item.Tag == tag && !ReferenceEquals(Nav.SelectedItem, item)) Nav.SelectedItem = item;
    }

    public bool IsFullScreen => AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;

    /// <summary>Pantalla completa para el reproductor: sin panel ni barra de título.</summary>
    public void SetFullScreen(bool on)
    {
        if (on == IsFullScreen) return;
        AppWindow.SetPresenter(on ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Default);
        Nav.IsPaneVisible = !on;
        Nav.Margin = on ? new Thickness(0) : new Thickness(0, 48, 0, 0);
        AppTitleBar.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        TitleRow.Height = on ? new GridLength(0) : new GridLength(48);
    }
}
