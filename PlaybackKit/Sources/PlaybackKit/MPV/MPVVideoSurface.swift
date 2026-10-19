import AppKit
import Libmpv
import QuartzCore

/// Cómo dibuja mpv el video.
public enum MPVRenderer: String, Sendable, CaseIterable {
    /// `vo=gpu-next` con Vulkan sobre MoltenVK en un `CAMetalLayer` (`gpu-context=moltenvk`, `wid` = la capa). Es Metal
    /// de punta a punta y es lo predeterminado. La API de render de libmpv solo ofrece OpenGL y software, así que para
    /// Metal mpv dibuja directamente en la capa.
    case metal
    /// Respaldo: `vo=libmpv` con la API de render de OpenGL en un `CAOpenGLLayer` (como IINA y la prueba de la fase 0).
    /// OpenGL está obsoleto en macOS, pero funciona y da control cuadro a cuadro.
    case openGL
}

/// Una superficie donde mpv dibuja. Además sabe «retener» la imagen: entre una carga nueva (búsqueda fuera de lo
/// descargado o cambio de calidad) y el momento en que mpv llega a la posición pedida, sigue mostrando el último cuadro
/// anterior a la carga en lugar del principio del segmento (hasta 6,8 s antes; ver RESULTADOS.md del spike, (e)).
@MainActor
protocol MPVVideoSurface: NSView {
    var renderer: MPVRenderer { get }
    /// Opciones de mpv que la superficie necesita, antes de `mpv_initialize`.
    func mpvOptions() -> [(String, String)]
    /// Después de `mpv_initialize` y antes del primer `loadfile`.
    func attach(to mpv: MPVHandle) throws
    /// Antes de destruir mpv.
    func detach()
    /// Desde ahora se ve el cuadro actual hasta `endHold`. Se llama antes del `loadfile`, con mpv todavía mostrando el
    /// archivo anterior.
    func beginHold(mpv: MPVHandle) async
    /// mpv ya está en la posición pedida: se vuelve a ver lo que dibuja.
    func endHold()
}

// MARK: - Metal (Vulkan sobre MoltenVK)

/// Vista con un `CAMetalLayer` propio. mpv crea su swapchain de Vulkan sobre esa capa (el parche `moltenvk` de MPVKit:
/// `wid` es el puntero a la capa) y presenta desde su hilo de VO. La vista solo mantiene `drawableSize` al día; mpv lo
/// lee al reconfigurar y MoltenVK marca la swapchain como subóptima cuando cambia, y libplacebo la recrea.
///
/// Retención: mpv presenta directo en la capa, así que no hay un FBO propio que congelar como en OpenGL. Antes de la
/// carga se pide a mpv el cuadro actual (`screenshot-raw video`, que con gpu-next lo dibuja la VO, también con
/// VideoToolbox) y se muestra en una subcapa encima hasta que mpv llega a T.
final class MPVMetalView: NSView, MPVVideoSurface {
    let renderer = MPVRenderer.metal
    let metalLayer = CAMetalLayer()
    private let holdLayer = CALayer()
    /// Tamaño del último cuadro retenido (diagnóstico).
    private(set) var holdImageSize: CGSize?
    /// Cambió el tamaño de la capa (píxeles). mpv no se entera solo: ver `MPVEngine.syncOutputSize`.
    var onDrawableSizeChange: ((CGSize) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.isOpaque = true
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        holdLayer.contentsGravity = .resizeAspect
        holdLayer.backgroundColor = NSColor.black.cgColor
        holdLayer.isHidden = true
        holdLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        metalLayer.addSublayer(holdLayer)
        layer = metalLayer // vista que aloja la capa (layer-hosting)
        wantsLayer = true
        updateDrawableSize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    func mpvOptions() -> [(String, String)] {
        let wid = Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque())
        return [("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"), ("wid", String(wid))]
    }

    func attach(to mpv: MPVHandle) throws {}
    func detach() {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        holdLayer.frame = metalLayer.bounds
        holdLayer.contentsScale = scale
        CATransaction.commit()
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            onDrawableSizeChange?(size)
        }
    }

    func beginHold(mpv: MPVHandle) async {
        let image = try? await mpv.run { mpv -> CGImage? in
            Self.image(from: try mpv.commandNode(["screenshot-raw", "video", "bgra"]))
        }
        guard let image else { return } // sin cuadro (p. ej. aún no hay video): se ve lo que dibuje mpv
        holdImageSize = CGSize(width: image.width, height: image.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holdLayer.frame = metalLayer.bounds
        holdLayer.contents = image
        holdLayer.isHidden = false
        CATransaction.commit()
    }

    func endHold() {
        guard !holdLayer.isHidden else { return }
        // mpv ya presentó (o está por presentar) el cuadro de T: se quita la imagen en el siguiente refresco.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [holdLayer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            holdLayer.isHidden = true
            holdLayer.contents = nil
            CATransaction.commit()
        }
    }

    /// Resultado de `screenshot-raw` (w, h, stride, format, data) → CGImage.
    nonisolated static func image(from node: MPVNode) -> CGImage? {
        guard let width = node["w"]?.int, let height = node["h"]?.int, let stride = node["stride"]?.int,
              case .bytes(let data)? = node["data"], width > 0, height > 0 else { return nil }
        let format = node["format"]?.string ?? "bgr0"
        let alpha: CGImageAlphaInfo = format == "bgra" ? .premultipliedFirst : .noneSkipFirst
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(stride),
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
