import SwiftUI
import YTKit

/// Filtros de búsqueda (fase 5a) junto al título de los resultados: un menú de vidrio con los grupos del diálogo
/// «Filtros de búsqueda» de YouTube (prioridad, fecha de carga, tipo, duración y características) y, con filtros
/// puestos, un botón para quitarlos. Cada cambio vuelve a buscar con el `params` de Innertube (`SearchFilter`).
struct SearchFilterMenu: View {
    let filter: SearchFilter
    let apply: (SearchFilter) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Prioridad", selection: binding(\.priority)) {
                        ForEach(SearchFilter.Priority.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Fecha de carga", selection: binding(\.uploadDate)) {
                        Text("Cualquier fecha").tag(SearchFilter.UploadDate?.none)
                        ForEach(SearchFilter.UploadDate.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                    Picker("Tipo", selection: binding(\.type)) {
                        Text("Todo").tag(SearchFilter.ResultType?.none)
                        ForEach(SearchFilter.ResultType.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                    Picker("Duración", selection: binding(\.duration)) {
                        Text("Cualquier duración").tag(SearchFilter.Duration?.none)
                        ForEach(SearchFilter.Duration.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                    Section("Características") {
                        ForEach(SearchFilter.Feature.menuOrder, id: \.self) { feature in
                            Toggle(feature.title, isOn: featureBinding(feature))
                        }
                    }
                    if !filter.isEmpty {
                        Divider()
                        Button("Quitar los filtros", systemImage: "xmark.circle") { apply(.none) }
                    }
                } label: {
                    Label(summary, systemImage: "line.3.horizontal.decrease")
                }
                .menuIndicator(.visible)
                .accessibilityLabel(filter.isEmpty ? "Filtros de búsqueda" : "Filtros de búsqueda: \(summary)")
                .help("Prioridad, fecha de carga, tipo, duración y características")

                if !filter.isEmpty {
                    Button { apply(.none) } label: {
                        Label("Quitar los filtros", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .help("Quitar los filtros")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .fixedSize()
        .animation(.smooth(duration: 0.2), value: filter.isEmpty)
    }

    /// «Filtros» o lo que está puesto: «Videos · Esta semana · 3–20 min».
    private var summary: String {
        var parts: [String] = []
        if let type = filter.type { parts.append(type.title) }
        if let date = filter.uploadDate { parts.append(date.title) }
        if let duration = filter.duration { parts.append(duration.shortTitle) }
        if filter.priority != .relevance { parts.append(filter.priority.title) }
        parts += SearchFilter.Feature.menuOrder.filter(filter.features.contains).map(\.title)
        guard !parts.isEmpty else { return "Filtros" }
        return parts.count > 3 ? parts.prefix(3).joined(separator: " · ") + " +\(parts.count - 3)" : parts.joined(separator: " · ")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SearchFilter, Value>) -> Binding<Value> {
        Binding(get: { filter[keyPath: keyPath] }, set: { value in
            var copy = filter
            copy[keyPath: keyPath] = value
            apply(copy)
        })
    }

    private func featureBinding(_ feature: SearchFilter.Feature) -> Binding<Bool> {
        Binding(get: { filter.features.contains(feature) }, set: { on in
            var copy = filter
            if on { copy.features.insert(feature) } else { copy.features.remove(feature) }
            apply(copy)
        })
    }
}

// Los textos del diálogo de YouTube en español (es-419).
extension SearchFilter.Priority {
    var title: String {
        switch self {
        case .relevance: "Relevancia"
        case .popularity: "Popularidad"
        }
    }
}

extension SearchFilter.UploadDate {
    var title: String {
        switch self {
        case .today: "Hoy"
        case .week: "Esta semana"
        case .month: "Este mes"
        case .year: "Este año"
        }
    }
}

extension SearchFilter.ResultType {
    var title: String {
        switch self {
        case .video: "Videos"
        case .shorts: "Shorts"
        case .channel: "Canales"
        case .playlist: "Playlists"
        case .movie: "Películas"
        }
    }
}

extension SearchFilter.Duration {
    var title: String {
        switch self {
        case .underThree: "Menos de 3 minutos"
        case .threeToTwenty: "De 3 a 20 minutos"
        case .overTwenty: "Más de 20 minutos"
        }
    }

    var shortTitle: String {
        switch self {
        case .underThree: "< 3 min"
        case .threeToTwenty: "3–20 min"
        case .overTwenty: "> 20 min"
        }
    }
}

extension SearchFilter.Feature {
    /// En el orden del diálogo de YouTube.
    static let menuOrder: [SearchFilter.Feature] = [.live, .uhd, .hd, .subtitles, .creativeCommons, .hdr]

    var title: String {
        switch self {
        case .live: "En vivo"
        case .uhd: "4K"
        case .hd: "HD"
        case .subtitles: "Subtítulos"
        case .creativeCommons: "Creative Commons"
        case .hdr: "HDR"
        }
    }
}
