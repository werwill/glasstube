using Glasstube.Models;
using Glasstube.Native;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace Glasstube.Controls;

/// <summary>
/// Iniciar sesión con el código de la app de TV, como `ytkit signin`: la persona abre youtube.com/activate (en la PC o
/// en el teléfono), escribe el código con su cuenta de Google y la app espera la aprobación. Glasstube nunca ve la
/// contraseña.
/// </summary>
public static class SignInDialog
{
    /// <summary>Las cuentas tras iniciar sesión, o null si se canceló.</summary>
    public static async Task<AccountList?> ShowAsync(XamlRoot root)
    {
        var code = new TextBlock
        {
            Text = "…", FontSize = 34, FontWeight = FontWeights.SemiBold, CharacterSpacing = 120,
            IsTextSelectionEnabled = true, HorizontalAlignment = HorizontalAlignment.Center,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        };
        var copy = new Button { Content = "Copiar código", IsEnabled = false, HorizontalAlignment = HorizontalAlignment.Center };
        var open = new HyperlinkButton
        {
            Content = "Abrir youtube.com/activate", NavigateUri = new Uri("https://www.youtube.com/activate"),
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        var ring = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
        var status = new TextBlock
        {
            Text = "Pidiendo un código…", TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        };
        var statusRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
        statusRow.Children.Add(ring);
        statusRow.Children.Add(status);

        var content = new StackPanel { Spacing = 14, MaxWidth = 420 };
        content.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Text = "Abre youtube.com/activate en este equipo o en tu teléfono, entra con tu cuenta de Google y escribe este código:",
        });
        content.Children.Add(new Border
        {
            Padding = new Thickness(16, 12, 16, 12), CornerRadius = new CornerRadius(8),
            Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
            Child = code,
        });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        actions.Children.Add(copy);
        actions.Children.Add(open);
        content.Children.Add(actions);
        content.Children.Add(statusRow);
        content.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap, FontSize = 12,
            Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"],
            Text = "Es el mismo inicio de sesión que usan las apps de YouTube para televisores. Glasstube no ve tu contraseña; "
                + "la sesión se guarda en el Administrador de credenciales de Windows.",
        });

        var dialog = new ContentDialog
        {
            XamlRoot = root, Title = "Iniciar sesión en YouTube", Content = content,
            CloseButtonText = "Cancelar", DefaultButton = ContentDialogButton.None,
        };

        AccountList? result = null;
        var closed = false;

        copy.Click += (_, _) =>
        {
            var package = new DataPackage();
            package.SetText(code.Text);
            Clipboard.SetContent(package);
            status.Text = "Código copiado. Esperando a que lo apruebes…";
        };

        async Task Run()
        {
            dialog.PrimaryButtonText = "";
            ring.Visibility = Visibility.Visible;
            copy.IsEnabled = false;
            code.Text = "…";
            status.Text = "Pidiendo un código…";
            try
            {
                var pending = await GlasstubeFFI.BeginSignIn();
                if (closed) return;
                code.Text = pending.UserCode;
                copy.IsEnabled = true;
                if (Uri.TryCreate(pending.VerificationUrl, UriKind.Absolute, out var uri)) open.NavigateUri = uri;
                status.Text = $"Esperando a que lo apruebes (el código vale {Math.Max(1, pending.ExpiresIn / 60)} min)…";
                result = await GlasstubeFFI.WaitForSignIn();
                if (!closed) dialog.Hide();
            }
            catch (Exception error)
            {
                if (closed) return;
                GlasstubeFFI.Log("app", $"inicio de sesión: {error.Message}");
                ring.Visibility = Visibility.Collapsed;
                status.Text = error.Message switch
                {
                    var m when m.Contains("venció") => "El código venció. Pide otro para intentarlo de nuevo.",
                    var m when m.Contains("rechazó el acceso") => "Se rechazó el acceso en la página de activación.",
                    var m => $"No se pudo iniciar sesión: {m}",
                };
                dialog.PrimaryButtonText = "Pedir otro código";
            }
        }

        dialog.PrimaryButtonClick += (_, args) =>
        {
            args.Cancel = true; // el diálogo sigue abierto con el código nuevo
            _ = Run();
        };

        var shown = dialog.ShowAsync();
        _ = Run();
        await shown;
        closed = true;
        if (result == null) GlasstubeFFI.CancelSignIn();
        return result;
    }
}
