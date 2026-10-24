using System.ComponentModel;
using System.Globalization;
using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>Una fila de la Bandeja: el video y si ya se vio (cambia sin rehacer la lista).</summary>
public sealed class InboxRow(VideoCard card, bool seen) : INotifyPropertyChanged
{
    static readonly Brush LiveBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(0xE5, 0xCC, 0, 0));
    static readonly Brush DurationBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(0xCC, 0, 0, 0));

    public VideoCard Card { get; } = card;

    bool seen = seen;
    public bool Seen
    {
        get => seen;
        set
        {
            if (seen == value) return;
            seen = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
        }
    }

    public Visibility UnseenVisibility => seen ? Visibility.Collapsed : Visibility.Visible;
    public Windows.UI.Text.FontWeight TitleWeight => seen ? FontWeights.Normal : FontWeights.SemiBold;
    public double TitleOpacity => seen ? 0.72 : 1;
    public string Meta => string.Join(" · ", new[] { Card.Channel, Card.Published }.Where(s => !string.IsNullOrEmpty(s)));
    public string Badge => Card.IsLive ? "EN VIVO" : Card.Duration ?? "";
    public Brush BadgeBrush => Card.IsLive ? LiveBrush : DurationBrush;
    public Visibility BadgeVisibility => Badge.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

    public event PropertyChangedEventHandler? PropertyChanged;
}

/// <summary>Grupo por día ("HOY", "AYER", "MIÉRCOLES 22 DE OCTUBRE").</summary>
public sealed class InboxGroup(string title, IEnumerable<InboxRow> rows) : List<InboxRow>(rows)
{
    public string Title { get; } = title;
}

/// <summary>
/// Suscripciones como Bandeja: lo nuevo de los canales agrupado por día, con pestañas Sin ver / Más tarde / Archivados,
/// vista previa y atajos de teclado (J/K, Intro, W, E, Mayús+U). Al volver del reproductor, el video queda visto y se
/// elige el siguiente. El parámetro de navegación filtra por canal ("channel:UC…") o por grupo ("group:id").
/// </summary>
public sealed partial class SubscriptionsPage : Page
{
    readonly SubscriptionsStore store = SubscriptionsStore.Shared;
    List<InboxRow> rows = [];
    Func<VideoCard, bool>? filter;
    InboxRow? playing;
    string? detailsFor;

