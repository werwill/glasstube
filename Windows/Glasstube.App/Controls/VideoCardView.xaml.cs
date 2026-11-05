using System.Numerics;
using Glasstube.Models;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

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

    /// <summary>Espera con el ratón encima antes de la vista previa, y tiempo de cada cuadro.</summary>
    static readonly TimeSpan PreviewDelay = TimeSpan.FromMilliseconds(600);
    static readonly TimeSpan PreviewFrame = TimeSpan.FromMilliseconds(550);
    /// <summary>Cuántos cuadros recorre la vista previa (repartidos entre el 5 % y el 95 % del video).</summary>
    const int PreviewFrames = 10;

    /// <summary>Hojas del storyboard ya decodificadas (varias tarjetas del mismo video, la barra del reproductor).</summary>
    static readonly Dictionary<string, BitmapImage> sheets = [];

    DispatcherQueueTimer? previewTimer;
    StoryboardInfo? storyboard;
    int previewStep;
    bool hovering;

    public VideoCardView()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            DeArrowStore.Shared.Updated += OnDeArrowUpdated;
            AppSettings.Changed += OnSettingsChanged;
        };
        Unloaded += (_, _) =>
        {
            DeArrowStore.Shared.Updated -= OnDeArrowUpdated;
            AppSettings.Changed -= OnSettingsChanged;
            StopPreview();
        };
    }

    void Update()
    {
        var video = Video;
        StopPreview();
        storyboard = null;
        DeArrowStore.Shared.Request(video?.IsPlaylist == false ? video.Id : null);
        ShowBranding();
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

    /// <summary>Título y miniatura: los de DeArrow si están activados y los hay; si no, los de YouTube.</summary>
    void ShowBranding()
    {
        var video = Video;
        var store = DeArrowStore.Shared;
        var title = video == null ? "" : store.Title(video.Id, video.Title);
        TitleText.Text = title;
        ToolTipService.SetToolTip(TitleText, video != null && title != video.Title ? $"Título original: {video.Title}" : null);
        ThumbnailImage.Source = store.Thumbnail(video?.Id) is { } community
            ? new BitmapImage(new Uri(community)) { DecodePixelWidth = 480, DecodePixelType = DecodePixelType.Logical }
            : video?.ThumbnailImage;
    }

    void OnDeArrowUpdated(object? sender, IReadOnlySet<string> ids)
    {
        if (Video is { } video && ids.Contains(video.Id)) ShowBranding();
    }

    void OnSettingsChanged(object? sender, EventArgs e)
    {
        DeArrowStore.Shared.Request(Video?.IsPlaylist == false ? Video.Id : null);
        ShowBranding();
        if (!AppSettings.Shared.HoverPreviews) StopPreview();
    }

    void SetHover(bool on)
    {
        hovering = on;
        // Con Z > 0 la ThemeShadow de la miniatura aparece sola.
        Thumbnail.Translation = on ? new Vector3(0, -4, 24) : Vector3.Zero;
        PlayGlyph.Opacity = on ? 1 : 0;
        if (on) SchedulePreview();
        else StopPreview();
    }

    void OnChannelClick(object sender, RoutedEventArgs e)
    {
        if (Video is { ChannelId: { } id } video) App.Window?.OpenChannel(id, video.Channel);
    }

    void OnPointerEntered(object sender, PointerRoutedEventArgs e) => SetHover(true);
    void OnPointerExited(object sender, PointerRoutedEventArgs e) => SetHover(false);

    // MARK: Vista previa

    void SchedulePreview()
    {
        if (!AppSettings.Shared.HoverPreviews || CaptureMode.Enabled || Video is not { IsLive: false, IsPlaylist: false }) return;
        previewTimer ??= CreatePreviewTimer();
        previewStep = -1;
        previewTimer.Interval = PreviewDelay;
        previewTimer.Start();
    }

    DispatcherQueueTimer CreatePreviewTimer()
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.IsRepeating = true;
        timer.Tick += async (t, _) =>
        {
            if (!hovering) { t.Stop(); return; }
            if (previewStep < 0)
            {
                // Primera vuelta: pedir las hojas (una vez por video) y seguir al ritmo de los cuadros.
                t.Stop();
                var video = Video;
                if (video == null) return;
                var info = await StoryboardCache.Get(video.Id);
                if (!hovering || !ReferenceEquals(video, Video) || info == null || info.Count == 0) return;
                storyboard = info;
                previewStep = 0;
                t.Interval = PreviewFrame;
                ShowPreviewFrame();
                t.Start();
                return;
            }
            previewStep = (previewStep + 1) % PreviewFrames;
            ShowPreviewFrame();
        };
        return timer;
    }

    void ShowPreviewFrame()
    {
        if (storyboard is not { } info) return;
        var fraction = 0.05 + 0.9 * previewStep / (PreviewFrames - 1);
        if (info.Frame((int)(fraction * info.Count)) is not { } frame) return;
        if (!sheets.TryGetValue(frame.Sheet, out var sheet))
        {
            sheet = new BitmapImage(new Uri(frame.Sheet));
            sheets[frame.Sheet] = sheet;
        }
        PreviewImage.Source = sheet;
        PreviewImage.Width = info.Columns * info.Width;
        PreviewImage.Height = info.Rows * info.Height;
        PreviewCanvas.Tag = frame.Crop;
        LayoutPreview();
        PreviewCanvas.Visibility = Visibility.Visible;
    }

    /// <summary>Escala la hoja para que el cuadro llene la miniatura (centrado, como UniformToFill) y la mueve a él.</summary>
    void LayoutPreview()
    {
        if (PreviewCanvas.Tag is not Windows.Foundation.Rect crop || crop.Width <= 0) return;
        var width = PreviewCanvas.ActualWidth;
        var height = PreviewCanvas.ActualHeight;
        if (width <= 0 || height <= 0) return;
        var scale = Math.Max(width / crop.Width, height / crop.Height);
        PreviewTransform.ScaleX = PreviewTransform.ScaleY = scale;
        PreviewTransform.TranslateX = -crop.X * scale + (width - crop.Width * scale) / 2;
        PreviewTransform.TranslateY = -crop.Y * scale + (height - crop.Height * scale) / 2;
        PreviewCanvas.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, width, height) };
    }

    void OnPreviewSizeChanged(object sender, SizeChangedEventArgs e) => LayoutPreview();

    void StopPreview()
    {
        previewTimer?.Stop();
        previewStep = -1;
        PreviewCanvas.Visibility = Visibility.Collapsed;
        PreviewImage.Source = null;
    }
}
