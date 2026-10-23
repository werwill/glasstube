import AppKit
import Testing
@testable import Glasstube

/// Al soltar el minirreproductor, queda pegado al borde más cercano de la pantalla en el punto donde se dejó.
@Suite struct MiniPlayerSnapTests {
    /// Pantalla útil de 1728×1000 ya con el margen.
    let bounds = NSRect(x: 20, y: 115, width: 1688, height: 960)
    let size = NSSize(width: 448, height: 252)

    @Test func sticksToTheNearestSideKeepingItsHeight() {
        let left = MiniPanel.snapped(NSRect(origin: NSPoint(x: 150, y: 500), size: size), in: bounds)
        #expect(left.origin == NSPoint(x: 20, y: 500))
        let right = MiniPanel.snapped(NSRect(origin: NSPoint(x: 1150, y: 400), size: size), in: bounds)
        #expect(right.origin == NSPoint(x: bounds.maxX - size.width, y: 400))
    }

    @Test func sticksToTopOrBottomKeepingItsPosition() {
        let top = MiniPanel.snapped(NSRect(origin: NSPoint(x: 640, y: 780), size: size), in: bounds)
        #expect(top.origin == NSPoint(x: 640, y: bounds.maxY - size.height))
        let bottom = MiniPanel.snapped(NSRect(origin: NSPoint(x: 700, y: 160), size: size), in: bounds)
        #expect(bottom.origin == NSPoint(x: 700, y: 115))
    }

    @Test func nearACornerSticksToBothEdges() {
        let corner = MiniPanel.snapped(NSRect(origin: NSPoint(x: 60, y: 170), size: size), in: bounds)
        #expect(corner.origin == NSPoint(x: 20, y: 115))
    }

    @Test func comesBackInsideWhenDroppedOffScreen() {
        let off = MiniPanel.snapped(NSRect(origin: NSPoint(x: 1600, y: -90), size: size), in: bounds)
        #expect(off.origin == NSPoint(x: bounds.maxX - size.width, y: 115))
        #expect(off.size == size)
    }
}
