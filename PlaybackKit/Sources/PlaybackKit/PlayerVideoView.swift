import AppKit
import SwiftUI

/// La superficie de video de un motor dentro de SwiftUI. El motor conserva la vista: se puede quitar y volver a
/// poner (p. ej. al cambiar de pantalla, o pasar de la ventana a un minirreproductor) sin interrumpir la reproducción.
///
/// Una vista de AppKit solo puede estar en un lugar. Si hay dos `PlayerVideoView` del mismo motor a la vez (la
/// ventana y el minirreproductor mientras uno aparece y el otro se va), solo la que tiene `isActive` la toma; sin eso,
/// la que se está yendo se la quitaba a la nueva en su última actualización y el video quedaba en negro.
public struct PlayerVideoView: NSViewRepresentable {
    let engine: any PlayerEngine
    let isActive: Bool

    public init(engine: any PlayerEngine, isActive: Bool = true) {
        self.engine = engine
        self.isActive = isActive
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        if isActive { attach(engine.videoView, to: container) }
        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        if isActive, engine.videoView.superview !== container { attach(engine.videoView, to: container) }
    }

    private func attach(_ video: NSView, to container: NSView) {
        video.removeFromSuperview()
        video.frame = container.bounds
        video.autoresizingMask = [.width, .height]
        container.addSubview(video)
    }
}
