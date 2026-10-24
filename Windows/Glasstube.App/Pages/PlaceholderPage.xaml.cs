using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>Secciones que aún no están (Suscripciones, Biblioteca). El parámetro de navegación es la etiqueta.</summary>
public sealed partial class PlaceholderPage : Page
{
    public string Section { get; private set; } = "";

    public PlaceholderPage() => InitializeComponent();

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        Section = e.Parameter as string ?? "";
        (Icon.Glyph, TitleText.Text, MessageText.Text) = Section switch
        {
            "subscriptions" => ("", "Suscripciones", "Próximamente: los videos de tus canales."),
            _ => ("", "Biblioteca", "Próximamente: historial, Ver más tarde y tus listas."),
        };
    }
}
