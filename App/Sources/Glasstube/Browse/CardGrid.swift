import SwiftUI
import YTKit

/// Posición de una tarjeta en una página de secciones (para el foco del teclado).
nonisolated struct CardSlot: Hashable, Sendable {
    var section: Int
    var index: Int
}

/// Tarjeta enfocada de una página. Es un objeto y no `@State`: el cierre de `onKeyPress` leía un valor viejo de un
/// `@State` (se quedaba en la primera tarjeta); un objeto siempre da el actual.
@Observable
final class GridFocus {
    var selection: CardSlot?
    /// La página tiene el foco del teclado (copia del `FocusState`, que la vista de la página no veía actualizado).
    var hasFocus = false
    /// Se usó el teclado en la página: el anillo de foco solo aparece entonces (como `:focus-visible` en la web), así que
    /// al arrancar el contenido ya responde a las flechas sin marcar una tarjeta a quien usa el ratón.
    var keyboardActive = false
    /// La tarjeta a resaltar: solo mientras la página tiene el foco y se está usando el teclado.
    var focusedSlot: CardSlot? { hasFocus && keyboardActive ? selection : nil }
    /// Posición del `ScrollView` de la página, para llevar la tarjeta enfocada a la vista.
    var scroll = ScrollPosition(idType: CardSlot.self)
}

nonisolated enum GridMetrics {
    static let minWidth: CGFloat = 220
    static let columnSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 24
    static let shortWidth: CGFloat = 168
    static let pagePadding: CGFloat = 26

    static func columns(for width: CGFloat, minimum: CGFloat = minWidth) -> Int {
        max(1, Int((width + columnSpacing) / (minimum + columnSpacing)))
    }

    static func gridItems(minimum: CGFloat = minWidth) -> [GridItem] {
        [GridItem(.adaptive(minimum: minimum), spacing: columnSpacing, alignment: .top)]
    }
}

/// Una sección de tarjetas: título, "Ver todo" opcional y cuadrícula adaptable (`LazyVGrid`). Las filas de Shorts van
/// en una sola fila horizontal.
struct CardSection: View {
    let title: String?
    let items: [MediaItem]
    let section: Int
    /// Foco del teclado de la página (ver `GridKeyboardNavigation`). Se lee al principio de `body`: leído dentro del
    /// cierre del `ForEach`, la vista no se enteraba de los cambios.
    var grid: GridFocus?
    var progress: (MediaItem) -> Double? = { _ in nil }
    var seeAll: (() -> Void)?
    /// Shorts en cuadrícula (la página de Shorts) en lugar de una fila horizontal.
    var shortsAsGrid = false

    var isShorts: Bool { !items.isEmpty && items.allSatisfy(\.isShort) }

    var body: some View {
        let focused = grid?.focusedSlot
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || seeAll != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(.system(size: 20, weight: .bold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer()
                    if let seeAll {
                        Button("Ver todo", action: seeAll)
                            .buttonStyle(.link)
                            .font(.system(size: 14, weight: .medium))
                    }
                }
            }
            if isShorts && shortsAsGrid {
                LazyVGrid(columns: GridMetrics.gridItems(minimum: GridMetrics.shortWidth), alignment: .leading,
                          spacing: GridMetrics.rowSpacing) {
                    cards(focused: focused)
                }
            } else if isShorts {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: GridMetrics.columnSpacing) {
                        cards(focused: focused).frame(width: GridMetrics.shortWidth)
                    }
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.never)
            } else {
                LazyVGrid(columns: GridMetrics.gridItems(), alignment: .leading, spacing: GridMetrics.rowSpacing) {
                    cards(focused: focused)
                }
            }
        }
    }

    private func cards(focused: CardSlot?) -> some View {
        // La identidad del ForEach es la posición: así `ScrollViewReader.scrollTo` encuentra también las tarjetas que
        // la cuadrícula perezosa aún no creó.
        ForEach(items.indices.map { CardSlot(section: section, index: $0) }, id: \.self) { slot in
            ItemCard(item: items[slot.index], progress: progress(items[slot.index]), isFocused: focused == slot)
        }
    }
}

