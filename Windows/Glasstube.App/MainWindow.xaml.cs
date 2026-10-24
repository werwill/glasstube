using Glasstube.Models;
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

/// <summary>Cómo se ve la barra de título sobre la página.</summary>
public enum TitleBarStyle
{
    /// <summary>Sin fondo, con los colores del tema (páginas normales, que empiezan debajo de la barra).</summary>
    Normal,
    /// <summary>Sin fondo y en claro, sobre una imagen oscura (la portada del Inicio, el video).</summary>
    OverImage,
    /// <summary>Con fondo de acrílico, cuando el contenido pasa por debajo (el Inicio desplazado).</summary>
    Solid,
}

/// <summary>
/// Página que ocupa toda la ventana, detrás del panel y de la barra de título (sin margen). Deja libre
/// <see cref="MainWindow.ContentInset"/> para su contenido normal.
/// </summary>
public interface IFullBleedPage
{
    /// <summary>Si la ventana debe quedarse solo con el botón de atrás (reproductor).</summary>
    bool HidesChrome { get; }

    /// <summary>La barra de título al entrar en la página (la página la cambia luego con SetTitleBarStyle).</summary>
    TitleBarStyle InitialTitleBar => TitleBarStyle.OverImage;
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
    TitleBarStyle titleBarStyle;
    Rect[] passthrough = [];

    /// <summary>
    /// Lo que tapan el panel fijo y la barra de título. Las páginas normales ya lo llevan de margen; las de
    /// <see cref="IFullBleedPage"/> lo usan para colocar su contenido (cambia con el ancho de la ventana).
    /// </summary>
    public Thickness ContentInset { get; private set; } = new(PaneMargin + PaneOpenWidth, TitleBarHeight, 0, 0);

    /// <summary>Cambió <see cref="ContentInset"/>.</summary>
    public event EventHandler? ContentInsetChanged;

    public MainWindow()
    {
        InitializeComponent();
        SystemBackdrop = DesktopAcrylicController.IsSupported() ? new DesktopAcrylicBackdrop()
            : MicaController.IsSupported() ? new MicaBackdrop() : null;

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.Resize(new SizeInt32(1440, 900));
        // Sin empaquetar, la barra de tareas y Alt+Tab toman el icono de la ventana, no el del exe.
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Glasstube.ico"));
        AppTitleBar.LayoutUpdated += (_, _) => UpdatePassthrough();
        UpdateCaptionColors();

        NavList.SelectedItem = HomeItem;
        if (CaptureMode.Enabled) return; // sin la cuenta ni sus canales
        _ = LoadAccount();
        SubscriptionsStore.Shared.Changed += (_, _) => UpdateChannels();
        _ = SubscriptionsStore.Shared.LoadAsync();
    }

    /// <summary>
    /// Sección "Canales" del panel con los canales suscritos (y los grupos, si hay): cuántos videos sin ver tiene cada
    /// uno en la Bandeja, o un punto si YouTube lo marca con contenido nuevo. Y el contador de Suscripciones.
    /// </summary>
    void UpdateChannels()
    {
        var store = SubscriptionsStore.Shared;
        var unseen = store.UnseenCount();
        SubscriptionsBadge.Value = unseen;
        SubscriptionsBadge.Visibility = unseen > 0 && Pane.Width >= PaneOpenWidth ? Visibility.Visible : Visibility.Collapsed;

        var selected = (ChannelList.SelectedItem as ListViewItem)?.Tag as string;
        selectingFromNavigation = true;
        ChannelList.Items.Clear();
        foreach (var group in store.Groups)
        {
            var ids = group.Channels.ToHashSet();
            ChannelList.Items.Add(ChannelItem($"group:{group.Id}", group.Title, null, "\uE8F1",
                store.UnseenCount(v => v.ChannelId != null && ids.Contains(v.ChannelId)), false));
        }
        // Primero los que tienen algo sin ver.
        foreach (var channel in store.Channels.OrderByDescending(c => store.UnseenCount(v => v.ChannelId == c.Id) > 0))
            ChannelList.Items.Add(ChannelItem($"channel:{channel.Id}", channel.Name, channel.Avatar, null,
                store.UnseenCount(v => v.ChannelId == channel.Id), channel.HasNew));
        ChannelList.SelectedItem = ChannelList.Items.OfType<ListViewItem>().FirstOrDefault(i => (string)i.Tag == selected);
        selectingFromNavigation = false;
        ChannelsHeader.Text = store.Groups.Count > 0 ? "Grupos y canales" : "Canales";
        ChannelsSection.Visibility = ChannelList.Items.Count > 0 && Pane.Width >= PaneOpenWidth ? Visibility.Visible : Visibility.Collapsed;
    }

