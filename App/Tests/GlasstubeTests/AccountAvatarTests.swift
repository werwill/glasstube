import AppKit
import Testing
@testable import Glasstube

/// El avatar del menú de cuenta tiene el tamaño en puntos que se pide (la toolbar usa el tamaño de la imagen).
@MainActor
@Suite struct AccountAvatarTests {
    @Test func circularAvatarHasTheRequestedSize() {
        // Como la foto de YouTube: 176 px, más grande que el lugar en la toolbar.
        let photo = NSImage(size: NSSize(width: 176, height: 176))
        let avatar = AccountAvatar.circular(photo, points: 22)
        #expect(avatar.size == NSSize(width: 22, height: 22))
        // Una foto que no es cuadrada tampoco cambia el tamaño.
        #expect(AccountAvatar.circular(NSImage(size: NSSize(width: 300, height: 120)), points: 32).size == NSSize(width: 32, height: 32))
    }
}
