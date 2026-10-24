using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>
/// Reproductor: resuelve las URLs con GlasstubeFFI y las abre en mpv, que pinta en el SwapChainPanel (MPVBridge). Un
/// temporizador lee el estado de mpv y mueve los controles. Ocupa toda la ventana; la barra de título se queda solo con
/// el botón de atrás.
/// </summary>
public sealed partial class PlayerPage : Page, IFullBleedPage
{
    static double lastVolume = 100;
    static readonly bool measuring = Environment.GetCommandLineArgs().Contains("--medir");

    VideoCard? video;
    StreamInfo? stream;
    MpvPlayer? player;
    DispatcherQueueTimer? poll;
    DispatcherQueueTimer? hideTimer;
    MpvState state;
    bool updatingProgress;
    bool dragging;
    bool closed;
    bool controlsVisible = true;
    bool overCapsule;
    int ticks;
    double volumeBeforeMute = 100;

    public bool HidesChrome => true;

    public PlayerPage()
    {
        InitializeComponent();
        // El arrastre de la barra de progreso: mientras se arrastra no la mueve mpv, y al soltar se busca.
        Progress.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => dragging = true), true);
        Progress.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => EndDrag()), true);
        Progress.AddHandler(PointerCaptureLostEvent, new PointerEventHandler((_, _) => EndDrag()), true);
        AddSpeedKeys();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        video = e.Parameter as VideoCard;
        if (video == null) return;
        TitleText.Text = video.Title;
        ChannelText.Text = channelName = video.Channel ?? "";
        Volume.Value = lastVolume;
        SpeedText.Text = speed.ToString("0.##", System.Globalization.CultureInfo.CurrentCulture) + "×";
        PanelTitle.Text = video.Title;
        SetPanelOpen(panelOpen);

        hideTimer = DispatcherQueue.CreateTimer();
        hideTimer.Interval = TimeSpan.FromSeconds(3);
        hideTimer.IsRepeating = false;
        hideTimer.Tick += (_, _) =>
        {
            if (!state.Paused.AsBool() && player != null && !dragging && !overCapsule && !overPanel && openMenus == 0
                && UpNextCard.Visibility == Visibility.Collapsed) SetControlsVisible(false);
        };
        if (App.Window is { } window)
        {
            window.MiniChanged += OnMiniChanged;
            // Llegando desde otro reproductor (sugerido, reproducción automática) se sigue en pantalla completa o en mini.
            FullScreenIcon.Glyph = window.IsFullScreen ? "\uE73F" : "\uE740";
            if (window.IsMini) OnMiniChanged(window, true);
        }

        GlasstubeFFI.Log("app", $"abrir {video.Id} «{video.Title}»");
        try
        {
            await App.Ready;
            _ = LoadExtras(video.Id);
            _ = LoadCaptions(video.Id);
            _ = LoadWatchNext(video.Id);
            // La rotación de clientes (y el PoToken, si hace falta) suele tardar 2–5 s; más de esto es que algo se colgó.
            var saved = GlasstubeFFI.SavedPositionOf(video.Id);
            var resolved = await GlasstubeFFI.ResolveStream(video.Id, Settings.Quality, null).WaitAsync(ResolveTimeout);
            if (closed) return;
            Start(resolved, ResumePosition(await saved));
        }
        catch (TimeoutException)
        {
            GlasstubeFFI.Log("app", $"{video.Id}: la resolución pasó de {ResolveTimeout.TotalSeconds} s");
            if (!closed) ShowError($"YouTube no respondió en {ResolveTimeout.TotalSeconds:0} s. Prueba otra vez.");
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"{video.Id}: no se pudo resolver: {error.Message}");
            if (!closed) ShowError(error.Message);
        }
    }

    static readonly TimeSpan ResolveTimeout = TimeSpan.FromSeconds(45);
    /// <summary>Si mpv no muestra el primer cuadro en este tiempo, se da por fallido.</summary>
    static readonly TimeSpan StartTimeout = TimeSpan.FromSeconds(30);
    DateTime loadedAt;

    /// <summary>Donde se quedó, si lo empezó y no lo terminó (como "Continuar viendo").</summary>
    static double ResumePosition(SavedPosition saved) =>
        saved.Position > 5 && (saved.Duration <= 0 || saved.Position < saved.Duration * 0.95) ? saved.Position : 0;

    /// <summary>Guarda la posición en el historial local (cada 10 s, al salir y al cerrar la app). Los directos no.</summary>
    public void RecordPosition()
    {
        if (player == null || video == null || stream?.Hls != null || !state.HasVideo.AsBool() || state.Position < 1) return;
        video.Position = state.Position;
        if (state.Duration > 0) video.Progress = Math.Clamp(state.Position / state.Duration, 0, 1);
        _ = GlasstubeFFI.RecordPlayback(video, state.Position, state.Duration);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        RecordPosition();
        _ = GlasstubeFFI.SaveLibrary();
        closed = true;
        poll?.Stop();
        hideTimer?.Stop();
        upNextTimer?.Stop();
        osdTimer?.Stop();
        player?.Dispose();
        player = null;
        SetCursorHidden(false);
        if (App.Window is { } window)
        {
            window.MiniChanged -= OnMiniChanged;
            if (!handingOff)
            {
                window.SetMini(false);
                window.SetFullScreen(false);
            }
        }
    }

    /// <summary>
    /// La tarjeta con la que se abrió puede venir incompleta (--abrir, enlaces): se completa con lo resuelto para que el
    /// historial guarde título, canal, miniatura y duración y no el id.
    /// </summary>
    void CompleteCard(string? title, string? author, string? channelId, double? duration)
    {
        if (video == null) return;
        if (!string.IsNullOrWhiteSpace(title) && (string.IsNullOrWhiteSpace(video.Title) || video.Title == video.Id)) video.Title = title;
        if (string.IsNullOrWhiteSpace(video.Channel) && !string.IsNullOrWhiteSpace(author)) video.Channel = author;
        video.ChannelId ??= channelId;
        video.Thumbnail ??= $"https://i.ytimg.com/vi/{video.Id}/hqdefault.jpg";
        if (video.DurationSeconds == null && duration > 0 && stream?.Hls == null)
        {
            video.DurationSeconds = (int)duration.Value;
            video.Duration ??= Time(duration.Value);
        }
    }

    void Start(StreamInfo resolved, double resumeAt)
    {
        stream = resolved;
        CompleteCard(resolved.Title, resolved.Author, null, resolved.DurationSeconds);
        if (!string.IsNullOrEmpty(resolved.Title)) TitleText.Text = resolved.Title;
        if (!string.IsNullOrEmpty(resolved.Author)) ChannelText.Text = channelName = resolved.Author;
        var (width, height, scale) = PanelPixels();
        player = MpvPlayer.Create(Panel, width, height, scale);
        if (player == null)
        {
            ShowError("No se pudo iniciar mpv.");
            return;
        }
        player.SetVolume(Volume.Value);
        player.SetSpeed(speed);
        player.SetProperty("sub-font-size", "40"); // el 55 de mpv tapa media imagen con subtítulos largos
        UpdateStreamMenus();
        UpdateSubtitleMargin();
        UpdateVideoMargin();
        var url = resolved.Hls ?? resolved.Video?.Url;
        if (url == null)
        {
            ShowError("YouTube no dio URLs para este video.");
            return;
        }
        var result = player.Load(url, resolved.Hls == null ? resolved.Audio?.Url : null, resolved.UserAgent, resolved.Headers,
                                 resolved.Hls == null ? resumeAt : 0);
        if (resumeAt > 0) GlasstubeFFI.Log("app", $"{resolved.VideoId}: sigue en {Time(resumeAt)}");
        if (result < 0)
        {
            ShowError(player.LastError);
            return;
        }
        GlasstubeFFI.Log("app", $"{resolved.VideoId}: cliente {resolved.Client}, video {resolved.Video?.Label} {resolved.Video?.Codec}, audio {resolved.Audio?.Label}{(resolved.Hls != null ? ", HLS" : "")}");
        // `--volcar-urls`: las URLs y cabeceras que recibe mpv, en logs\stream-<id>.json (para medirlas con curl).
        if (Environment.GetCommandLineArgs().Contains("--volcar-urls"))
        {
            try
            {
                var path = Path.Combine(GlasstubeFFI.LogDirectory(), $"stream-{resolved.VideoId}.json");
                File.WriteAllText(path, System.Text.Json.JsonSerializer.Serialize(resolved));
            }
            catch (Exception error) { GlasstubeFFI.Log("app", $"volcar URLs: {error.Message}"); }
        }
        SpinnerText.Text = "Cargando…";
        loadedAt = DateTime.UtcNow;
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
            GlasstubeFFI.Log("app", $"mpv falló: {player.LastError}");
            ShowError($"mpv no pudo abrir el video: {player.LastError}");
            return;
        }
        if (!state.HasVideo.AsBool() && DateTime.UtcNow - loadedAt > StartTimeout)
        {
            poll?.Stop();
            GlasstubeFFI.Log("app", $"sin imagen tras {StartTimeout.TotalSeconds} s (último error de mpv: {player.LastError})");
            ShowError($"El video no empezó en {StartTimeout.TotalSeconds:0} s."
                      + (string.IsNullOrEmpty(player.LastError) ? "" : $" mpv: {player.LastError}"));
            return;
        }
        ApplyCaptions();
        CheckEnded();
        var waiting = !state.HasVideo.AsBool() || state.Buffering.AsBool() || reloading;
        Spinner.Visibility = waiting && !state.Paused.AsBool() ? Visibility.Visible : Visibility.Collapsed;

        var paused = state.Paused.AsBool() || state.Ended.AsBool();
        PlayIcon.Glyph = MiniPlayIcon.Glyph = paused ? "" : "";
        if (state.Paused.AsBool() && !controlsVisible) SetControlsVisible(true);
        TimeText.Text = MiniTimeText.Text = $"{Time(state.Position)} / {Time(state.Duration)}";
        if (!dragging && state.Duration > 0)
        {
            updatingProgress = true;
            Progress.Maximum = state.Duration;
            Progress.Value = Math.Min(state.Position, state.Duration);
            updatingProgress = false;
        }
        UpdateExtras(dragging ? Progress.Value : state.Position);
        // `--medir`: cada 5 s, cómo va la reproducción (para diagnosticar atascos de red).
        if (ticks % 150 == 0 && measuring)
            GlasstubeFFI.Log("medir", $"{video?.Id} t={(DateTime.UtcNow - loadedAt).TotalSeconds:0}s pos={state.Position:0.0}s caché={state.Buffered:0.0}s esperando={state.Buffering} imagen={state.HasVideo}");
        if (ticks++ % 15 == 0) UpdateQuality();
        if (ticks % 300 == 0) RecordPosition();
    }

    /// <summary>"1080p60" con la altura y los cuadros por segundo que da mpv (o la etiqueta del formato elegido).</summary>
    void UpdateQuality()
    {
        if (player == null) return;
        var (height, fps) = player.VideoFormat();
        var label = height > 0 ? fps > 32 ? $"{height}p{Math.Round(fps)}" : $"{height}p" : null;
        label ??= stream?.Hls == null ? stream?.Video?.Label : null;
        QualityText.Text = label ?? "";
        QualityBadge.Visibility = string.IsNullOrEmpty(label) ? Visibility.Collapsed : Visibility.Visible;
        QualityIcon.Visibility = string.IsNullOrEmpty(label) ? Visibility.Visible : Visibility.Collapsed;
    }

    public static string Time(double seconds)
    {
        if (double.IsNaN(seconds) || seconds < 0) seconds = 0;
        var t = TimeSpan.FromSeconds(Math.Floor(seconds));
        return t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");
    }

    void ShowError(string message)
    {
        Spinner.Visibility = Visibility.Collapsed;
        string logs;
        try { logs = Path.GetFullPath(GlasstubeFFI.LogDirectory()); } catch { logs = @"%LOCALAPPDATA%\Glasstube\logs"; }
        ErrorBar.Message = (string.IsNullOrWhiteSpace(message) ? "Error desconocido." : message)
                           + $"\n\nRegistro: {logs}\\glasstube.log";
        ErrorBar.IsOpen = true;
        SetControlsVisible(true);
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

    void OnPanelSizeChanged(object sender, SizeChangedEventArgs e)
    {
        Resize();
        UpdateVideoMargin();
    }
    void OnPanelScaleChanged(SwapChainPanel sender, object args) => Resize();

    // MARK: Mostrar y ocultar controles

    bool IsMini => App.Window?.IsMini == true;

    /// <summary>Controles, título, botón de atrás y cursor aparecen y se ocultan juntos.</summary>
    void SetControlsVisible(bool visible)
    {
        controlsVisible = visible;
        Controls.Opacity = visible && !IsMini ? 1 : 0;
        Controls.IsHitTestVisible = visible && !IsMini;
        MiniControls.Opacity = visible && IsMini ? 1 : 0;
        App.Window?.SetChromeFaded(!visible);
        SetCursorHidden(!visible);
        UpdateSubtitleMargin();
    }

    void ShowControls()
    {
        if (!controlsVisible) SetControlsVisible(true);
        hideTimer?.Stop();
        hideTimer?.Start();
    }

    /// <summary>
    /// Cursor transparente (recurso BLANK de MPVBridge.dll): WinUI no tiene un cursor "ninguno" y lleva el cursor desde
    /// su capa de entrada, así que SetCursor/ShowCursor de Win32 no sirven.
    /// </summary>
    static InputCursor? blankCursor;

    void SetCursorHidden(bool hidden)
    {
        if (hidden)
        {
            try { blankCursor ??= InputDesktopNamedResourceCursor.CreateFromModule("MPVBridge.dll", "BLANK"); }
            catch (Exception error) { GlasstubeFFI.Log("app", $"cursor transparente: {error.Message}"); }
        }
        ProtectedCursor = hidden ? blankCursor : null;
    }

    void OnMiniChanged(object? sender, bool mini)
    {
        Controls.Visibility = mini ? Visibility.Collapsed : Visibility.Visible;
        MiniControls.Visibility = mini ? Visibility.Visible : Visibility.Collapsed;
        SetPanelOpen(panelOpen); // el panel no cabe en el mini reproductor; vuelve al salir
        SetControlsVisible(!mini);
        if (!mini) ShowControls();
    }

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
        if (window.IsMini) window.SetMini(false);
        window.SetFullScreen(!window.IsFullScreen);
        FullScreenIcon.Glyph = window.IsFullScreen ? "" : "";
    }

    void ToggleMini()
    {
        if (App.Window is not { } window) return;
        window.SetMini(!window.IsMini);
        FullScreenIcon.Glyph = "";
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
    void OnBack10(object sender, RoutedEventArgs e) => SeekBy(-10);
    void OnForward10(object sender, RoutedEventArgs e) => SeekBy(10);
    void OnMute(object sender, RoutedEventArgs e) => ToggleMute();
    void OnFullScreen(object sender, RoutedEventArgs e) => ToggleFullScreen();
    void OnMini(object sender, RoutedEventArgs e) => ToggleMini();
    void OnPointerActivity(object sender, PointerRoutedEventArgs e) => ShowControls();
    void OnCapsulePointerEntered(object sender, PointerRoutedEventArgs e) => overCapsule = true;
    void OnCapsulePointerExited(object sender, PointerRoutedEventArgs e) => overCapsule = false;

    void OnPointerLeft(object sender, PointerRoutedEventArgs e)
    {
        // El mini reproductor solo enseña controles con el ratón encima.
        if (IsMini) SetControlsVisible(false);
    }

    void OnDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (IsMini) ToggleMini();
        else ToggleFullScreen();
    }

    void OnTogglePauseKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; TogglePause(); }
    void OnFullScreenKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; ToggleFullScreen(); }
    void OnMiniKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; ToggleMini(); }
    void OnSeekBackKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; SeekBy(-5); }
    void OnSeekForwardKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; SeekBy(5); }
    void OnSeekBack10Key(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; SeekBy(-10); }
    void OnSeekForward10Key(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; SeekBy(10); }
    void OnMuteKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { args.Handled = true; ToggleMute(); }

    void OnEscapeKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        if (IsMini) ToggleMini();
        else if (App.Window?.IsFullScreen == true) ToggleFullScreen();
        else App.Window?.GoBack();
    }
}

static class IntFlag
{
    public static bool AsBool(this int value) => value != 0;
}