    static ListViewItem ChannelItem(string tag, string name, string? avatar, string? glyph, int unseen, bool hasNew)
    {
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        FrameworkElement icon = glyph != null
            ? new FontIcon { Glyph = glyph, FontSize = 16, Width = 20 }
            : new PersonPicture { Width = 20, Height = 20, DisplayName = name, ProfilePicture = avatar == null ? null : new BitmapImage(new Uri(avatar)) { DecodePixelWidth = 40 } };
        row.Children.Add(icon);
        var label = new TextBlock { Text = name, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(label, 1);
        row.Children.Add(label);
        FrameworkElement? mark = unseen > 0
            ? new TextBlock { Text = unseen.ToString(), FontSize = 12, VerticalAlignment = VerticalAlignment.Center,
                              Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] }
            : hasNew ? new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 6, Height = 6, VerticalAlignment = VerticalAlignment.Center,
                                                              Fill = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"] }
            : null;
        if (mark != null)
        {
            Grid.SetColumn(mark, 2);
            row.Children.Add(mark);
        }
        var item = new ListViewItem { Tag = tag, Content = row, Padding = new Thickness(16, 0, 12, 0), MinHeight = 36 };
        ToolTipService.SetToolTip(item, name);
        return item;
    }

    /// <summary>La Bandeja de Suscripciones, de todos los canales o de uno ("UC…").</summary>
    public void ShowSubscriptions(string? channelId)
    {
        var section = channelId == null ? "subscriptions" : $"channel:{channelId}";
        if (CurrentTag != section) ContentFrame.Navigate(typeof(SubscriptionsPage), section, new EntranceNavigationTransitionInfo());
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
        else if (tag == "subscriptions" || tag.StartsWith("channel:") || tag.StartsWith("group:"))
            ContentFrame.Navigate(typeof(SubscriptionsPage), tag, new EntranceNavigationTransitionInfo());
        else
            ContentFrame.Navigate(typeof(PlaceholderPage), tag, new EntranceNavigationTransitionInfo());
    }

    /// <summary>Sección del panel que corresponde a la página visible (null en el reproductor y la búsqueda).</summary>
    string? CurrentTag => ContentFrame.Content switch
    {
        HomePage => "home",
        SubscriptionsPage subscriptions => subscriptions.Section,
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

    /// <summary>Busca <paramref name="text"/> como si se escribiera en la barra (`--buscar`).</summary>
    public void Search(string text)
    {
        SearchBox.Text = text;
        ContentFrame.Navigate(typeof(SearchPage), text, new EntranceNavigationTransitionInfo());
    }

    /// <summary>
    /// Abre otro video desde el reproductor (sugeridos, reproducción automática). Con <paramref name="replacePlayer"/>,
    /// el reproductor anterior sale del historial: atrás vuelve a donde se abrió el primero.
    /// </summary>
    public void Play(Models.VideoCard video, bool replacePlayer)
    {
        var fromPlayer = ContentFrame.Content is PlayerPage;
        ContentFrame.Navigate(typeof(PlayerPage), video, new SuppressNavigationTransitionInfo());
        if (replacePlayer && fromPlayer && ContentFrame.BackStack.Count > 0)
            ContentFrame.BackStack.RemoveAt(ContentFrame.BackStack.Count - 1);
        BackButton.IsEnabled = ContentFrame.CanGoBack;
    }

    void OnNavigated(object sender, NavigationEventArgs e)
    {
        BackButton.IsEnabled = ContentFrame.CanGoBack;
        chromeHidden = (e.Content as IFullBleedPage)?.HidesChrome == true;
        titleBarStyle = (e.Content as IFullBleedPage)?.InitialTitleBar ?? TitleBarStyle.Normal;
        chromeFaded = false;
        BackButton.Opacity = 1;

        // Al volver de un reproductor, la selección del panel sigue a la página. Navigated llega antes de que la página
        // (guardada en caché) lea su parámetro: la sección sale del parámetro mismo.
        var tag = e.Content is SubscriptionsPage ? e.Parameter as string ?? "subscriptions"
            : e.Content is PlaceholderPage ? e.Parameter as string : CurrentTag;
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
        var inset = new Thickness(docked > 0 ? PaneMargin + docked : 0, TitleBarHeight, 0, 0);
        ContentFrame.Margin = ContentFrame.Content is IFullBleedPage ? new Thickness(0) : inset;
        if (!inset.Equals(ContentInset))
        {
            ContentInset = inset;
            ContentInsetChanged?.Invoke(this, EventArgs.Empty);
        }

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
        // Los canales y el contador solo con el panel abierto.
        ChannelsSection.Visibility = visible && ChannelList.Items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        SubscriptionsBadge.Visibility = visible && SubscriptionsBadge.Value > 0 ? Visibility.Visible : Visibility.Collapsed;
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
        var overImage = chromeHidden || titleBarStyle == TitleBarStyle.OverImage;
        var dark = overImage || Root.ActualTheme == ElementTheme.Dark;
        AppTitleBar.RequestedTheme = overImage ? ElementTheme.Dark : ElementTheme.Default;
        AppTitleBar.Background = titleBarStyle == TitleBarStyle.Solid && !chromeHidden
            ? (Brush)Application.Current.Resources["AcrylicInAppFillColorDefaultBrush"] : null;
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

    /// <summary>La página a pantalla completa cambia la barra de título (el Inicio, al desplazarse bajo ella).</summary>
    public void SetTitleBarStyle(TitleBarStyle style)
    {
        if (style == titleBarStyle) return;
        titleBarStyle = style;
        UpdateCaptionColors();
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
