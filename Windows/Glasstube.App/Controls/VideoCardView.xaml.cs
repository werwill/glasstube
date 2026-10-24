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
        MetaText.Text = video?.Meta ?? "";
        DurationText.Text = video?.Duration ?? "";
        DurationBadge.Visibility = video?.HasDuration == true ? Visibility.Visible : Visibility.Collapsed;
        SetHover(false);
    }

    void SetHover(bool on)
    {
        // Con Z > 0 la ThemeShadow de la miniatura aparece sola.
        Thumbnail.Translation = on ? new Vector3(0, -4, 24) : Vector3.Zero;
        PlayGlyph.Opacity = on ? 1 : 0;
    }

    void OnPointerEntered(object sender, PointerRoutedEventArgs e) => SetHover(true);
    void OnPointerExited(object sender, PointerRoutedEventArgs e) => SetHover(false);
}
