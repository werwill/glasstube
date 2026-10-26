using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace Glasstube.Pages;

/// <summary>
/// Panel lateral del reproductor (como SidePanel.swift en la app de Mac): Descripción (gt_video_details, con los
/// capítulos para saltar), Comentarios (gt_comments: Destacados o Recientes, respuestas desplegables y «Cargar más») y
/// Sugeridos (gt_watch_next). También la reproducción automática: al terminar, el siguiente sugerido tras 5 s.
/// </summary>
public sealed partial class PlayerPage
{
    const double PanelGap = 12;
    const int UpNextSeconds = 5;

    static bool panelOpen;
    string? detailsChannelId;
    WatchNextInfo? watchNext;
    bool commentsLoaded;
    bool loadingComments;
    string? commentsContinuation;
    bool overPanel;
    DispatcherQueueTimer? upNextTimer;
    int upNextLeft;
    bool upNextShown;
    /// <summary>Se va a otro video desde este reproductor: no salir de pantalla completa ni del mini reproductor.</summary>
    bool handingOff;

    static readonly Brush Secondary = new SolidColorBrush(Color.FromArgb(0xB3, 0xFF, 0xFF, 0xFF));
    static readonly Brush Primary = new SolidColorBrush(Microsoft.UI.Colors.White);

    // MARK: Abrir y cerrar

    void SetPanelOpen(bool open)
    {
        panelOpen = open;
        var visible = open && !IsMini;
        SidePanel.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        // La cápsula, el título y las píldoras se quedan a la izquierda del panel: no se tapan.
        var right = visible ? SidePanel.Width + SidePanel.Margin.Right + PanelGap : 24;
        Capsule.Margin = new Thickness(24, 0, right, 24);
        SkipButton.Margin = new Thickness(0, 0, right + 8, SkipButton.Margin.Bottom);
        UpNextCard.Margin = new Thickness(0, 0, right, UpNextCard.Margin.Bottom);
        UpdateVideoMargin();
        PanelIcon.Glyph = visible ? "" : "";
        if (visible && ReferenceEquals(PanelTabs.SelectedItem, CommentsTab)) _ = LoadComments(null);
    }

