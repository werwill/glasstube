using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Glasstube.Pages;

/// <summary>
/// Capítulos y SponsorBlock en el reproductor (gt_video_details): la barra de progreso partida en un tramo por capítulo,
/// los segmentos de SponsorBlock sombreados con su color, el capítulo actual junto al canal ("Capítulo 2: …") y la
/// píldora «Saltar patrocinio» mientras se está dentro de un segmento. No salta solo.
/// </summary>
public sealed partial class PlayerPage
{
    /// <summary>Medio pulgar del Slider: el valor 0 y el máximo quedan a esta distancia de los bordes.</summary>
    const double ThumbInset = 9;
    const double TrackHeight = 4;

    static readonly Brush TrackBrush = new SolidColorBrush(Color.FromArgb(0x4D, 0xFF, 0xFF, 0xFF));

    List<ChapterInfo> chapters = [];
    List<SponsorSegmentInfo> segments = [];
    readonly List<(Border Track, Border Played, double Start, double End)> bars = [];
    string channelName = "";
    int chapterIndex = -1;
    SponsorSegmentInfo? currentSegment;
    /// <summary>Segmento que el usuario ya saltó o del que volvió atrás: no se vuelve a ofrecer hasta salir de él.</summary>
    SponsorSegmentInfo? dismissedSegment;

