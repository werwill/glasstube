import Foundation
import Observation
import YTKit

/// Secciones fijas de la barra lateral (el `SidebarService` de SmartTube).
public enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home, subscriptions, history, playlists, shorts
    case music, gaming, news, live

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "Inicio"
        case .subscriptions: "Suscripciones"
        case .history: "Historial"
        case .playlists: "Playlists"
        case .shorts: "Shorts"
        case .music: "Música"
        case .gaming: "Gaming"
        case .news: "Noticias"
        case .live: "En vivo"
        }
    }

    public var symbol: String {
        switch self {
        case .home: "house"
        case .subscriptions: "play.rectangle.on.rectangle"
        case .history: "clock.arrow.circlepath"
        case .playlists: "list.and.film"
        case .shorts: "play.square.stack"
        case .music: "music.note"
        case .gaming: "gamecontroller"
        case .news: "newspaper"
        case .live: "dot.radiowaves.left.and.right"
        }
    }

    public var topic: Topic? {
        switch self {
        case .music: .music
        case .gaming: .gaming
        case .news: .news
        case .live: .live
        default: nil
        }
    }

    public static let library: [SidebarItem] = [.home, .subscriptions, .history, .playlists, .shorts]
    public static let explore: [SidebarItem] = [.music, .gaming, .news, .live]
}

/// Lo que muestra la columna de contenido.
public enum Destination: Hashable {
    case section(SidebarItem)
    /// Resultados de una búsqueda con sus filtros (fase 5a).
    case search(String, SearchFilter = .none)
    case channel(id: String, title: String?)
    case playlist(id: String, title: String?)
    /// "Ver todo" de una fila: la fila con su continuación.
    case group(MediaGroup)
    /// Feed de un grupo de canales (`ChannelGroup.id`).
    case channelGroup(String)

    public var sidebarItem: SidebarItem? {
        if case .section(let item) = self { return item }
        return nil
    }
}

/// Historial de navegación con atrás y adelante (NavigationStack no tiene "adelante").
@Observable
public final class Navigator {
    public private(set) var current: Destination = .section(.home)
    public private(set) var backStack: [Destination] = []
    public private(set) var forwardStack: [Destination] = []

    public init() {}

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public func go(_ destination: Destination) {
        guard destination != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = destination
    }

    /// Cambia el destino sin dejar el anterior en «Atrás» (otros filtros de la misma búsqueda).
    public func replace(_ destination: Destination) {
        guard destination != current else { return }
        current = destination
    }

    public func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
    }
}

/// Cómo se ve el reproductor abierto: en la ventana o en el minirreproductor flotante. En Windows no hay PiP del sistema
/// (en la Mac, los directos con AVPlayer usan el suyo): todo va por mpv.
public enum PlayerPresentation: Equatable {
    case full, mini
}

/// La lista desde la que se abrió un video (una playlist): el resto pasa a la cola.
public struct PlayContext {
    public var title: String?
    public var items: [MediaItem]

    public init(title: String?, items: [MediaItem]) {
        self.title = title
        self.items = items
    }
}