    /// <summary>Con el panel abierto, mpv encoge el video (y los subtítulos) a la parte que queda a su izquierda.</summary>
    void UpdateVideoMargin()
    {
        if (player == null || Panel.ActualWidth <= 0) return;
        var covered = panelOpen && !IsMini ? SidePanel.Width + SidePanel.Margin.Right + PanelGap : 0;
        var ratio = Math.Clamp(covered / Panel.ActualWidth, 0, 0.6);
        player.SetProperty("video-margin-ratio-right", ratio.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture));
        // Si no, los subtítulos usan el ancho entero de la ventana (el margen cuenta como franja negra) y quedan bajo el panel.
        player.SetProperty("sub-use-margins", covered > 0 ? "no" : "yes");
        UpdateSubtitleMargin();
    }

    void TogglePanel()
    {
        SetPanelOpen(!panelOpen);
        ShowControls();
    }

    void OnTogglePanel(object sender, RoutedEventArgs e) => TogglePanel();

    void OnPanelKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        TogglePanel();
    }

    void OnSidePanelPointerEntered(object sender, PointerRoutedEventArgs e) => overPanel = true;
    void OnSidePanelPointerExited(object sender, PointerRoutedEventArgs e) => overPanel = false;

    void OnPanelTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var item = sender.SelectedItem;
        DescriptionView.Visibility = ReferenceEquals(item, DescriptionTab) ? Visibility.Visible : Visibility.Collapsed;
        CommentsView.Visibility = ReferenceEquals(item, CommentsTab) ? Visibility.Visible : Visibility.Collapsed;
        SuggestionsView.Visibility = ReferenceEquals(item, SuggestionsTab) ? Visibility.Visible : Visibility.Collapsed;
        if (ReferenceEquals(item, CommentsTab)) _ = LoadComments(null);
    }

    // MARK: Descripción

    /// <summary>Con los detalles del video (PlayerPage.Chapters.cs): título, vistas y fecha, canal, texto y capítulos.</summary>
    void FillDescription(VideoDetails details)
    {
        PanelTitle.Text = details.Title ?? video?.Title ?? "";
        PanelMeta.Text = string.Join(" · ", new[] { details.Views, details.Published }.Where(s => !string.IsNullOrWhiteSpace(s)));
        PanelChannel.Text = details.Author ?? channelName;
        detailsChannelId = details.ChannelId;
        PanelChannelButton.IsEnabled = details.ChannelId != null;
        PanelAvatar.DisplayName = PanelChannel.Text;
        if (details.Avatar != null) PanelAvatar.ProfilePicture = new BitmapImage(new Uri(details.Avatar)) { DecodePixelWidth = 32 };
        PanelDescription.Text = string.IsNullOrWhiteSpace(details.Description) ? "Sin descripción." : details.Description.Trim();
        ChaptersList.Children.Clear();
        ChaptersHeader.Visibility = chapters.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var chapter in chapters)
        {
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(56) });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.Children.Add(new TextBlock { Text = Time(chapter.Start), Foreground = (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"], FontSize = 12 });
            var title = new TextBlock { Text = chapter.Title, Foreground = Primary, FontSize = 13, TextWrapping = TextWrapping.Wrap };
            Grid.SetColumn(title, 1);
            row.Children.Add(title);
            var button = new Button
            {
                Content = row, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(8, 6, 8, 6),
            };
            AutomationProperties_SetName(button, $"{Time(chapter.Start)} {chapter.Title}");
            var start = chapter.Start;
            button.Click += (_, _) => { player?.Seek(start); ShowControls(); };
            ChaptersList.Children.Add(button);
        }
    }

    static void AutomationProperties_SetName(DependencyObject element, string name) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, name);

    // MARK: Sugeridos y reproducción automática

    async Task LoadWatchNext(string videoId)
    {
        AutoplaySwitch.IsOn = Settings.Autoplay;
        try
        {
            watchNext = await GlasstubeFFI.WatchNext(videoId);
            if (closed) return;
            SuggestionsList.ItemsSource = watchNext.Suggestions;
            SuggestionsMessage.Visibility = watchNext.Suggestions.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            SuggestionsMessage.Text = "No hay sugeridos para este video.";
            CommentsCountText.Text = watchNext.CommentsCount is { } count ? $"{count} comentarios" : "";
            CommentSortButtons.Visibility = watchNext.CommentSorts.Count >= 2 ? Visibility.Visible : Visibility.Collapsed;
            if (ReferenceEquals(PanelTabs.SelectedItem, CommentsTab) && panelOpen) _ = LoadComments(null);
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"{videoId}: sin sugeridos: {error.Message}");
            SuggestionsMessage.Text = $"No se pudieron cargar los sugeridos: {error.Message}";
            CommentsMessage.Text = "No se pudieron cargar los comentarios.";
            CommentsMessage.Visibility = Visibility.Visible;
        }
    }

    void OnSuggestionClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is VideoCard card) PlayOther(card);
    }

    /// <summary>Abre otro video en lugar de este (sin dejar este reproductor en el historial de atrás).</summary>
    void PlayOther(VideoCard card)
    {
        CancelUpNext();
        handingOff = true;
        App.Window?.Play(card, replacePlayer: true);
    }

    void OnAutoplayToggled(object sender, RoutedEventArgs e)
    {
        if (Settings.Autoplay == AutoplaySwitch.IsOn) return;
        Settings.Autoplay = AutoplaySwitch.IsOn;
        Settings.Save();
        if (!Settings.Autoplay) CancelUpNext();
    }

    /// <summary>Desde Tick: al terminar, la cuenta atrás hacia el siguiente sugerido (una vez por video).</summary>
    void CheckEnded()
    {
        if (!state.Ended.AsBool())
        {
            if (upNextShown && state.Position < state.Duration - 2) upNextShown = false; // volvió atrás: se puede ofrecer otra vez
            return;
        }
        if (upNextShown || !Settings.Autoplay || watchNext?.Next is not { } next) return;
        upNextShown = true;
        UpNextTitle.Text = next.Title;
        UpNextChannel.Text = next.Channel ?? "";
        UpNextImage.Source = next.ThumbnailImage;
        upNextLeft = UpNextSeconds;
        UpNextCountdown.Text = $"Siguiente en {upNextLeft}";
        UpNextCard.Visibility = Visibility.Visible;
        GlasstubeFFI.Log("app", $"terminó; siguiente en {UpNextSeconds} s: {next.Id} «{next.Title}»");
        if (upNextTimer == null)
        {
            upNextTimer = DispatcherQueue.CreateTimer();
            upNextTimer.Interval = TimeSpan.FromSeconds(1);
            upNextTimer.Tick += (_, _) =>
            {
                if (--upNextLeft > 0)
                {
                    UpNextCountdown.Text = $"Siguiente en {upNextLeft}";
                    return;
                }
                upNextTimer?.Stop();
                if (watchNext?.Next is { } card) PlayOther(card);
            };
        }
        upNextTimer.Start();
        SetControlsVisible(true);
    }

    void CancelUpNext()
    {
        upNextTimer?.Stop();
        UpNextCard.Visibility = Visibility.Collapsed;
    }

    void OnCancelUpNext(object sender, RoutedEventArgs e)
    {
        GlasstubeFFI.Log("app", "reproducción automática cancelada");
        CancelUpNext();
    }

    void OnPlayUpNext(object sender, RoutedEventArgs e)
    {
        if (watchNext?.Next is { } card) PlayOther(card);
    }

    // MARK: Comentarios

    /// <summary>Primera página (token null: la del orden elegido) o la siguiente (con <see cref="commentsContinuation"/>).</summary>
    async Task LoadComments(string? continuation)
    {
        if (loadingComments || watchNext == null || (continuation == null && commentsLoaded)) return;
        var token = continuation ?? SelectedSortToken();
        if (token == null)
        {
            commentsLoaded = true;
            CommentsMessage.Text = "Los comentarios están desactivados en este video.";
            CommentsMessage.Visibility = Visibility.Visible;
            return;
        }
        loadingComments = true;
        commentsLoaded = true;
        CommentsSpinner.IsActive = true;
        MoreCommentsButton.Visibility = Visibility.Collapsed;
        CommentsMessage.Visibility = Visibility.Collapsed;
        try
        {
            var page = await GlasstubeFFI.Comments(token);
            if (closed) return;
            foreach (var comment in page.Comments) CommentsList.Children.Add(CommentView(comment, isReply: false));
            commentsContinuation = page.Continuation;
            if (CommentsList.Children.Count == 0)
            {
                CommentsMessage.Text = "Todavía no hay comentarios.";
                CommentsMessage.Visibility = Visibility.Visible;
            }
            GlasstubeFFI.Log("app", $"comentarios: {page.Comments.Count} más (total {CommentsList.Children.Count}), siguen: {page.Continuation != null}");
        }
        catch (Exception error)
        {
            GlasstubeFFI.Log("app", $"comentarios: {error.Message}");
            CommentsMessage.Text = $"No se pudieron cargar los comentarios: {error.Message}";
            CommentsMessage.Visibility = Visibility.Visible;
            if (continuation == null) commentsLoaded = false;
        }
        finally
        {
            loadingComments = false;
            CommentsSpinner.IsActive = false;
            MoreCommentsButton.Visibility = commentsContinuation != null ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    /// <summary>El token de Destacados (el primer orden) o Recientes (el segundo); sin órdenes, el de la página.</summary>
    string? SelectedSortToken()
    {
        var sorts = watchNext?.CommentSorts ?? [];
        if (sorts.Count >= 2) return sorts[NewestCommentsButton.IsChecked == true ? 1 : 0].Token;
        return watchNext?.CommentsToken;
    }

    void OnCommentSort(object sender, RoutedEventArgs e)
    {
        var newest = ReferenceEquals(sender, NewestCommentsButton);
        TopCommentsButton.IsChecked = !newest;
        NewestCommentsButton.IsChecked = newest;
        if (loadingComments) return;
        CommentsList.Children.Clear();
        commentsContinuation = null;
        commentsLoaded = false;
        CommentsScroller.ChangeView(null, 0, null, true);
        _ = LoadComments(null);
    }

    void OnMoreComments(object sender, RoutedEventArgs e)
    {
        if (commentsContinuation != null) _ = LoadComments(commentsContinuation);
    }

    /// <summary>Un comentario: foto, autor y fecha, texto, me gusta y, si tiene, el botón de sus respuestas.</summary>
    FrameworkElement CommentView(CommentInfo comment, bool isReply)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var size = isReply ? 24 : 32;
        // --capturas: quien comenta sale como @personaN y sin foto (el canal del video sí, con su nombre).
        var anonymous = CaptureMode.Enabled && !comment.AuthorIsChannelOwner;
        var name = anonymous ? CaptureMode.Person(comment.Author) : comment.Author;
        grid.Children.Add(new PersonPicture
        {
            Width = size, Height = size, DisplayName = anonymous ? "" : name.TrimStart('@'),
            ProfilePicture = anonymous ? null : comment.AvatarImage, VerticalAlignment = VerticalAlignment.Top,
        });

        var body = new StackPanel { Spacing = 4 };
        Grid.SetColumn(body, 1);
        grid.Children.Add(body);

        if (comment.IsPinned)
        {
            body.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 4,
                Children = { new FontIcon { Glyph = "", FontSize = 11, Foreground = Secondary },
                             new TextBlock { Text = "Fijado", FontSize = 11, Foreground = Secondary } },
            });
        }
        var header = new TextBlock { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
        var author = new Microsoft.UI.Xaml.Documents.Run { Text = name, FontWeight = FontWeights.SemiBold };
        author.Foreground = comment.AuthorIsChannelOwner ? (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"] : Primary;
        header.Inlines.Add(author);
        if (!string.IsNullOrEmpty(comment.Published))
            header.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "  " + comment.Published, Foreground = Secondary });
        body.Children.Add(header);
        body.Children.Add(new TextBlock
        {
            Text = comment.Text, Foreground = Primary, FontSize = 13, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
        });

        var footer = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        footer.Children.Add(new FontIcon { Glyph = "", FontSize = 12, Foreground = Secondary });
        footer.Children.Add(new TextBlock { Text = comment.Likes ?? "", FontSize = 12, Foreground = Secondary, Margin = new Thickness(0, 0, 8, 0) });
        if (comment.IsHearted) footer.Children.Add(new FontIcon { Glyph = "", FontSize = 12, Foreground = new SolidColorBrush(Color.FromArgb(0xFF, 0xFF, 0x45, 0x5F)) });
        body.Children.Add(footer);

        if (!isReply && comment.RepliesToken is { } token)
        {
            var replies = new StackPanel { Spacing = 12, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };
            var label = comment.ReplyCountText ?? (comment.ReplyCount is { } n ? $"{n} respuestas" : "Respuestas");
            var toggle = new HyperlinkButton { Content = $"▾ {label}", Padding = new Thickness(0, 2, 0, 2), FontSize = 12 };
            var loaded = false;
            toggle.Click += async (_, _) =>
            {
                var open = replies.Visibility == Visibility.Collapsed;
                replies.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
                toggle.Content = $"{(open ? "▴" : "▾")} {label}";
                if (!open || loaded) return;
                loaded = true;
                await LoadReplies(replies, token, isFirst: true);
            };
            body.Children.Add(toggle);
            body.Children.Add(replies);
        }
        return grid;
    }

    /// <summary>Respuestas de un comentario (y sus páginas siguientes, con su propio «Cargar más respuestas»).</summary>
    async Task LoadReplies(StackPanel replies, string token, bool isFirst)
    {
        var spinner = new ProgressRing { IsActive = true, Width = 18, Height = 18, Foreground = Primary, HorizontalAlignment = HorizontalAlignment.Left };
        replies.Children.Add(spinner);
        try
        {
            var page = await GlasstubeFFI.Comments(token, replies: isFirst);
            replies.Children.Remove(spinner);
            foreach (var reply in page.Comments) replies.Children.Add(CommentView(reply, isReply: true));
            if (page.Continuation is { } next)
            {
                var more = new HyperlinkButton { Content = "Cargar más respuestas", FontSize = 12, Padding = new Thickness(0, 2, 0, 2) };
                more.Click += async (_, _) =>
                {
                    replies.Children.Remove(more);
                    await LoadReplies(replies, next, isFirst: false);
                };
                replies.Children.Add(more);
            }
        }
        catch (Exception error)
        {
            replies.Children.Remove(spinner);
            replies.Children.Add(new TextBlock { Text = $"No se pudieron cargar: {error.Message}", Foreground = Secondary, FontSize = 12, TextWrapping = TextWrapping.Wrap });
        }
    }
}
