using Glasstube.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Glasstube.Pages;

/// <summary>
/// Al pasar el ratón por la barra de progreso (y al arrastrarla), una burbuja encima con el cuadro del storyboard de ese
/// momento, el minuto y el capítulo, como en la app de Mac. Sin storyboard (directos), solo el minuto.
/// </summary>
public sealed partial class PlayerPage
{
    StoryboardInfo? scrubStoryboard;
    readonly Dictionary<string, BitmapImage> scrubSheets = [];

    void AddScrubHandlers()
    {
        // El Slider marca como atendidos sus eventos de puntero: se escuchan también esos.
        Progress.AddHandler(PointerMovedEvent, new PointerEventHandler((_, e) => ShowScrub(e)), true);
        Progress.AddHandler(PointerExitedEvent, new PointerEventHandler((_, _) => { if (!dragging) HideScrub(); }), true);
        Progress.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, e) =>
        {
            var point = e.GetCurrentPoint(Progress).Position;
            if (point.X < 0 || point.Y < 0 || point.X > Progress.ActualWidth || point.Y > Progress.ActualHeight) HideScrub();
        }), true);
    }

    async Task LoadStoryboard(string videoId)
    {
        scrubStoryboard = null;
        var info = await StoryboardCache.Get(videoId);
        if (closed || video?.Id != videoId) return;
        scrubStoryboard = info;
    }

    void ShowScrub(PointerRoutedEventArgs e)
    {
        var duration = TrackDuration;
        if (duration <= 0 || stream?.Hls != null || player == null) return;
        var x = e.GetCurrentPoint(Progress).Position.X;
        var width = Progress.ActualWidth - 2 * ThumbInset;
        if (width <= 0) return;
        var seconds = Math.Clamp((x - ThumbInset) / width, 0, 1) * duration;

        ScrubTime.Text = Time(seconds);
        var chapter = chapters.LastOrDefault(c => c.Start <= seconds);
        ScrubChapter.Text = chapter?.Title ?? "";
        ScrubChapter.Visibility = chapter != null ? Visibility.Visible : Visibility.Collapsed;

        var hasFrame = scrubStoryboard?.FrameAt(seconds, duration) is { } frame && ShowScrubFrame(scrubStoryboard, frame);
        ScrubFrameHost.Visibility = hasFrame ? Visibility.Visible : Visibility.Collapsed;
        ScrubBubble.Visibility = Visibility.Visible;
        ScrubBubble.UpdateLayout();

        // Centrada sobre el puntero, sin salirse de la ventana, y justo encima de la cápsula.
        var origin = Progress.TransformToVisual(ScrubLayer).TransformPoint(new Windows.Foundation.Point(0, 0));
        var bubbleWidth = ScrubBubble.ActualWidth;
        var left = Math.Clamp(origin.X + x - bubbleWidth / 2, 8, Math.Max(8, Root.ActualWidth - bubbleWidth - 8));
        var capsuleTop = Capsule.TransformToVisual(ScrubLayer).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
        Microsoft.UI.Xaml.Controls.Canvas.SetLeft(ScrubBubble, left);
        Microsoft.UI.Xaml.Controls.Canvas.SetTop(ScrubBubble, capsuleTop - ScrubBubble.ActualHeight - 10);
    }

    bool ShowScrubFrame(StoryboardInfo info, (string Sheet, Windows.Foundation.Rect Crop) frame)
    {
        if (!scrubSheets.TryGetValue(frame.Sheet, out var sheet))
        {
            sheet = new BitmapImage(new Uri(frame.Sheet));
            scrubSheets[frame.Sheet] = sheet;
        }
        if (!ReferenceEquals(ScrubImage.Source, sheet)) ScrubImage.Source = sheet;
        ScrubImage.Width = info.Columns * info.Width;
        ScrubImage.Height = info.Rows * info.Height;
        // El cuadro llena 192×108 (centrado si no es 16:9).
        var crop = frame.Crop;
        var scale = Math.Max(ScrubFrameHost.Width / crop.Width, ScrubFrameHost.Height / crop.Height);
        ScrubTransform.ScaleX = ScrubTransform.ScaleY = scale;
        ScrubTransform.TranslateX = -crop.X * scale + (ScrubFrameHost.Width - crop.Width * scale) / 2;
        ScrubTransform.TranslateY = -crop.Y * scale + (ScrubFrameHost.Height - crop.Height * scale) / 2;
        return true;
    }

    void HideScrub() => ScrubBubble.Visibility = Visibility.Collapsed;
}
