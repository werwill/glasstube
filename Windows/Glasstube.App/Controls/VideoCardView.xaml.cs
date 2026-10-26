using System.Numerics;
using Glasstube.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Glasstube.Controls;

/// <summary>Tarjeta de un video en las cuadrículas. Los contenedores se reciclan: todo se rellena al cambiar <see cref="Video"/>.</summary>
public sealed partial class VideoCardView : UserControl
{
    public static readonly DependencyProperty VideoProperty = DependencyProperty.Register(
        nameof(Video), typeof(VideoCard), typeof(VideoCardView),
        new PropertyMetadata(null, (d, _) => ((VideoCardView)d).Update()));

    public VideoCard? Video
    {
        get => (VideoCard?)GetValue(VideoProperty);
        set => SetValue(VideoProperty, value);
    }

    public VideoCardView() => InitializeComponent();

    void Update()
    {
        var video = Video;
        ThumbnailImage.Source = video?.ThumbnailImage;
        TitleText.Text = video?.Title ?? "";
        ChannelText.Text = video?.Channel ?? "";
        ChannelLink.IsHitTestVisible = !string.IsNullOrEmpty(video?.ChannelId);
        ChannelLink.Visibility = string.IsNullOrEmpty(video?.Channel) ? Visibility.Collapsed : Visibility.Visible;
        ToolTipService.SetToolTip(ChannelLink, ChannelLink.IsHitTestVisible ? $"Ver el canal {video?.Channel}" : null);
        MetaText.Text = video?.Meta ?? "";
        DurationText.Text = video?.Duration ?? "";
        var live = video?.IsLive == true;
        DurationBadge.Visibility = video?.HasDuration == true && !live ? Visibility.Visible : Visibility.Collapsed;
        LiveBadge.Visibility = live ? Visibility.Visible : Visibility.Collapsed;
        var progress = video?.Progress ?? 0;
        ProgressTrack.Visibility = progress > 0.01 && !live ? Visibility.Visible : Visibility.Collapsed;
        ProgressDone.Width = new GridLength(progress, GridUnitType.Star);
        ProgressLeft.Width = new GridLength(1 - progress, GridUnitType.Star);
        SetHover(false);
    }

    void SetHover(bool on)
    {
        // Con Z > 0 la ThemeShadow de la miniatura aparece sola.
        Thumbnail.Translation = on ? new Vector3(0, -4, 24) : Vector3.Zero;
        PlayGlyph.Opacity = on ? 1 : 0;
    }

    void OnChannelClick(object sender, RoutedEventArgs e)
    {
        if (Video is { ChannelId: { } id } video) App.Window?.OpenChannel(id, video.Channel);
    }

    void OnPointerEntered(object sender, PointerRoutedEventArgs e) => SetHover(true);
    void OnPointerExited(object sender, PointerRoutedEventArgs e) => SetHover(false);
}
