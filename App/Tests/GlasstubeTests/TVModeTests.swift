import Foundation
import Testing
import YTKit
@testable import Glasstube

/// Fase 5b: la navegación del modo TV con flechas, Retorno y Esc (sin red ni ventana) y los controles de juego.
@MainActor
@Suite struct TVModeTests {
    static func video(_ id: String, short: Bool = false) -> MediaItem {
        var item = MediaItem(kind: .video, title: "Video \(id)", renderer: "prueba")
        item.videoId = id
        item.isShort = short
        return item
    }

    static func row(_ title: String, _ ids: [String]) -> TVRow {
        TVRow(id: title, title: title, group: MediaGroup(kind: .home, title: title, items: ids.map { video($0) }, renderer: "prueba"))
    }

    static var page: TVPage {
        TVPage(title: "Inicio", rows: [row("Uno", ["a", "b", "c"]), row("Dos", ["d", "e"])], state: .loaded)
    }

    @Test func sectionsFollowTheSidebarAndTheGroups() {
        let sections = TVMode.sections(groups: [ChannelGroup(id: "g1", title: "Blender", channels: [])])
        #expect(sections.first == .item(.home))
        #expect(sections.contains(.item(.shorts)) && sections.contains(.item(.music)))
        #expect(sections.last == .group("g1"))
        #expect(!sections.contains(.item(.playlists))) // Playlists pide cuenta y abre una lista de listas: no va en la tele
    }

    @Test func arrowsMoveAlongRowsAndEachRowRemembersItsCard() {
        let tv = TVMode(app: nil)
        tv.setPagesForTesting([Self.page])
        #expect(tv.focusedItem?.videoId == "a")
        tv.handle(.right)
        tv.handle(.right)
        #expect(tv.focusedItem?.videoId == "c")
        #expect(!tv.handle(.right)) // fin de la fila: la tecla no hace nada
        tv.handle(.down)
        #expect(tv.focusedItem?.videoId == "d") // la fila de abajo empieza en su propia tarjeta
        tv.handle(.right)
        tv.handle(.up)
        #expect(tv.focusedItem?.videoId == "c") // la de arriba sigue donde estaba
        #expect(!tv.handle(.up))
        tv.handle(.down)
        #expect(tv.focusedItem?.videoId == "e")
    }

    @Test func leftOnTheFirstCardAndEscapeGoToTheMenu() {
        let tv = TVMode(app: nil)
        tv.setPagesForTesting([Self.page])
        tv.handle(.left)
        #expect(tv.focus == .menu && tv.focusedItem == nil)
        tv.handle(.right)
        #expect(tv.focus == .content && tv.focusedItem?.videoId == "a")
        tv.handle(.back)
        #expect(tv.focus == .menu)
        tv.handle(.enter)
        #expect(tv.focus == .content)
    }

    @Test func escapeClosesAnOpenedChannelFirst() {
        let tv = TVMode(app: nil)
        let channel = TVPage(title: "Blender", rows: [Self.row("Videos", ["x", "y"])], state: .loaded)
        tv.setPagesForTesting([Self.page, channel])
        #expect(tv.focusedItem?.videoId == "x")
        // En un canal abierto no hay menú al lado: ← en la primera tarjeta no hace nada.
        #expect(!tv.handle(.left))
        tv.handle(.back)
        #expect(tv.pages.count == 1 && tv.focus == .content && tv.focusedItem?.videoId == "a")
    }

    @Test func theMenuMovesBetweenSectionsAndAnEmptyPageKeepsTheFocusThere() {
        let tv = TVMode(app: nil)
        tv.setPagesForTesting([TVPage(title: "Inicio", state: .empty("Nada"))], focus: .menu)
        #expect(!tv.handle(.right)) // sin filas no hay adónde ir
        #expect(!tv.handle(.up)) // ya es la primera
        tv.handle(.down)
        #expect(tv.selected == 1 && tv.section == .item(.subscriptions))
        #expect(tv.page?.state == .loading) // la sección nueva se pide
    }

    @Test func clickingACardFocusesIt() {
        let tv = TVMode(app: nil)
        tv.setPagesForTesting([Self.page], focus: .menu)
        tv.click(row: 1, column: 1)
        #expect(tv.focus == .content && tv.focusedItem?.videoId == "e")
    }

    @Test func hiddenAndBlockedItemsAndEmptyRowsAreLeftOut() {
        let groups = [MediaGroup(kind: .home, title: nil, items: [Self.video("a"), Self.video("b")], renderer: "prueba"),
                      MediaGroup(kind: .home, title: "Vacía", items: [Self.video("c")], renderer: "prueba")]
        let rows = TVMode.rows({ $0.filter { $0.videoId != "b" && $0.videoId != "c" } }, groups)
        #expect(rows.map(\.title) == ["Destacado"])
        #expect(rows.first?.items.map(\.videoId) == ["a"])
    }

    @Test func gameControllerSticksAndButtons() {
        #expect(TVGameControllers.arrow(x: 0, y: 0) == nil)
        #expect(TVGameControllers.arrow(x: 0.3, y: -0.2) == nil) // dentro de la zona muerta
        #expect(TVGameControllers.arrow(x: 0.9, y: 0.2) == "right")
        #expect(TVGameControllers.arrow(x: -0.7, y: 0.6) == "left")
        #expect(TVGameControllers.arrow(x: 0.1, y: 1) == "up")
        #expect(TVGameControllers.arrow(x: -0.5, y: -0.8) == "down")
        #expect(TVGameControllers.buttons["a"] == "return" && TVGameControllers.buttons["b"] == "escape")
        #expect(TVGameControllers.buttons["menu"] == "escape" && TVGameControllers.buttons["x"] == "space")
    }
}
