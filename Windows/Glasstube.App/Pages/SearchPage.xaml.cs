using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>Resultados de búsqueda (solo videos) en la cuadrícula adaptable. El parámetro de navegación es el texto.</summary>
public sealed partial class SearchPage : Page
{
    public SearchPage() => InitializeComponent();

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        var query = e.Parameter as string ?? "";
        TitleText.Text = $"Resultados de «{query}»";
        if (e.NavigationMode == NavigationMode.Back && Results.ItemsSource != null) return;
        LoadingPanel.Visibility = Visibility.Visible;
        try
        {
            await App.Ready;
            var page = await GlasstubeFFI.Search(query);
            ShowChannels(page.Channels ?? []);
            Results.ItemsSource = new FeedCollection(page.Items, page.HasMore, GlasstubeFFI.SearchMore);
            if (page.Items.Count == 0) ShowNotice(InfoBarSeverity.Informational, page.Notice ?? "Sin videos para esta búsqueda.");
        }
        catch (Exception error)
        {
            ShowNotice(InfoBarSeverity.Error, $"No se pudo buscar: {error.Message}");
        }
        finally
        {
            LoadingPanel.Visibility = Visibility.Collapsed;
        }
    }

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
