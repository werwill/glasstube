using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Glasstube.Pages;

/// <summary>Búsqueda (aún sin resultados: la FFI no la expone). El parámetro de navegación es el texto.</summary>
public sealed partial class SearchPage : Page
{
    public SearchPage() => InitializeComponent();

    protected override void OnNavigatedTo(NavigationEventArgs e) => TitleText.Text = $"Buscar: {e.Parameter as string}";
}
