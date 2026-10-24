using Glasstube.Native;
using Glasstube.Pages;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using Windows.Foundation;
using Windows.Graphics;
using Windows.UI;

namespace Glasstube;

/// <summary>Página que ocupa toda la ventana, detrás del panel y de la barra de título (sin margen).</summary>
public interface IFullBleedPage
{
    /// <summary>Si la ventana debe quedarse solo con el botón de atrás (reproductor).</summary>
    bool HidesChrome { get; }
}

public sealed partial class MainWindow : Window
{
    /// <summary>Por encima de este ancho (DIP) el panel va abierto; por debajo, solo iconos.</summary>
    const double ExpandedMinWidth = 1000;
    /// <summary>Por debajo, el panel se esconde y el botón de menú lo abre encima del contenido.</summary>
    const double CompactMinWidth = 640;
    const double PaneOpenWidth = 240;
    const double PaneCompactWidth = 56;
    const double PaneMargin = 8;
    const double TitleBarHeight = 48;
    const double SearchMaxWidth = 480;

    /// <summary>Con la ventana ancha, el usuario plegó el panel con el botón de menú.</summary>
    bool paneCollapsedByUser;
    /// <summary>Panel abierto encima del contenido (ventana estrecha).</summary>
    bool paneOverlayOpen;
    bool chromeHidden;
    bool chromeFaded;
    bool selectingFromNavigation;
    bool searchFocused;
    Rect[] passthrough = [];

