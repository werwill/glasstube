using System.Globalization;
using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VirtualKey = Windows.System.VirtualKey;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace Glasstube.Pages;

/// <summary>
/// Menús de la cápsula (como QualityMenu, SpeedMenu, CaptionsMenu y AudioMenu de PlayerControls.swift en la app de Mac):
/// calidad y pista de audio (re-resuelven y recargan mpv donde iba, con la misma pausa), velocidad (&lt; y &gt;) y
/// subtítulos (C), cargados en mpv con sub-add. La calidad, el idioma de los subtítulos y si iban activados se
/// recuerdan (PlayerSettings).
/// </summary>
public sealed partial class PlayerPage
{
    static readonly double[] Speeds = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
    /// <summary>La velocidad sigue de un video al siguiente mientras la app está abierta (como el volumen).</summary>
    static double speed = 1;

    PlayerSettings Settings => PlayerSettings.Shared;
    List<CaptionTrackInfo> captions = [];
    CaptionTrackInfo? caption;
    /// <summary>Último <see cref="MpvState.FileLoads"/> con los subtítulos ya puestos (loadfile los descarta).</summary>
    int captionsAppliedForLoad = -1;
    bool subtitleAdded;
    /// <summary>Pista de audio elegida en este video (null = la predeterminada).</summary>
    string? audioTrackId;
    bool reloading;
    int openMenus;
    DispatcherQueueTimer? osdTimer;

    /// <summary>Atajos que XAML no puede nombrar: &lt; y &gt;.</summary>
    void AddSpeedKeys()
    {
        void Add(VirtualKey key, VirtualKeyModifiers modifiers, int step)
        {
            var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
            accelerator.Invoked += (_, args) => { args.Handled = true; StepSpeed(step); };
            KeyboardAccelerators.Add(accelerator);
        }
        Add((VirtualKey)188, VirtualKeyModifiers.Shift, -1); // Shift+, (EE. UU.)
        Add((VirtualKey)190, VirtualKeyModifiers.Shift, +1); // Shift+.
        // La tecla < propia de los teclados de España y Latinoamérica (VK_OEM_102; con Shift, >): un KeyboardAccelerator
        // con esa tecla no llega a dispararse, así que va por KeyDown.
        AddHandler(KeyDownEvent, new KeyEventHandler((_, e) =>
        {
            if (e.Key != (VirtualKey)226) return;
            e.Handled = true;
            var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            StepSpeed(shift ? +1 : -1);
        }), true);
    }

    // MARK: Aviso

    void ShowOsd(string text)
    {
        OsdText.Text = text;
        Osd.Opacity = 1;
        if (osdTimer == null)
        {
            osdTimer = DispatcherQueue.CreateTimer();
            osdTimer.Interval = TimeSpan.FromSeconds(1.4);
            osdTimer.IsRepeating = false;
            osdTimer.Tick += (_, _) => Osd.Opacity = 0;
        }
        osdTimer.Stop();
        osdTimer.Start();
    }

    // Con un menú abierto, los controles no se ocultan.
    void OnMenuOpened(object? sender, object e) { openMenus++; ShowControls(); }
    void OnMenuClosed(object? sender, object e) { openMenus = Math.Max(0, openMenus - 1); ShowControls(); }

    static RadioMenuFlyoutItem Choice(string text, string group, bool selected, Action action)
    {
        var item = new RadioMenuFlyoutItem { Text = text, GroupName = group, IsChecked = selected };
        item.Click += (_, _) => action();
        return item;
    }

    // MARK: Calidad

    /// <summary>Tras cada resolución: qué menús hay (calidad solo sin HLS; audio solo con varias pistas).</summary>
    void UpdateStreamMenus()
    {
        QualityButton.IsEnabled = stream?.Qualities is { Count: > 0 };
        AudioButton.Visibility = stream?.AudioTracks is { Count: > 1 } ? Visibility.Visible : Visibility.Collapsed;
        audioTrackId = stream?.AudioTrackId;
    }

    void OnQualityMenuOpening(object sender, object e)
    {
        QualityMenu.Items.Clear();
        var current = stream?.Video?.Height;
        QualityMenu.Items.Add(Choice(Settings.Quality == 0 && current is { } h ? $"Auto ({h}p)" : "Auto", "calidad",
                                     Settings.Quality == 0, () => ChooseQuality(0)));
        QualityMenu.Items.Add(new MenuFlyoutSeparator());
        foreach (var option in stream?.Qualities ?? [])
            QualityMenu.Items.Add(Choice(option.Label, "calidad", Settings.Quality != 0 && option.Height == current,
                                         () => ChooseQuality(option.Height)));
    }