/// Flechas, Tab y Retorno en una página de secciones: el foco se mueve por la cuadrícula como con la cruceta en
/// SmartTube (arriba y abajo cambian de fila y de sección; Retorno abre; ← en la primera columna va a la barra lateral).
///
/// La página entera es una sola vista enfocable y la tarjeta enfocada es estado propio: en macOS las vistas con
/// `.focusable(interactions: .activate)` solo reciben el foco con "Navegación con teclado" activada, y asignar el foco
/// a tarjetas dentro de un `LazyVGrid` no surte efecto. Así funciona igual con o sin esa opción del sistema.
struct GridKeyboardNavigation: ViewModifier {
    /// Elementos de cada sección y cuántas columnas tiene (una fila horizontal: todas).
    let sections: [(items: [MediaItem], columns: Int)]
    let grid: GridFocus
    var isFocused: FocusState<Bool>.Binding
    let open: (MediaItem) -> Void
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var grid = grid
        content
            .scrollPosition($grid.scroll)
            .focusable()
            .focusEffectDisabled()
            .focused(isFocused)
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                // La primera flecha solo muestra dónde está el foco.
                guard grid.keyboardActive else {
                    grid.keyboardActive = true
                    if grid.selection.flatMap(item(at:)) == nil { grid.selection = firstSlot }
                    return .handled
                }
                // ← en la primera columna: a la barra lateral.
                if press.key == .leftArrow, let slot = grid.selection, sections.indices.contains(slot.section),
                   slot.index % max(1, sections[slot.section].columns) == 0 {
                    model.focusSidebar()
                    return .handled
                }
                guard let next = move(from: grid.selection, key: press.key) else { return .ignored }
                grid.selection = next
                return .handled
            }
            .onKeyPress(.tab) {
                grid.keyboardActive = true
                grid.selection = step(from: grid.selection, by: NSEvent.modifierFlags.contains(.shift) ? -1 : 1)
                return .handled
            }
            .onKeyPress(keys: [.return, .space]) { _ in
                guard let slot = grid.selection, let item = item(at: slot) else { return .ignored }
                open(item)
                return .handled
            }
            // El foco entra al contenido al pedirlo (→ desde la barra lateral, al cargar o tras una búsqueda).
            .onChange(of: model.contentFocusRequest) {
                isFocused.wrappedValue = true
                grid.hasFocus = true
                if model.contentFocusFromKeyboard { grid.keyboardActive = true }
                if grid.selection.flatMap(item(at:)) == nil { grid.selection = firstSlot }
            }
            .onChange(of: isFocused.wrappedValue, initial: true) { _, focused in
                grid.hasFocus = focused
                if focused, grid.selection.flatMap(item(at:)) == nil { grid.selection = firstSlot }
            }
            .onChange(of: grid.selection) { _, slot in
                if let slot { withAnimation(.smooth(duration: 0.25)) { grid.scroll.scrollTo(id: slot) } }
                if Automation.shared.logsKeys { NSLog("Glasstube automation: tarjeta enfocada = \(String(describing: slot)) (foco \(grid.hasFocus))") }
            }
    }

    private var firstSlot: CardSlot? {
        sections.indices.first { !sections[$0].items.isEmpty }.map { CardSlot(section: $0, index: 0) }
    }

    /// Tab y Shift+Tab: la tarjeta siguiente o anterior en orden de lectura.
    private func step(from slot: CardSlot?, by delta: Int) -> CardSlot? {
        let all = sections.indices.flatMap { section in sections[section].items.indices.map { CardSlot(section: section, index: $0) } }
        guard !all.isEmpty else { return nil }
        guard let slot, let index = all.firstIndex(of: slot) else { return all.first }
        return all[(index + delta + all.count) % all.count]
    }

    private func item(at slot: CardSlot) -> MediaItem? {
        guard sections.indices.contains(slot.section), sections[slot.section].items.indices.contains(slot.index) else { return nil }
        return sections[slot.section].items[slot.index]
    }

    private func move(from slot: CardSlot?, key: KeyEquivalent) -> CardSlot? {
        let nonEmpty = sections.indices.filter { !sections[$0].items.isEmpty }
        guard let first = nonEmpty.first else { return nil }
        guard let slot, sections.indices.contains(slot.section) else { return CardSlot(section: first, index: 0) }
        let count = sections[slot.section].items.count
        let columns = max(1, sections[slot.section].columns)
        let column = slot.index % columns
        let previous = nonEmpty.last { $0 < slot.section }
        let following = nonEmpty.first { $0 > slot.section }

        switch key {
        case .rightArrow:
            if slot.index + 1 < count { return CardSlot(section: slot.section, index: slot.index + 1) }
            return following.map { CardSlot(section: $0, index: 0) }
        case .leftArrow:
            if slot.index > 0 { return CardSlot(section: slot.section, index: slot.index - 1) }
            return previous.map { CardSlot(section: $0, index: sections[$0].items.count - 1) }
        case .downArrow:
            if slot.index + columns < count { return CardSlot(section: slot.section, index: slot.index + columns) }
            if (slot.index / columns) < ((count - 1) / columns) { return CardSlot(section: slot.section, index: count - 1) }
            return following.map { CardSlot(section: $0, index: min(column, sections[$0].items.count - 1)) }
        case .upArrow:
            if slot.index - columns >= 0 { return CardSlot(section: slot.section, index: slot.index - columns) }
            guard let previous else { return nil }
            let target = sections[previous]
            let targetColumns = max(1, target.columns)
            let lastRowStart = ((target.items.count - 1) / targetColumns) * targetColumns
            return CardSlot(section: previous, index: min(lastRowStart + column, target.items.count - 1))
        default:
            return nil
        }
    }
}

/// Encabezado grande de una página (título y subtítulo).
struct PageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Estado de carga, error o vacío de una página.
struct LoadStateView: View {
    enum State {
        case loading
        case failed(String)
    }

    let state: State
    var retry: (() -> Void)?

    var body: some View {
        switch state {
        case .loading:
            ProgressView("Cargando…")
                .frame(maxWidth: .infinity, minHeight: 300)
        case .failed(let message):
            ContentUnavailableView {
                Label("No se pudo cargar", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                if let retry { Button("Reintentar", action: retry) }
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }
}