    public MainWindow()
    {
        InitializeComponent();
        SystemBackdrop = DesktopAcrylicController.IsSupported() ? new DesktopAcrylicBackdrop()
            : MicaController.IsSupported() ? new MicaBackdrop() : null;

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.Resize(new SizeInt32(1440, 900));
        AppTitleBar.LayoutUpdated += (_, _) => UpdatePassthrough();
        UpdateCaptionColors();

        NavList.SelectedItem = HomeItem;
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
            // La FFI no da el correo aparte: el byline de la cuenta es el correo (o el @ de una cuenta de marca).
            AccountByline.Text = account.Byline ?? (session.AccountCount > 1 ? $"{session.AccountCount} cuentas" : "");
            AccountPicture.DisplayName = AccountFlyoutPicture.DisplayName = account.Name;
            if (account.Avatar != null)
                AccountPicture.ProfilePicture = AccountFlyoutPicture.ProfilePicture = new BitmapImage(new Uri(account.Avatar));
            ToolTipService.SetToolTip(AccountButton, account.Name);
            AccountButton.Visibility = Visibility.Visible;
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"sesión: {error.Message}");
        }
    }

    // MARK: Navegación

    void OnNavSelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (selectingFromNavigation || sender is not ListView list || list.SelectedItem is not ListViewItem item) return;
        // Una sola selección entre las listas del panel.
        selectingFromNavigation = true;
        foreach (var other in new[] { NavList, FooterList, ChannelList })
            if (!ReferenceEquals(other, list)) other.SelectedItem = null;
        selectingFromNavigation = false;

        CloseOverlayPane();
        var tag = item.Tag as string ?? "home";
        if (tag == CurrentTag) return;
        if (tag == "home")
            ContentFrame.Navigate(typeof(HomePage), null, new EntranceNavigationTransitionInfo());
        else
            ContentFrame.Navigate(typeof(PlaceholderPage), tag, new EntranceNavigationTransitionInfo());
    }

    /// <summary>Sección del panel que corresponde a la página visible (null en el reproductor y la búsqueda).</summary>
    string? CurrentTag => ContentFrame.Content switch
    {
        HomePage => "home",
        PlaceholderPage placeholder => placeholder.Section,
        _ => null,
    };

    /// <summary>La página visible.</summary>
    public object? CurrentPage => ContentFrame.Content;

    public void GoBack()
    {
        if (ContentFrame.CanGoBack) ContentFrame.GoBack();
    }

    /// <summary>Abre el reproductor de un video.</summary>
    public void Play(Models.VideoCard video) =>
        ContentFrame.Navigate(typeof(PlayerPage), video, new DrillInNavigationTransitionInfo());

    void OnNavigated(object sender, NavigationEventArgs e)
    {
        BackButton.IsEnabled = ContentFrame.CanGoBack;
        chromeHidden = (e.Content as IFullBleedPage)?.HidesChrome == true;
        chromeFaded = false;
        BackButton.Opacity = 1;

        // Al volver de un reproductor, la selección del panel sigue a la página.
        var tag = CurrentTag;
        selectingFromNavigation = true;
        foreach (var list in new[] { NavList, FooterList, ChannelList })
        {
            var match = tag == null ? null : list.Items.OfType<ListViewItem>().FirstOrDefault(i => (string)i.Tag == tag);
            if (!ReferenceEquals(list.SelectedItem, match)) list.SelectedItem = match;
        }
        selectingFromNavigation = false;

        CloseOverlayPane();
        ApplyLayout();
        UpdateCaptionColors();
    }

    void OnBackClick(object sender, RoutedEventArgs e) => GoBack();

    void OnBackKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        GoBack();
    }

    // MARK: Búsqueda

    void OnSearchKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (SearchHost.Visibility != Visibility.Visible) return;
        args.Handled = true;
        SearchBox.Focus(FocusState.Keyboard);
    }

    void OnSearchSubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        var text = args.QueryText.Trim();
        if (text.Length == 0) return;
        // La FFI aún no tiene búsqueda: la página solo muestra lo que se buscó.
        ContentFrame.Navigate(typeof(SearchPage), text, new EntranceNavigationTransitionInfo());
    }

    // El foco lo tiene el TextBox de dentro (la AutoSuggestBox sigue en Unfocused): se siguen sus eventos.
    void OnSearchGotFocus(object sender, RoutedEventArgs e)
    {
        searchFocused = true;
        UpdateSearchHint();
    }

    void OnSearchLostFocus(object sender, RoutedEventArgs e)
    {
        searchFocused = FocusManager.GetFocusedElement(Root.XamlRoot) is DependencyObject focused && IsInside(focused, SearchBox);
        UpdateSearchHint();
    }

    void OnSearchTextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args) => UpdateSearchHint();

    void UpdateSearchHint()
    {
        var hidden = searchFocused || SearchBox.Text.Length > 0 || SearchHost.Width < 320;
        SearchHint.Visibility = hidden ? Visibility.Collapsed : Visibility.Visible;
    }

    static bool IsInside(DependencyObject node, DependencyObject ancestor)
    {
        for (DependencyObject? current = node; current != null; current = VisualTreeHelper.GetParent(current))
            if (ReferenceEquals(current, ancestor)) return true;
        return false;
    }

    // MARK: Panel y diseño adaptable

    void OnPaneToggleClick(object sender, RoutedEventArgs e)
    {
        if (DockedPaneWidth(ignoreUser: true) == PaneOpenWidth && !paneOverlayOpen)
            paneCollapsedByUser = !paneCollapsedByUser;
        else
            paneOverlayOpen = !paneOverlayOpen;
        ApplyLayout();
    }

    void OnDismissTapped(object sender, TappedRoutedEventArgs e) => CloseOverlayPane();

    void CloseOverlayPane()
    {
        if (!paneOverlayOpen) return;
        paneOverlayOpen = false;
        ApplyLayout();
    }

    void OnRootSizeChanged(object sender, SizeChangedEventArgs e)
    {
        // Al ensanchar la ventana, el panel encima se vuelve panel fijo.
        if (paneOverlayOpen && DockedPaneWidth() == PaneOpenWidth) paneOverlayOpen = false;
        ApplyLayout();
    }

    /// <summary>Ancho del panel fijo (0 si está escondido) según el ancho de la ventana.</summary>
    double DockedPaneWidth(bool ignoreUser = false)
    {
        var width = Root.ActualWidth;
        if (width >= ExpandedMinWidth) return paneCollapsedByUser && !ignoreUser ? PaneCompactWidth : PaneOpenWidth;
        return width >= CompactMinWidth ? PaneCompactWidth : 0;
    }

    /// <summary>Coloca el panel, el margen de la página y la barra de título según el ancho y la página.</summary>
    void ApplyLayout()
    {
        var width = Root.ActualWidth;
        if (width <= 0) return;
        var docked = DockedPaneWidth();

        // Panel
        var paneWidth = paneOverlayOpen ? PaneOpenWidth : docked;
        Pane.Visibility = !chromeHidden && paneWidth > 0 ? Visibility.Visible : Visibility.Collapsed;
        Pane.Width = paneWidth;
        Pane.Translation = new System.Numerics.Vector3(0, 0, paneOverlayOpen ? 32 : 8);
        DismissLayer.Visibility = paneOverlayOpen && !chromeHidden ? Visibility.Visible : Visibility.Collapsed;
        SetPaneLabelsVisible(paneWidth >= PaneOpenWidth);

        // Página: las normales no quedan debajo del panel fijo ni de la barra de título.
        ContentFrame.Margin = ContentFrame.Content is IFullBleedPage ? new Thickness(0)
            : new Thickness(docked > 0 ? PaneMargin + docked : 0, TitleBarHeight, 0, 0);

        // Barra de título: en el reproductor solo queda el botón de atrás (y los de la ventana).
        var chrome = chromeHidden ? Visibility.Collapsed : Visibility.Visible;
        PaneToggle.Visibility = RightChrome.Visibility = chrome;
        AppName.Visibility = !chromeHidden && width >= 760 ? Visibility.Visible : Visibility.Collapsed;
        LayoutSearch(width);
    }

    /// <summary>La búsqueda va centrada en la ventana si cabe; si no, llena el hueco entre los dos lados.</summary>
    void LayoutSearch(double width)
    {
        if (chromeHidden)
        {
            SearchHost.Visibility = Visibility.Collapsed;
            return;
        }
        var caption = AppWindow.TitleBar.RightInset / Scale;
        CaptionColumn.Width = new GridLength(caption);
        LeftChrome.Measure(new Size(double.PositiveInfinity, TitleBarHeight));
        RightChrome.Measure(new Size(double.PositiveInfinity, TitleBarHeight));
        var left = LeftChrome.DesiredSize.Width + 12;
        var right = RightChrome.DesiredSize.Width + caption + 12;

        var centered = Math.Min(SearchMaxWidth, width - 2 * Math.Max(left, right));
        if (centered >= 260)
        {
            SearchHost.HorizontalAlignment = HorizontalAlignment.Center;
            SearchHost.Margin = new Thickness(0);
            SearchHost.Width = centered;
        }
        else
        {
            SearchHost.HorizontalAlignment = HorizontalAlignment.Left;
            SearchHost.Margin = new Thickness(left, 0, 0, 0);
            SearchHost.Width = Math.Min(SearchMaxWidth, Math.Max(0, width - left - right));
        }
        SearchHost.Visibility = SearchHost.Width >= 120 ? Visibility.Visible : Visibility.Collapsed;
        UpdateSearchHint();
    }

    void SetPaneLabelsVisible(bool visible)
    {
        var state = visible ? Visibility.Visible : Visibility.Collapsed;
        foreach (var item in NavList.Items.Concat(FooterList.Items).OfType<ListViewItem>())
        {
            var panel = item.Content as StackPanel ?? (item.Content as Grid)?.Children.OfType<StackPanel>().First();
            if (panel?.Children.OfType<TextBlock>().FirstOrDefault() is { } label) label.Visibility = state;
            // Con solo iconos, el nombre sale en el tooltip.
            ToolTipService.SetToolTip(item, visible ? null : panel?.Children.OfType<TextBlock>().First().Text);
        }
        ChannelsHeader.Visibility = state;
    }

    double Scale => Root.XamlRoot?.RasterizationScale ?? 1;

    // MARK: Barra de título

    /// <summary>
    /// Zonas de la barra de título que reciben clics (botones, búsqueda, cuenta); el resto arrastra la ventana. Se
    /// recalcula tras cada pasada de diseño y solo se manda a Windows si cambió.
    /// </summary>
    void UpdatePassthrough()
    {
        if (Root.XamlRoot == null) return;
        var scale = Scale;
        var rects = new List<Rect>();
        foreach (FrameworkElement element in new FrameworkElement[] { BackButton, PaneToggle, SearchHost, AccountButton })
        {
            if (!IsShown(element)) continue;
            var bounds = element.TransformToVisual(null).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
            rects.Add(new Rect(bounds.X * scale, bounds.Y * scale, bounds.Width * scale, bounds.Height * scale));
        }
        if (rects.SequenceEqual(passthrough)) return;
        passthrough = [.. rects];
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough,
            rects.Select(r => new RectInt32((int)Math.Round(r.X), (int)Math.Round(r.Y),
                                            (int)Math.Round(r.Width), (int)Math.Round(r.Height))).ToArray());
    }

    static bool IsShown(FrameworkElement element)
    {
        for (DependencyObject? node = element; node is UIElement ui; node = VisualTreeHelper.GetParent(node))
            if (ui.Visibility != Visibility.Visible) return false;
        return element.ActualWidth > 0;
    }

    void OnThemeChanged(FrameworkElement sender, object args) => UpdateCaptionColors();

    /// <summary>
    /// Botones de la ventana sin fondo propio y con el color del tema. Encima de video (o de una imagen oscura) van en
    /// blanco.
    /// </summary>
    void UpdateCaptionColors()
    {
        var dark = chromeHidden || Root.ActualTheme == ElementTheme.Dark;
        AppTitleBar.RequestedTheme = chromeHidden ? ElementTheme.Dark : ElementTheme.Default;
        var bar = AppWindow.TitleBar;
        var foreground = dark ? Colors.White : Colors.Black;
        bar.ButtonBackgroundColor = bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        bar.ButtonForegroundColor = foreground;
        bar.ButtonInactiveForegroundColor = dark ? Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x80, 0, 0, 0);
        bar.ButtonHoverBackgroundColor = dark ? Color.FromArgb(0x18, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x10, 0, 0, 0);
        bar.ButtonHoverForegroundColor = dark ? Colors.White : Colors.Black;
        bar.ButtonPressedBackgroundColor = dark ? Color.FromArgb(0x10, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x08, 0, 0, 0);
        bar.ButtonPressedForegroundColor = foreground;
    }

    /// <summary>
    /// El reproductor esconde el botón de atrás junto con sus controles. Los botones de la ventana se quedan: Windows no
    /// acepta un color de primer plano transparente para ellos.
    /// </summary>
    public void SetChromeFaded(bool faded)
    {
        if (faded == chromeFaded || !chromeHidden) return;
        chromeFaded = faded;
        BackButton.Opacity = faded ? 0 : 1;
    }

    // MARK: Mini reproductor

    /// <summary>Tamaño inicial del mini reproductor (DIP, 16:9).</summary>
    const double MiniWidth = 400;

    /// <summary>Presentador, posición, tamaño y si estaba maximizada antes del mini reproductor.</summary>
    (AppWindowPresenterKind Kind, RectInt32 Bounds, bool Maximized)? beforeMini;
    bool fittingMini;

    public bool IsMini => AppWindow.Presenter.Kind == AppWindowPresenterKind.CompactOverlay;

    /// <summary>Cambia entre la ventana y el mini reproductor (siempre encima). El argumento dice si queda en mini.</summary>
    public event EventHandler<bool>? MiniChanged;

    public void SetMini(bool on)
    {
        if (on == IsMini) return;
        if (on)
        {
            var maximized = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
            if (IsFullScreen) AppWindow.SetPresenter(AppWindowPresenterKind.Default);
            beforeMini = (AppWindow.Presenter.Kind,
                          new RectInt32(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height),
                          maximized);
            AppWindow.SetPresenter(AppWindowPresenterKind.CompactOverlay);
            var width = (int)Math.Round(MiniWidth * Scale);
            AppWindow.Resize(new SizeInt32(width, width * 9 / 16));
            AppWindow.Changed += KeepMiniAspect;
        }
        else
        {
            AppWindow.Changed -= KeepMiniAspect;
            AppWindow.SetPresenter(beforeMini?.Kind ?? AppWindowPresenterKind.Default);
            if (beforeMini is { } before)
            {
                if (before.Maximized && AppWindow.Presenter is OverlappedPresenter overlapped) overlapped.Maximize();
                else AppWindow.MoveAndResize(before.Bounds);
            }
            beforeMini = null;
        }
        // En mini no queda ni el botón de atrás: solo los controles del reproductor al pasar el ratón.
        BackButton.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        MiniChanged?.Invoke(this, on);
    }

    /// <summary>El mini reproductor se redimensiona a mano, pero siempre en 16:9.</summary>
    void KeepMiniAspect(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (!args.DidSizeChange || fittingMini || !IsMini) return;
        var size = sender.Size;
        var height = size.Width * 9 / 16;
        if (Math.Abs(height - size.Height) <= 2) return;
        fittingMini = true;
        sender.Resize(new SizeInt32(size.Width, height));
        fittingMini = false;
    }

    // MARK: Pantalla completa

    public bool IsFullScreen => AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;

    /// <summary>Pantalla completa para el reproductor (la ventana ya va sin panel ni búsqueda).</summary>
    public void SetFullScreen(bool on)
    {
        if (on == IsFullScreen) return;
        AppWindow.SetPresenter(on ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Default);
    }
}
