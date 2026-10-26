using System.Globalization;
using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Glasstube.Pages;

/// <summary>
/// La cuenta en el reproductor (la fila de arriba de PlayerControls.swift en la app de Mac): Suscribirse / Suscrito y
/// Me gusta / No me gusta con el estado de la cuenta guardada, y los votos de Return YouTube Dislike. Sin sesión los
/// botones de la cuenta quedan atenuados y avisan al pulsarlos; los votos se ven igual.
/// </summary>
public sealed partial class PlayerPage
{
    VideoAccountInfo? account;
    /// <summary>1 me gusta, -1 no me gusta, 0 ninguno (el de la cuenta, o el que se acaba de elegir).</summary>
    int likeState;
    /// <summary>El estado con el que llegaron los votos de RYD (los votos propios se suman o restan respecto a él).</summary>
    int likeStateAtLoad;
    bool subscribed;
    bool accountBusy;

    static readonly Brush ActiveBrush = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"];
    static readonly Brush WhiteBrush = new SolidColorBrush(Microsoft.UI.Colors.White);

    async Task LoadAccount(string videoId)
    {
        try
        {
            account = await GlasstubeFFI.VideoAccount(videoId);
            if (closed) return;
            // --capturas: sin el estado de la cuenta (como si no hubiera sesión); los votos de RYD sí.
            if (CaptureMode.Enabled) account = account with { SignedIn = false, LikeStatus = null, IsSubscribed = null };
            likeState = likeStateAtLoad = account.LikeStatus switch { "like" => 1, "dislike" => -1, _ => 0 };
            subscribed = account.IsSubscribed == true;
            UpdateAccountRow();
            AccountRow.Visibility = Visibility.Visible;
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"{videoId}: sin estado de la cuenta: {error.Message}");
        }
    }

    void UpdateAccountRow()
    {
        if (account == null) return;
        var signedIn = account.SignedIn;
        var dim = signedIn ? 1 : 0.6;

        ChannelButton.Visibility = account.ChannelId != null ? Visibility.Visible : Visibility.Collapsed;
        ChannelButtonText.Text = ChannelAvatar.DisplayName = account.Channel ?? channelName;
        if (account.ChannelAvatar != null && ChannelAvatar.ProfilePicture == null)
            ChannelAvatar.ProfilePicture = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(account.ChannelAvatar)) { DecodePixelWidth = 52 };
        ToolTipService.SetToolTip(ChannelButton, account.Subscribers is { } subscribers ? $"Ver el canal · {subscribers}" : "Ver el canal");
        SubscribeButton.Visibility = account.ChannelId != null ? Visibility.Visible : Visibility.Collapsed;
        SubscribeText.Text = subscribed ? "Suscrito" : "Suscribirse";
        SubscribeIcon.Glyph = subscribed ? "" : "";
        if (subscribed || !signedIn) SubscribeButton.ClearValue(BackgroundProperty);
        else SubscribeButton.Background = ActiveBrush;
        SubscribeButton.Opacity = dim;
        ToolTipService.SetToolTip(SubscribeButton, !signedIn ? "Inicia sesión para suscribirte"
            : subscribed ? $"Anular la suscripción a {account.Channel}" : $"Suscribirse a {account.Channel}");

        // Votos de RYD con el voto propio ajustado (RYD tarda en contarlo); sin RYD, el número de YouTube.
        var likes = account.Likes is { } l ? l + (likeState == 1 ? 1 : 0) - (likeStateAtLoad == 1 ? 1 : 0) : (int?)null;
        var dislikes = account.Dislikes is { } d ? d + (likeState == -1 ? 1 : 0) - (likeStateAtLoad == -1 ? 1 : 0) : (int?)null;
        LikeText.Text = likes is { } shownLikes ? Compact(shownLikes) : account.LikeCountText ?? "";
        DislikeText.Text = dislikes is { } shownDislikes ? Compact(shownDislikes) : "";
        LikeText.Visibility = LikeText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        DislikeText.Visibility = DislikeText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        LikeIcon.Foreground = likeState == 1 ? ActiveBrush : WhiteBrush;
        DislikeIcon.Foreground = likeState == -1 ? ActiveBrush : WhiteBrush;
        LikeIcon.Opacity = DislikeIcon.Opacity = dim;
        ToolTipService.SetToolTip(LikeButton, !signedIn ? "Inicia sesión para dar me gusta"
            : likeState == 1 ? "Quitar el me gusta" : "Me gusta");
        ToolTipService.SetToolTip(DislikeButton, (!signedIn ? "Inicia sesión para votar" : likeState == -1 ? "Quitar el no me gusta" : "No me gusta")
            + (account.Dislikes != null ? " · votos de Return YouTube Dislike" : ""));
    }

    /// <summary>"1.2 K", "3.4 M" (como los números cortos de YouTube).</summary>
    static string Compact(int value) => value switch
    {
        >= 1_000_000 => (value / 1_000_000.0).ToString("0.#", CultureInfo.CurrentCulture) + " M",
        >= 1_000 => (value / 1_000.0).ToString("0.#", CultureInfo.CurrentCulture) + " K",
        _ => value.ToString(CultureInfo.CurrentCulture),
    };

    async Task SetLike(int wanted)
    {
        ShowControls();
        if (account == null || video == null || accountBusy) return;
        if (!account.SignedIn)
        {
            ShowOsd("Inicia sesión para votar");
            return;
        }
        var previous = likeState;
        var status = previous == wanted ? 0 : wanted;
        likeState = status;
        UpdateAccountRow();
        accountBusy = true;
        try
        {
            await GlasstubeFFI.SetLike(video.Id, status, previous);
            ShowOsd(status == 1 ? "Te gusta" : status == -1 ? "No te gusta" : "Voto quitado");
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"me gusta: {error.Message}");
            likeState = previous;
            UpdateAccountRow();
            ShowOsd("No se pudo votar");
        }
        finally
        {
            accountBusy = false;
        }
    }

    /// <summary>La página del canal del video (botón de la fila de la cuenta o el canal de la descripción).</summary>
    void OnChannelClick(object sender, RoutedEventArgs e)
    {
        var id = account?.ChannelId ?? detailsChannelId;
        if (id != null) App.Window?.OpenChannel(id, account?.Channel ?? channelName);
    }

    async void OnLikeClick(object sender, RoutedEventArgs e) => await SetLike(1);
    async void OnDislikeClick(object sender, RoutedEventArgs e) => await SetLike(-1);

    async void OnSubscribeClick(object sender, RoutedEventArgs e)
    {
        ShowControls();
        if (account?.ChannelId is not { } channelId || accountBusy) return;
        if (!account.SignedIn)
        {
            ShowOsd("Inicia sesión para suscribirte");
            return;
        }
        if (subscribed)
        {
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot, RequestedTheme = ElementTheme.Dark, Title = "¿Anular la suscripción?",
                Content = $"Dejarás de ver los videos de {account.Channel} en Suscripciones.",
                PrimaryButtonText = "Anular suscripción", CloseButtonText = "Cancelar", DefaultButton = ContentDialogButton.Close,
            };
            openMenus++;
            try { if (await dialog.ShowAsync() != ContentDialogResult.Primary) return; }
            finally { openMenus--; }
        }
        accountBusy = true;
        var wanted = !subscribed;
        try
        {
            await GlasstubeFFI.Subscribe(channelId, wanted, account.SubscribeParams);
            subscribed = wanted;
            UpdateAccountRow();
            ShowOsd(wanted ? $"Suscrito a {account.Channel}" : "Suscripción anulada");
            // Canales del panel y Bandeja.
            _ = SubscriptionsStore.Shared.LoadAsync(force: true);
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"suscribirse: {error.Message}");
            ShowOsd("No se pudo cambiar la suscripción");
        }
        finally
        {
            accountBusy = false;
        }
    }
}