    void ChooseQuality(int height)
    {
        Settings.Quality = height;
        Settings.Save();
        GlasstubeFFI.Log("app", $"calidad: {(height == 0 ? "auto" : $"{height}p")}");
        ShowOsd(height == 0 ? "Calidad: Auto" : $"Calidad: {height}p");
        _ = Reload("Cambiando la calidad…");
    }

    // MARK: Pista de audio

    void OnAudioMenuOpening(object sender, object e)
    {
        AudioMenu.Items.Clear();
        foreach (var track in stream?.AudioTracks ?? [])
            AudioMenu.Items.Add(Choice(track.IsDefault && !track.Name.Contains("original", StringComparison.OrdinalIgnoreCase)
                                           ? $"{track.Name} (original)" : track.Name, "audio",
                                       track.Id == audioTrackId, () => ChooseAudio(track)));
    }

    void ChooseAudio(AudioTrackOption track)
    {
        if (track.Id == audioTrackId) return;
        audioTrackId = track.Id;
        GlasstubeFFI.Log("app", $"pista de audio: {track.Name} ({track.Id})");
        ShowOsd($"Audio: {track.Name}");
        _ = Reload("Cambiando el audio…");
    }

    /// <summary>Vuelve a resolver con la calidad y el audio elegidos y recarga mpv donde iba (pausado si lo estaba).</summary>
    async Task Reload(string message)
    {
        if (video == null || player == null || reloading || stream?.Hls != null) return;
        reloading = true;
        var position = state.Position;
        SpinnerText.Text = message;
        Spinner.Visibility = Visibility.Visible;
        try
        {
            var resolved = await GlasstubeFFI.ResolveStream(video.Id, Settings.Quality, audioTrackId).WaitAsync(ResolveTimeout);
            if (closed || player == null || resolved.Video == null) return;
            // Pausa y velocidad son propiedades de mpv y siguen igual tras loadfile; la posición va en `start`.
            var result = player.Load(resolved.Video.Url, resolved.Audio?.Url, resolved.UserAgent, resolved.Headers, position);
            if (result < 0) throw new GlasstubeException(player.LastError);
            stream = resolved;
            loadedAt = DateTime.UtcNow;
            UpdateStreamMenus();
            GlasstubeFFI.Log("app", $"{resolved.VideoId}: recargado en {Time(position)} con video {resolved.Video.Label} {resolved.Video.Codec}, audio {resolved.Audio?.Label}");
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"recargar: {error.Message}");
            ShowOsd("No se pudo cambiar");
        }
        finally
        {
            reloading = false;
            SpinnerText.Text = "Cargando…";
        }
    }

    // MARK: Velocidad

    void OnSpeedMenuOpening(object sender, object e)
    {
        SpeedMenu.Items.Clear();
        foreach (var value in Speeds)
            SpeedMenu.Items.Add(Choice(SpeedLabel(value), "velocidad", value == speed, () => SetSpeed(value)));
    }

    static string SpeedLabel(double value) => value == 1 ? "Normal" : value.ToString("0.##", CultureInfo.CurrentCulture) + "×";

    void SetSpeed(double value)
    {
        speed = value;
        player?.SetSpeed(value);
        SpeedText.Text = value.ToString("0.##", CultureInfo.CurrentCulture) + "×";
        ShowOsd($"Velocidad: {SpeedLabel(value)}");
    }

    void StepSpeed(int step)
    {
        var index = Array.IndexOf(Speeds, speed);
        if (index < 0) index = Array.IndexOf(Speeds, 1.0);
        SetSpeed(Speeds[Math.Clamp(index + step, 0, Speeds.Length - 1)]);
        ShowControls();
    }

    // MARK: Subtítulos

    async Task LoadCaptions(string videoId)
    {
        try
        {
            captions = (await GlasstubeFFI.Captions(videoId)).Tracks;
            if (closed) return;
            CaptionsButton.IsEnabled = captions.Count > 0;
            ToolTipService.SetToolTip(CaptionsButton, captions.Count > 0 ? "Subtítulos (C)" : "Sin subtítulos");
            if (Settings.CaptionsOn && captions.Count > 0) SelectCaption(PreferredCaption(), remember: false);
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"{videoId}: sin subtítulos: {error.Message}");
            ToolTipService.SetToolTip(CaptionsButton, "Sin subtítulos");
        }
    }

    /// <summary>Los del último idioma (o el de la interfaz): escritos a mano antes que automáticos; si no, los primeros.</summary>
    CaptionTrackInfo? PreferredCaption()
    {
        var language = Settings.CaptionLanguage ?? CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
        return captions.FirstOrDefault(c => c.LanguageCode.StartsWith(language, StringComparison.OrdinalIgnoreCase) && !c.IsAutomatic)
               ?? captions.FirstOrDefault(c => c.LanguageCode.StartsWith(language, StringComparison.OrdinalIgnoreCase))
               ?? captions.FirstOrDefault(c => !c.IsAutomatic) ?? captions.FirstOrDefault();
    }

    void OnCaptionsMenuOpening(object sender, object e)
    {
        CaptionsMenu.Items.Clear();
        CaptionsMenu.Items.Add(Choice("Desactivados", "subtitulos", caption == null, () => SelectCaption(null)));
        if (captions.Count > 0) CaptionsMenu.Items.Add(new MenuFlyoutSeparator());
        // Los escritos a mano primero; los automáticos al final.
        foreach (var track in captions.OrderBy(c => c.IsAutomatic))
            CaptionsMenu.Items.Add(Choice(track.Title, "subtitulos", ReferenceEquals(track, caption), () => SelectCaption(track)));
    }

    void SelectCaption(CaptionTrackInfo? track, bool remember = true)
    {
        caption = track;
        captionsAppliedForLoad = -1; // se ponen en mpv en el siguiente Tick (cuando el archivo esté abierto)
        CaptionsOnMark.Visibility = track != null ? Visibility.Visible : Visibility.Collapsed;
        if (remember)
        {
            Settings.CaptionsOn = track != null;
            if (track != null) Settings.CaptionLanguage = track.LanguageCode.Split('-')[0];
            Settings.Save();
            ShowOsd(track == null ? "Subtítulos desactivados" : $"Subtítulos: {track.Title}");
        }
    }

    /// <summary>Desde Tick: pone (o quita) los subtítulos en mpv cuando hay un archivo abierto que aún no los tiene.</summary>
    void ApplyCaptions()
    {
        if (player == null || state.FileLoads == 0 || captionsAppliedForLoad == state.FileLoads) return;
        captionsAppliedForLoad = state.FileLoads;
        if (caption == null && !subtitleAdded) return; // nada que quitar
        subtitleAdded = caption != null;
        player.SetSubtitle(caption?.Url, caption?.Title, caption?.LanguageCode);
        if (caption != null) GlasstubeFFI.Log("app", $"subtítulos: {caption.Title}");
    }

    /// <summary>
    /// Con los controles a la vista, los subtítulos suben por encima de la cápsula. `sub-margin-y` va en píxeles de una
    /// pantalla de 720 de alto (mpv escala con la ventana); 22 es el valor de mpv.
    /// </summary>
    void UpdateSubtitleMargin()
    {
        if (player == null || Panel.ActualHeight <= 0) return;
        // Lo que la cápsula tapa del video (que puede no llegar abajo), en proporción a su alto.
        var capsuleTop = Root.ActualHeight - (Capsule.ActualHeight + Capsule.Margin.Bottom + 12);
        var covered = controlsVisible && !IsMini ? Math.Max(0, Panel.Margin.Top + Panel.ActualHeight - capsuleTop) : 0;
        var margin = Math.Max(22, covered / Panel.ActualHeight * 720);
        player.SetProperty("sub-margin-y", Math.Round(margin).ToString(CultureInfo.InvariantCulture));
    }

    double VideoAspect()
    {
        var match = System.Text.RegularExpressions.Regex.Match(stream?.Video?.Label ?? "", @"^(\d+)x(\d+)");
        return match.Success && double.Parse(match.Groups[2].Value) > 0
            ? double.Parse(match.Groups[1].Value) / double.Parse(match.Groups[2].Value) : 16.0 / 9;
    }

    void ToggleCaptions()
    {
        if (caption != null) SelectCaption(null);
        else if (captions.Count == 0) ShowOsd("Este video no tiene subtítulos");
        else SelectCaption(PreferredCaption());
        ShowControls();
    }

    void OnCaptionsKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        ToggleCaptions();
    }
}
