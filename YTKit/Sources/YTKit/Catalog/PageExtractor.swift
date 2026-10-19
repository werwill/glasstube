import Foundation

/// Raíz de una respuesta de `/browse`, `/search` o `/next` (primera página o continuación). Las cuatro formas de traer
/// contenido que usa YouTube: `contents` (primera página), `continuationContents` (continuación de TV) y
/// `onResponseReceivedActions` / `Commands` / `Endpoints` (continuación de WEB).
struct InnertubeResponse: Decodable, Sendable {
    struct ResponseContext: Decodable, Sendable { @Lenient var visitorData: String? }

    @Lenient var contents: Node?
    @Lenient var continuationContents: Node?
    @Lenient var onResponseReceivedActions: [Node]?
    @Lenient var onResponseReceivedCommands: [Node]?
    @Lenient var onResponseReceivedEndpoints: [Node]?
    @Lenient var header: Node?
    @Lenient var responseContext: ResponseContext?

    var roots: [Node] {
        [contents, continuationContents].compactMap { $0 }
            + (onResponseReceivedActions ?? []) + (onResponseReceivedCommands ?? []) + (onResponseReceivedEndpoints ?? [])
    }
}

/// Recorre el árbol de nodos y lo convierte en filas (`MediaGroup`). Equivale a los `getShelves`, `getItems` y
/// `getContinuationToken` repartidos por los helpers de SmartTube, pero sin una ruta fija por pantalla:
///
/// - Un contenedor "de fila" (`shelfRenderer`, `richShelfRenderer`, `reelShelfRenderer`, `gridShelfViewModel`, o un
///   `itemSectionRenderer` con título) es una fila: todo lo que tiene dentro se aplana en ella y su token de
///   continuación es el de la fila.
/// - Los demás contenedores (`sectionListRenderer`, `richGridRenderer`, `tabRenderer`, `tvSurfaceContentRenderer`…)
///   son transparentes: sus elementos sueltos forman una fila sin título (la cuadrícula) y sus filas suben tal cual.
/// - Un token suelto es de la cuadrícula si hay elementos sueltos (más elementos) y de la página si no (más filas).
struct PageExtractor {
    let surface: Surface
    let api: Continuation.API
    let kind: MediaGroup.Kind

    static let rowContainers: Set<String> = ["shelfRenderer", "richShelfRenderer", "reelShelfRenderer", "gridShelfViewModel"]

    struct Result {
        var groups: [MediaGroup] = []
        var loose: [MediaItem] = []
        var looseToken: String?
        var notices: [String] = []
        var stats = ParseStats()
    }

    func extract(_ roots: [Node]) -> Result {
        var result = Result()
        for root in roots { visit(root, into: &result) }
        return result
    }

    /// Página completa: la cuadrícula suelta (si hay) va primero, con el título que se le dé, y luego las filas.
    func page(_ roots: [Node], looseTitle: String? = nil) -> BrowsePage {
        let result = extract(roots)
        var groups = result.groups
        var pageToken: String?
        if !result.loose.isEmpty {
            let grid = MediaGroup(kind: kind, title: looseTitle, items: result.loose,
                                  continuation: continuation(result.looseToken), renderer: "grid")
            groups.insert(grid, at: 0)
        } else {
            pageToken = result.looseToken
        }
        var page = BrowsePage(groups: groups, continuation: continuation(pageToken), surface: surface,
                              notice: result.notices.first)
        page.stats = result.stats
        return page
    }

    func continuation(_ token: String?) -> Continuation? {
        token.map { Continuation(token: $0, api: api, surface: surface) }
    }

    private func visit(_ node: Node, into result: inout Result) {
        switch node.value {
        case .item(let renderer):
            if Convert.isNavigationShortcut(renderer) {
                result.stats.ignored[node.key + " (atajo)", default: 0] += 1
            } else if let item = Convert.item(renderer, key: node.key) {
                result.loose.append(item)
            } else {
                result.stats.dropped[node.key, default: 0] += 1
            }
        case .continuation(let renderer):
            if result.looseToken == nil { result.looseToken = renderer.token }
        case .notice(let text):
            result.notices.append(text)
        case .ignored:
            result.stats.ignored[node.key, default: 0] += 1
        case .failed:
            result.stats.failed[node.key, default: 0] += 1
        case .container(let container):
            if isRow(node.key, container) {
                var inner = Result()
                for child in container.children { visit(child, into: &inner) }
                result.stats.merge(inner.stats)
                result.notices += inner.notices
                let items = inner.loose + inner.groups.flatMap(\.items)
                guard !items.isEmpty else { return }
                let token = container.continuationToken ?? inner.looseToken
                let more = container.endpoint?.browseEndpoint.flatMap { endpoint in
                    endpoint.browseId.map { BrowseTarget(browseId: $0, params: endpoint.params) }
                }
                result.groups.append(MediaGroup(kind: kind, title: container.resolvedTitle, items: items,
                                                continuation: continuation(token), moreEndpoint: more,
                                                renderer: node.key))
            } else {
                for child in container.children { visit(child, into: &result) }
                if result.looseToken == nil { result.looseToken = container.continuationToken }
            }
        }
    }

    private func isRow(_ key: String, _ container: Container) -> Bool {
        if Self.rowContainers.contains(key) { return true }
        if key == "itemSectionRenderer", container.resolvedTitle != nil { return true }
        return false
    }
}
