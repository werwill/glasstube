import AppKit
import SwiftUI

/// «Reducir movimiento» (Ajustes del Sistema › Accesibilidad › Pantalla; fase 5b). Como recomienda Apple, con el ajuste
/// nada se desliza, crece ni se desplaza solo (la lista que sigue al foco salta en lugar de deslizarse, las tarjetas no
/// se elevan); los fundidos se quedan. `-GTReducirMovimiento YES` lo simula sin tocar el ajuste del sistema (pruebas).
enum Motion {
    static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey: "GTReducirMovimiento")
    }

    /// La animación, o ninguna con «Reducir movimiento».
    static func animation(_ animation: Animation) -> Animation? { isReduced ? nil : animation }
}

extension AnyTransition {
    /// Una transición con desplazamiento o zoom que con «Reducir movimiento» es solo un fundido.
    static func moving(_ transition: AnyTransition) -> AnyTransition { Motion.isReduced ? .opacity : transition }
}