    async Task LoadExtras(string videoId)
    {
        try
        {
            var details = await GlasstubeFFI.Details(videoId);
            if (closed) return;
            chapters = details.Chapters.OrderBy(c => c.Start).ToList();
            segments = details.Segments;
            // Abierto solo con el id (--abrir, enlaces): el título y el canal salen de aquí.
            if (TitleText.Text == videoId && !string.IsNullOrEmpty(details.Title)) TitleText.Text = details.Title;
            if (channelName.Length == 0 && !string.IsNullOrEmpty(details.Author)) ChannelText.Text = channelName = details.Author;
            chapterIndex = -2; // que se vuelva a escribir la línea del canal
            GlasstubeFFI.Log("app", $"{videoId}: {chapters.Count} capítulos, {segments.Count} segmentos de SponsorBlock");
            BuildTrack();
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"{videoId}: sin capítulos ni SponsorBlock: {error.Message}");
        }
    }

    double TrackDuration => state.Duration > 0 ? state.Duration : stream?.DurationSeconds ?? 0;

    /// <summary>Dibuja la pista: tramos de capítulo (o uno solo), lo reproducido encima y los segmentos de SponsorBlock.</summary>
    void BuildTrack()
    {
        TrackLayer.Children.Clear();
        bars.Clear();
        var duration = TrackDuration;
        var width = Progress.ActualWidth - 2 * ThumbInset;
        if (duration <= 0 || width <= 0) return;
        var top = (Progress.ActualHeight - TrackHeight) / 2;
        double X(double seconds) => ThumbInset + Math.Clamp(seconds / duration, 0, 1) * width;

        var starts = chapters.Count > 0 ? chapters.Select(c => c.Start).ToList() : [0];
        for (var i = 0; i < starts.Count; i++)
        {
            var start = starts[i];
            var end = i + 1 < starts.Count ? starts[i + 1] : duration;
            var gap = i + 1 < starts.Count ? 2 : 0; // corte entre capítulos
            var x = X(start);
            var w = Math.Max(1, X(end) - x - gap);
            var track = new Border { Width = w, Height = TrackHeight, CornerRadius = new CornerRadius(2), Background = TrackBrush };
            var played = new Border { Width = 0, Height = TrackHeight, CornerRadius = new CornerRadius(2),
                                      Background = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"] };
            foreach (var element in new[] { track, played })
            {
                Canvas.SetLeft(element, x);
                Canvas.SetTop(element, top);
                TrackLayer.Children.Add(element);
            }
            bars.Add((track, played, start, end));
        }
        foreach (var segment in segments)
        {
            var x = X(segment.Start);
            var shade = new Border
            {
                Width = Math.Max(2, X(segment.End) - x), Height = TrackHeight, CornerRadius = new CornerRadius(1),
                Background = new SolidColorBrush(SegmentColor(segment.Category)),
            };
            ToolTipService.SetToolTip(shade, segment.Title);
            Canvas.SetLeft(shade, x);
            Canvas.SetTop(shade, top);
            TrackLayer.Children.Add(shade);
        }
        UpdateTrack(state.Position);
    }

    /// <summary>Los colores de SponsorBlock (los de GlasstubeCore, SponsorSegment.color).</summary>
    static Color SegmentColor(string category) => category switch
    {
        "sponsor" => Color.FromArgb(0xE6, 0x30, 0xD1, 0x59),
        "selfpromo" => Color.FromArgb(0xE6, 0xFF, 0xD6, 0x0A),
        "interaction" => Color.FromArgb(0xE6, 0xBF, 0x5A, 0xF2),
        "intro" => Color.FromArgb(0xE6, 0x64, 0xD2, 0xFF),
        "outro" => Color.FromArgb(0xE6, 0x0A, 0x84, 0xFF),
        "preview" => Color.FromArgb(0xE6, 0x5A, 0xC8, 0xFA),
        "music_offtopic" => Color.FromArgb(0xE6, 0xFF, 0x9F, 0x0A),
        _ => Color.FromArgb(0xE6, 0x99, 0x99, 0xA6),
    };

    /// <summary>En cada lectura de mpv: lo reproducido, el capítulo actual y la píldora de SponsorBlock.</summary>
    void UpdateExtras(double position)
    {
        if (bars.Count == 0 && TrackDuration > 0 && Progress.ActualWidth > 0) BuildTrack();
        UpdateTrack(position);

        var index = chapters.FindLastIndex(c => c.Start <= position + 0.25);
        if (index != chapterIndex)
        {
            chapterIndex = index;
            ChannelText.Text = index < 0 ? channelName
                : string.Join(" · ", new[] { channelName, $"Capítulo {index + 1}: {chapters[index].Title}" }.Where(s => s.Length > 0));
        }

        var segment = segments.FirstOrDefault(s => position >= s.Start && position < s.End - 0.5);
        if (dismissedSegment != null && !ReferenceEquals(segment, dismissedSegment)) dismissedSegment = null;
        if (ReferenceEquals(segment, dismissedSegment)) segment = null;
        if (!ReferenceEquals(segment, currentSegment))
        {
            currentSegment = segment;
            if (segment != null) SkipText.Text = segment.Title;
        }
        SkipButton.Visibility = currentSegment != null && !IsMini ? Visibility.Visible : Visibility.Collapsed;
    }

    void UpdateTrack(double position)
    {
        foreach (var (track, played, start, end) in bars)
            played.Width = end > start ? Math.Clamp((position - start) / (end - start), 0, 1) * track.Width : 0;
    }

    void Skip()
    {
        if (currentSegment is not { } segment || player == null) return;
        GlasstubeFFI.Log("app", $"saltar {segment.Category} {segment.Start:0}–{segment.End:0} s");
        dismissedSegment = segment;
        currentSegment = null;
        SkipButton.Visibility = Visibility.Collapsed;
        player.Seek(Math.Min(segment.End, Math.Max(0, TrackDuration - 1)));
        ShowControls();
    }

    void OnSkip(object sender, RoutedEventArgs e) => Skip();

    void OnSkipKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        Skip();
    }

    void OnProgressSizeChanged(object sender, SizeChangedEventArgs e) => BuildTrack();

    /// <summary>La píldora va justo encima de la cápsula, que cambia de alto con el ancho de la ventana.</summary>
    void OnCapsuleSizeChanged(object sender, SizeChangedEventArgs e) =>
        SkipButton.Margin = new Thickness(0, 0, 24 + 8, Capsule.Margin.Bottom + e.NewSize.Height + 12);
}
