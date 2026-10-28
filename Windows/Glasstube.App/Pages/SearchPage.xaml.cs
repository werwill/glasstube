using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>
/// Resultados de búsqueda (solo videos) en la cuadrícula adaptable, con los filtros de YouTube. El parámetro de
/// navegación es el texto o un <see cref="SearchRequest"/>.
/// </summary>
public sealed partial class SearchPage : Page
{
    string query = "";
    SearchFilterInfo filter = new();
    /// <summary>Sube con cada búsqueda: los resultados de una anterior que lleguen tarde se descartan.</summary>
    int generation;

    public SearchPage() => InitializeComponent();

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        // Al volver a la página guardada se queda con sus filtros y resultados.
        if (e.NavigationMode == NavigationMode.Back && Results.ItemsSource != null) return;
        (query, filter) = e.Parameter switch
        {
            SearchRequest request => (request.Query, request.Filter.Copy()),
            string text => (text, new SearchFilterInfo()),
            _ => ("", new SearchFilterInfo()),
        };
        TitleText.Text = $"Resultados de «{query}»";
        BuildFilterMenu();
        await Run();
    }

    async Task Run()
    {
        var started = ++generation;
        Notice.IsOpen = false;
        Results.ItemsSource = null;
        ShowChannels([]);
        LoadingPanel.Visibility = Visibility.Visible;
        try
        {
            await App.Ready;
            var page = await GlasstubeFFI.Search(query, filter);
            if (started != generation) return;
            ShowChannels(page.Channels ?? []);
            Results.ItemsSource = new FeedCollection(page.Items, page.HasMore, GlasstubeFFI.SearchMore);
            if (page.Items.Count == 0)
                ShowNotice(InfoBarSeverity.Informational, page.Notice
                    ?? (filter.IsEmpty ? "Sin videos para esta búsqueda." : "Sin videos con estos filtros."));
        }
        catch (Exception error)
        {
            if (started == generation) ShowNotice(InfoBarSeverity.Error, $"No se pudo buscar: {error.Message}");
        }
        finally
        {
            if (started == generation) LoadingPanel.Visibility = Visibility.Collapsed;
        }
    }

    // MARK: Filtros

    static readonly (string Title, int Value)[] Priorities = [("Relevancia", 0), ("Popularidad", 3)];
    static readonly (string Title, int? Value)[] Dates =
        [("Cualquier fecha", null), ("Hoy", 2), ("Esta semana", 3), ("Este mes", 4), ("Este año", 5)];
    static readonly (string Title, int? Value)[] Types = [("Todo", null), ("Videos", 1), ("Películas", 4)];
    static readonly (string Title, int? Value)[] Durations =
        [("Cualquier duración", null), ("Menos de 3 minutos", 4), ("De 3 a 20 minutos", 5), ("Más de 20 minutos", 2)];
    static readonly (string Title, int Value)[] Features =
        [("HD", 4), ("4K", 14), ("HDR", 25), ("Subtítulos", 5), ("Creative Commons", 6), ("En vivo", 8)];

    /// <summary>El menú con lo elegido marcado, y el botón con cuántos filtros hay.</summary>
    void BuildFilterMenu()
    {
        FilterMenu.Items.Clear();
        void Section(string title)
        {
            if (FilterMenu.Items.Count > 0) FilterMenu.Items.Add(new MenuFlyoutSeparator());
            FilterMenu.Items.Add(new MenuFlyoutItem { Text = title, IsEnabled = false });
        }
        void Choices<T>(string group, (string Title, T Value)[] options, T current, Action<T> apply)
        {
            foreach (var (title, value) in options)
            {
                var item = new RadioMenuFlyoutItem { Text = title, GroupName = group, IsChecked = Equals(value, current) };
                item.Click += (_, _) => { apply(value); Changed(); };
                FilterMenu.Items.Add(item);
            }
        }

        Section("Prioridad");
        Choices("prioridad", Priorities, filter.Priority, v => filter.Priority = v);
        Section("Fecha de subida");
        Choices("fecha", Dates, filter.UploadDate, v => filter.UploadDate = v);
        Section("Tipo");
        Choices("tipo", Types, filter.Type, v => filter.Type = v);
        Section("Duración");
        Choices("duracion", Durations, filter.Duration, v => filter.Duration = v);
        Section("Características");
        foreach (var (title, value) in Features)
        {
            var item = new ToggleMenuFlyoutItem { Text = title, IsChecked = filter.Features.Contains(value) };
            item.Click += (_, _) =>
            {
                if (!filter.Features.Remove(value)) filter.Features.Add(value);
                Changed();
            };
            FilterMenu.Items.Add(item);
        }
        if (!filter.IsEmpty)
        {
            FilterMenu.Items.Add(new MenuFlyoutSeparator());
            var clear = new MenuFlyoutItem { Text = "Quitar filtros", Icon = new FontIcon { Glyph = "" } };
            clear.Click += (_, _) => { filter = new SearchFilterInfo(); Changed(); };
            FilterMenu.Items.Add(clear);
        }
        FilterText.Text = filter.ActiveCount > 0 ? $"Filtros ({filter.ActiveCount})" : "Filtros";
    }

    async void Changed()
    {
        BuildFilterMenu();
        await Run();
    }

    // MARK: Canales y avisos

    void ShowChannels(List<ChannelCard> channels)
    {
        ChannelsRow.Children.Clear();
        foreach (var channel in channels.Take(12))
        {
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = channel.Title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
                                              TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 220 });
            var meta = string.Join(" · ", new[] { channel.Handle, channel.Subscribers }.Where(s => !string.IsNullOrWhiteSpace(s)));
            if (meta.Length > 0)
                text.Children.Add(new TextBlock { Text = meta, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                                                  Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                                                  TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 220 });
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            content.Children.Add(new PersonPicture
            {
                Width = 44, Height = 44, DisplayName = channel.Title,
                ProfilePicture = channel.Avatar == null ? null : new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(channel.Avatar)) { DecodePixelWidth = 88 },
            });
            content.Children.Add(text);
            var button = new Button { Content = content, Padding = new Thickness(10, 8, 16, 8), CornerRadius = new CornerRadius(30) };
            ToolTipService.SetToolTip(button, $"Ver el canal {channel.Title}");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, channel.Title);
            var id = channel.Id;
            var name = channel.Title;
            button.Click += (_, _) => App.Window?.OpenChannel(id, name);
            ChannelsRow.Children.Add(button);
        }
        ChannelsScroller.Visibility = ChannelsRow.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
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
}