    public SubscriptionsPage()
    {
        InitializeComponent();
        // La fila con el foco se queda con Intro antes que el atajo de la página.
        List.AddHandler(KeyDownEvent, new KeyEventHandler((_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter) return;
            e.Handled = true;
            Play();
        }), true);
    }

    /// <summary>"subscriptions", "channel:UC…" o "group:id": la sección del panel que corresponde.</summary>
    public string Section { get; private set; } = "subscriptions";

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        var section = e.Parameter as string ?? "subscriptions";
        var returning = e.NavigationMode == NavigationMode.Back && playing != null;
        if (section != Section || e.NavigationMode != NavigationMode.Back) SetFilter(section);

        Loading.Visibility = store.IsLoaded ? Visibility.Collapsed : Visibility.Visible;
        await store.LoadAsync();
        Loading.Visibility = Visibility.Collapsed;

        if (returning && playing is { } watched)
        {
            // Volviendo del reproductor: visto, y a la siguiente.
            playing = null;
            var index = rows.IndexOf(watched);
            watched.Seen = true;
            await store.SetSeen(watched.Card, true);
            Rebuild();
            Select(index + 1);
            return;
        }
        Rebuild(List.SelectedItem is InboxRow current ? current.Card.Id : null);
    }

    void SetFilter(string section)
    {
        Section = section;
        filter = null;
        string? name = null;
        if (section.StartsWith("channel:"))
        {
            var id = section["channel:".Length..];
            filter = v => v.ChannelId == id;
            name = store.Channels.FirstOrDefault(c => c.Id == id)?.Name ?? id;
        }
        else if (section.StartsWith("group:") && store.Groups.FirstOrDefault(g => g.Id == section["group:".Length..]) is { } group)
        {
            var ids = group.Channels.ToHashSet();
            filter = v => v.ChannelId != null && ids.Contains(v.ChannelId);
            name = group.Title;
        }
        HeaderText.Text = name ?? "Suscripciones";
        FilterText.Text = name == null ? "Todos los canales" : "✕  Todos los canales";
        FilterButton.IsEnabled = name != null;
    }

    // MARK: Lista

    /// <summary>Rehace la lista de la pestaña elegida, manteniendo la selección si sigue ahí.</summary>
    void Rebuild(string? keep = null)
    {
        IEnumerable<VideoCard> source = Tabs.SelectedItem == LaterTab ? store.WatchLater.Where(v => filter?.Invoke(v) ?? true)
            : Tabs.SelectedItem == ArchivedTab ? store.Items.Where(v => store.IsArchived(v) && (filter?.Invoke(v) ?? true))
            : store.Inbox(filter);
        rows = source.Select(v => new InboxRow(v, store.IsSeen(v))).ToList();
        Groups.Source = Tabs.SelectedItem == LaterTab
            ? (rows.Count > 0 ? new List<InboxGroup> { new("VER MÁS TARDE", rows) } : [])
            : rows.GroupBy(r => DayTitle(r.Card)).Select(g => new InboxGroup(g.Key, g)).ToList();

        var unseen = store.UnseenCount(filter);
        InboxTab.Text = unseen > 0 ? $"Sin ver  {unseen}" : "Sin ver";
        var later = store.WatchLater.Count(v => filter?.Invoke(v) ?? true);
        LaterTab.Text = later > 0 ? $"Más tarde  {later}" : "Más tarde";
        MoreButton.Visibility = Tabs.SelectedItem == InboxTab && store.HasMore ? Visibility.Visible : Visibility.Collapsed;

        EmptyPanel.Visibility = rows.Count == 0 && store.IsLoaded || store.Error != null ? Visibility.Visible : Visibility.Collapsed;
        EmptyText.Text = store.Error != null ? $"No se pudieron cargar las suscripciones.\n{store.Error}"
            : Tabs.SelectedItem == LaterTab ? "Nada en Ver más tarde."
            : Tabs.SelectedItem == ArchivedTab ? "Nada archivado." : "Estás al día.";

        var keepIndex = keep == null ? -1 : rows.FindIndex(r => r.Card.Id == keep);
        Select(keepIndex >= 0 ? keepIndex : 0);
    }

    static string DayTitle(VideoCard video)
    {
        if (video.PublishedAt is not { } seconds) return "ANTES";
        var day = DateTimeOffset.FromUnixTimeSeconds((long)seconds).LocalDateTime.Date;
        var today = DateTime.Today;
        if (day == today) return "HOY";
        if (day == today.AddDays(-1)) return "AYER";
        var culture = CultureInfo.GetCultureInfo("es-MX");
        var text = day.Year == today.Year ? day.ToString("dddd d 'de' MMMM", culture) : day.ToString("d 'de' MMMM 'de' yyyy", culture);
        return text.ToUpper(culture);
    }

    void Select(int index)
    {
        if (rows.Count == 0)
        {
            List.SelectedItem = null;
            ShowPreview(null);
            return;
        }
        var row = rows[Math.Clamp(index, 0, rows.Count - 1)];
        List.SelectedItem = row;
        List.ScrollIntoView(row);
    }

    InboxRow? Selected => List.SelectedItem as InboxRow;

    void OnSelectionChanged(object sender, SelectionChangedEventArgs e) => ShowPreview(Selected);

    void OnTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args) => Rebuild();

    void OnClearFilter(object sender, RoutedEventArgs e) => App.Window?.ShowSubscriptions(null);

    async void OnLoadMore(object sender, RoutedEventArgs e)
    {
        MoreButton.IsEnabled = false;
        var keep = Selected?.Card.Id;
        await store.LoadMoreAsync();
        MoreButton.IsEnabled = true;
        Rebuild(keep);
    }

    // MARK: Vista previa

    void ShowPreview(InboxRow? row)
    {
        Preview.Visibility = row == null ? Visibility.Collapsed : Visibility.Visible;
        PreviewEmpty.Visibility = row == null ? Visibility.Visible : Visibility.Collapsed;
        if (row == null) return;
        var video = row.Card;
        var image = video.ThumbnailLarge ?? video.Thumbnail;
        var bitmap = image == null ? null : new BitmapImage(new Uri(image));
        if (bitmap != null && video.Thumbnail != null && image != video.Thumbnail)
            bitmap.ImageFailed += (_, _) => PreviewImage.Source = new BitmapImage(new Uri(video.Thumbnail));
        PreviewImage.Source = bitmap;
        PreviewBadgeText.Text = row.Badge;
        PreviewBadge.Background = row.BadgeBrush;
        PreviewBadge.Visibility = row.BadgeVisibility;
        PreviewTitle.Text = video.Title;
        PreviewMeta.Text = string.Join(" · ", new[] { video.Channel, video.Views, video.Published }.Where(s => !string.IsNullOrEmpty(s)));
        PreviewAvatar.DisplayName = video.Channel ?? "";
        PreviewAvatar.ProfilePicture = video.Avatar == null ? null : new BitmapImage(new Uri(video.Avatar));
        UpdateCommands(row);
        PreviewDescription.Text = "";
        PreviewDescription.Visibility = Visibility.Collapsed;
        ChaptersPanel.Visibility = Visibility.Collapsed;
        _ = LoadDetails(video);
    }

    void UpdateCommands(InboxRow row)
    {
        var later = store.IsInWatchLater(row.Card);
        LaterIcon.Glyph = later ? "" : "";
        LaterText.Text = later ? "En Más tarde" : "Más tarde";
        SeenText.Text = row.Seen ? "No visto" : "Visto";
        ArchiveText.Text = store.IsArchived(row.Card) ? "Desarchivar" : "Archivar";
    }

    /// <summary>Descripción y capítulos (después de una pausa corta, para no pedir cada fila al moverse con J/K).</summary>
    async Task LoadDetails(VideoCard video)
    {
        detailsFor = video.Id;
        await Task.Delay(250);
        if (detailsFor != video.Id) return;
        try
        {
            var details = await GlasstubeFFI.Details(video.Id);
            if (detailsFor != video.Id) return;
            if (!string.IsNullOrWhiteSpace(details.Description))
            {
                PreviewDescription.Text = details.Description.Trim();
                PreviewDescription.Visibility = Visibility.Visible;
            }
            if (video.Avatar == null && details.Avatar != null) PreviewAvatar.ProfilePicture = new BitmapImage(new Uri(details.Avatar));
            ChaptersList.ItemsSource = details.Chapters.Select(c => $"{PlayerPage.Time(c.Start)}   {c.Title}").ToList();
            ChaptersPanel.Visibility = details.Chapters.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"vista previa {video.Id}: {error.Message}");
        }
    }

    // MARK: Acciones

    void Play()
    {
        if (Selected is not { } row) return;
        playing = row;
        App.Window?.Play(row.Card);
    }

    async void ToggleWatchLater()
    {
        if (Selected is not { } row) return;
        await store.ToggleWatchLater(row.Card);
        if (Tabs.SelectedItem == LaterTab) RemoveAndSelectNext(row);
        else
        {
            UpdateCommands(row);
            Rebuild(row.Card.Id);
        }
    }

    async void ToggleArchive()
    {
        if (Selected is not { } row) return;
        await store.SetArchived(row.Card, !store.IsArchived(row.Card));
        RemoveAndSelectNext(row);
    }

    async void ToggleSeen()
    {
        if (Selected is not { } row) return;
        row.Seen = !row.Seen;
        UpdateCommands(row);
        await store.SetSeen(row.Card, row.Seen);
        var unseen = store.UnseenCount(filter);
        InboxTab.Text = unseen > 0 ? $"Sin ver  {unseen}" : "Sin ver";
    }

    void RemoveAndSelectNext(InboxRow row)
    {
        var index = rows.IndexOf(row);
        Rebuild();
        Select(index);
    }

    void Move(int delta)
    {
        if (rows.Count == 0) return;
        Select((Selected == null ? -1 : rows.IndexOf(Selected)) + delta);
        List.Focus(FocusState.Keyboard);
    }

    void OnPlay(object sender, RoutedEventArgs e) => Play();
    void OnWatchLater(object sender, RoutedEventArgs e) => ToggleWatchLater();
    void OnToggleSeen(object sender, RoutedEventArgs e) => ToggleSeen();
    void OnArchive(object sender, RoutedEventArgs e) => ToggleArchive();
    void OnPreviewThumbnailTapped(object sender, TappedRoutedEventArgs e) => Play();
    void OnListDoubleTapped(object sender, DoubleTappedRoutedEventArgs e) => Play();

    void OnNextKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; Move(1); }
    void OnPreviousKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; Move(-1); }
    void OnPlayKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; Play(); }
    void OnWatchLaterKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; ToggleWatchLater(); }
    void OnArchiveKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; ToggleArchive(); }
    void OnToggleSeenKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; ToggleSeen(); }
}
