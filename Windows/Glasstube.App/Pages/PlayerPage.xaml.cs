using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>
/// Reproductor: resuelve las URLs con GlasstubeFFI y las abre en mpv, que pinta en el SwapChainPanel (MPVBridge). Un
/// temporizador lee el estado de mpv y mueve los controles.
/// </summary>
public sealed partial class PlayerPage : Page
{
    static double lastVolume = 100;

    VideoCard? video;
    MpvPlayer? player;
    DispatcherQueueTimer? poll;
    DispatcherQueueTimer? hideTimer;
    MpvState state;
    bool updatingProgress;
    bool dragging;
    bool closed;
    double volumeBeforeMute = 100;

    public PlayerPage()
    {
        InitializeComponent();
        // El arrastre de la barra de progreso: mientras se arrastra no la mueve mpv, y al soltar se busca.
        Progress.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => dragging = true), true);
        Progress.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => EndDrag()), true);
        Progress.AddHandler(PointerCaptureLostEvent, new PointerEventHandler((_, _) => EndDrag()), true);
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        video = e.Parameter as VideoCard;
        if (video == null) return;
        TitleText.Text = video.Title;
        ChannelText.Text = video.Channel ?? "";
        Volume.Value = lastVolume;

        hideTimer = DispatcherQueue.CreateTimer();
        hideTimer.Interval = TimeSpan.FromSeconds(3);
        hideTimer.IsRepeating = false;
        hideTimer.Tick += (_, _) => { if (!state.Paused.AsBool() && player != null && !dragging) Controls.Opacity = 0; };

        try
        {
            await App.Ready;
            var stream = await GlasstubeFFI.ResolveStream(video.Id);
            if (closed) return;
            Start(stream);
        }
        catch (Exception error)
        {
            ShowError(error.Message);
        }
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        closed = true;
        poll?.Stop();
        hideTimer?.Stop();
        player?.Dispose();
        player = null;
        App.Window?.SetFullScreen(false);
    }

    void Start(StreamInfo stream)
    {
        if (!string.IsNullOrEmpty(stream.Title)) TitleText.Text = stream.Title;
        if (!string.IsNullOrEmpty(stream.Author)) ChannelText.Text = stream.Author;
        var (width, height, scale) = PanelPixels();
        player = MpvPlayer.Create(Panel, width, height, scale);
        if (player == null)
        {
            ShowError("No se pudo iniciar mpv.");
            return;
        }
        player.SetVolume(Volume.Value);
        var url = stream.Hls ?? stream.Video?.Url;
        if (url == null)
        {
            ShowError("YouTube no dio URLs para este video.");
            return;
        }
        var result = player.Load(url, stream.Hls == null ? stream.Audio?.Url : null, stream.UserAgent, stream.Headers);
        if (result < 0)
        {
            ShowError(player.LastError);
            return;
        }
        Console.Error.WriteLine($"[app] {stream.VideoId}: cliente {stream.Client}, video {stream.Video?.Label} {stream.Video?.Codec}, audio {stream.Audio?.Label}");
        SpinnerText.Text = "Cargando…";
        poll = DispatcherQueue.CreateTimer();
        poll.Interval = TimeSpan.FromMilliseconds(33);
        poll.Tick += (_, _) => Tick();
        poll.Start();
        hideTimer?.Start();
    }

    void Tick()
    {
        if (player == null) return;
        state = player.Poll();
        if (state.Error.AsBool())
        {
            poll?.Stop();
            ShowError(player.LastError);
            return;
        }
        var waiting = !state.HasVideo.AsBool() || state.Buffering.AsBool();
        Spinner.Visibility = waiting && !state.Paused.AsBool() ? Visibility.Visible : Visibility.Collapsed;

        PlayIcon.Glyph = state.Paused.AsBool() || state.Ended.AsBool() ? "" : "";
        if (state.Paused.AsBool()) Controls.Opacity = 1;
        TimeText.Text = $"{Time(state.Position)} / {Time(state.Duration)}";
        if (!dragging && state.Duration > 0)
        {
            updatingProgress = true;
            Progress.Maximum = state.Duration;
            Progress.Value = Math.Min(state.Position, state.Duration);
            updatingProgress = false;
        }
    }

    static string Time(double seconds)
    {
        if (double.IsNaN(seconds) || seconds < 0) seconds = 0;
        var t = TimeSpan.FromSeconds(Math.Floor(seconds));
        return t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");
    }

    void ShowError(string message)
    {
        Spinner.Visibility = Visibility.Collapsed;
        ErrorBar.Message = string.IsNullOrWhiteSpace(message) ? "Error desconocido." : message;
        ErrorBar.IsOpen = true;
        Controls.Opacity = 1;
    }

    // MARK: Tamaño del panel (píxeles físicos para d3d11-composition-size)

    (int, int, float) PanelPixels()
    {
        var scale = Panel.CompositionScaleX > 0 ? Panel.CompositionScaleX : 1f;
        return ((int)Math.Round(Panel.ActualWidth * scale), (int)Math.Round(Panel.ActualHeight * scale), scale);
    }

    void Resize()
    {
        var (width, height, scale) = PanelPixels();
        player?.Resize(width, height, scale);
    }

    void OnPanelSizeChanged(object sender, SizeChangedEventArgs e) => Resize();
    void OnPanelScaleChanged(SwapChainPanel sender, object args) => Resize();

    // MARK: Controles

    void TogglePause()
    {
        if (player == null) return;
        if (state.Ended.AsBool())
        {
            player.Seek(0);
            player.SetPause(false);
        }
        else
        {
            player.SetPause(!state.Paused.AsBool());
        }
        ShowControls();
    }

    void SeekBy(double seconds)
    {
        if (player == null) return;
        player.Seek(Math.Clamp(state.Position + seconds, 0, Math.Max(0, state.Duration - 1)));
        ShowControls();
    }

    void ToggleFullScreen()
    {
        if (App.Window is not { } window) return;
        window.SetFullScreen(!window.IsFullScreen);
        FullScreenIcon.Glyph = window.IsFullScreen ? "" : "";
    }

    void ToggleMute()
    {
        if (Volume.Value > 0)
        {
            volumeBeforeMute = Volume.Value;
            Volume.Value = 0;
        }
        else
        {
            Volume.Value = volumeBeforeMute > 0 ? volumeBeforeMute : 100;
        }
    }

    void ShowControls()
    {
        Controls.Opacity = 1;
        hideTimer?.Stop();
        hideTimer?.Start();
    }

    void EndDrag()
    {
        if (!dragging) return;
        dragging = false;
        player?.Seek(Progress.Value);
        ShowControls();
    }

    void OnProgressChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        // Clic o teclado sobre la barra (sin arrastre): buscar ya. Con arrastre, al soltar.
        if (updatingProgress || dragging || player == null) return;
        if (Math.Abs(e.NewValue - state.Position) > 0.5) player.Seek(e.NewValue);
    }

    void OnVolumeChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        lastVolume = e.NewValue;
        player?.SetVolume(e.NewValue);
        if (VolumeIcon != null)
            VolumeIcon.Glyph = e.NewValue == 0 ? "" : e.NewValue < 34 ? "" : e.NewValue < 67 ? "" : "";
    }

    void OnPlayPause(object sender, RoutedEventArgs e) => TogglePause();
    void OnMute(object sender, RoutedEventArgs e) => ToggleMute();
    void OnFullScreen(object sender, RoutedEventArgs e) => ToggleFullScreen();
    void OnBack(object sender, RoutedEventArgs e) => App.Window?.GoBack();
    void OnPointerActivity(object sender, PointerRoutedEventArgs e) => ShowControls();
    void OnDoubleTapped(object sender, DoubleTappedRoutedEventArgs e) => ToggleFullScreen();

    void OnTogglePauseKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; TogglePause(); }
    void OnFullScreenKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; ToggleFullScreen(); }
    void OnSeekBackKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; SeekBy(-5); }
    void OnSeekForwardKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; SeekBy(5); }
    void OnMuteKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; ToggleMute(); }

    void OnEscapeKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        if (App.Window?.IsFullScreen == true) ToggleFullScreen();
        else App.Window?.GoBack();
    }
}

static class IntFlag
{
    public static bool AsBool(this int value) => value != 0;
}
