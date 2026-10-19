import AppKit
import AVFoundation
import AVKit

/// Picture in Picture del sistema para `AVEngine` (directos por HLS). Solo existe con AVPlayer: el PiP de macOS
/// (`AVPictureInPictureController`) necesita un `AVPlayerLayer`; con mpv el equivalente es una ventana flotante propia
/// (lo hace la app).
@MainActor
public final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    /// macOS no da PiP en todos los equipos (p. ej. en una máquina virtual).
    public static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    public private(set) var isActive = false
    /// El usuario volvió de la ventana del sistema a la app (botón de restaurar): la app debe mostrar su reproductor.
    public var onRestore: (() -> Void)?
    /// Terminó el PiP (por restaurar o por cerrarlo).
    public var onStop: (() -> Void)?

    private let controller: AVPictureInPictureController
    private var possibleObservation: NSKeyValueObservation?
    private var pending = false

    init?(playerLayer: AVPlayerLayer) {
        guard Self.isSupported, let controller = AVPictureInPictureController(playerLayer: playerLayer) else { return nil }
        self.controller = controller
        super.init()
        controller.delegate = self
        // Al crearlo, `isPictureInPicturePossible` tarda un momento en ser verdadero: si se pidió antes, se arranca entonces.
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, possible, self.pending else { return }
                    self.pending = false
                    self.controller.startPictureInPicture()
                }
            }
        }
    }

    public func start() {
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            pending = true
        }
    }

    public func stop() {
        pending = false
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
    }

    // MARK: - AVPictureInPictureControllerDelegate

    nonisolated public func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { isActive = true }
    }

    nonisolated public func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            isActive = false
            onStop?()
        }
    }

    nonisolated public func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                       failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated {
            isActive = false
            onStop?()
        }
    }

    nonisolated public func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                       restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { onRestore?() }
        completionHandler(true)
    }
}

extension AVEngine {
    /// El PiP del sistema sobre la capa de este motor (nil si macOS no lo admite). Uno por motor.
    public func makePictureInPicture() -> PictureInPicture? {
        PictureInPicture(playerLayer: playerLayer)
    }
}
