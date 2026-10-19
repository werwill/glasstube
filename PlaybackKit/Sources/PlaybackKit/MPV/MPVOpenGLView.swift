import AppKit
import Libmpv
import OpenGL.GL3

// Respaldo OpenGL: API de render de libmpv (`vo=libmpv`) en un CAOpenGLLayer. Port de `MPVVideoLayer` de
// glasstube-spike, solo con el modo de retención `keep` (el que quedó por omisión en el spike).

private let openGLFramework = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL)

/// Capa que dibuja cuando mpv lo pide: el callback de actualización agenda `display()` en una cola serie propia;
/// ahí `canDraw` consulta `mpv_render_context_update` y, si hay cuadro nuevo, `draw` lo dibuja. (Con
/// `isAsynchronous = true`, que deja a Core Animation preguntar en cada refresco, mpv perdía cientos de cuadros a
/// 1080p60.) mpv dibuja en dos FBO propios que se alternan y `draw` copia el visible al de la capa; durante una
/// retención mpv sigue dibujando cada cuadro fuera de pantalla (la VO no espera) y la capa sigue mostrando el último
/// anterior a la carga.
final class MPVOpenGLLayer: CAOpenGLLayer, @unchecked Sendable {
    private struct Target {
        var fbo: GLuint = 0
        var texture: GLuint = 0
        var width: GLsizei = 0
        var height: GLsizei = 0
    }

    private let pixelFormat: CGLPixelFormatObj
    private let glContext: CGLContextObj
    private var renderContext: OpaquePointer?
    /// Protege `renderContext`, los FBO y la retención mientras se usan (canDraw/draw) frente a `stop`.
    private let renderLock = NSLock()
    /// Solo para `updatePending`: el callback de mpv puede llegar con candados internos de mpv tomados, así que nunca
    /// comparte candado con una llamada a la API de render.
    private let flagLock = NSLock()
    private var updatePending = false
    private var scheduled = false
    private let renderQueue = DispatchQueue(label: "glasstube.mpv.render", qos: .userInteractive)
    private var lastSize = CGSize.zero
    private var targets = [Target(), Target()]
    private var front = 0
    private var renderNext = false
    /// Retención: desde `beginHold` hasta que, pedido el fin, mpv dibujó un cuadro nuevo.
    private var holding = false
    private var releaseRequested = false
    private var framesSinceRelease = 0
    private var presentPending = false

    init(mpv: MPVHandle) throws {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFADoubleBuffer, kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, CGLPixelFormatAttribute(0),
        ]
        var format: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &format, &count)
        guard let format else { throw MPVError(description: "CGLChoosePixelFormat falló") }
        var context: CGLContextObj?
        CGLCreateContext(format, nil, &context)
        guard let context else { throw MPVError(description: "CGLCreateContext falló") }
        pixelFormat = format
        glContext = context
        super.init()

        CGLSetCurrentContext(context)
        var render: OpaquePointer?
        var initParams = mpv_opengl_init_params(get_proc_address: { _, name in
            guard let name else { return nil }
            return dlsym(openGLFramework, name)
        }, get_proc_address_ctx: nil)
        let api = strdup("opengl")
        defer { free(api) }
        let code = withUnsafeMutablePointer(to: &initParams) { initPointer -> Int32 in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPointer)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return mpv_render_context_create(&render, mpv.handle, &params)
        }
        CGLSetCurrentContext(nil)
        guard code >= 0, let render else { throw MPVError(description: "mpv_render_context_create: \(MPVHandle.errorString(code))") }
        renderContext = render
        mpv_render_context_set_update_callback(render, { ctx in
            Unmanaged<MPVOpenGLLayer>.fromOpaque(ctx!).takeUnretainedValue().markUpdate()
        }, Unmanaged.passUnretained(self).toOpaque())

        isAsynchronous = false
        isOpaque = true
        needsDisplayOnBoundsChange = true
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        backgroundColor = NSColor.black.cgColor
    }

    override init(layer: Any) {
        let other = layer as! MPVOpenGLLayer
        pixelFormat = other.pixelFormat
        glContext = other.glContext
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    /// Callback de mpv (cualquier hilo, quizá con candados de mpv tomados): solo marca y agenda.
    private func markUpdate() {
        let schedule = flagLock.withLock { () -> Bool in
            updatePending = true
            defer { scheduled = true }
            return !scheduled
        }
        if schedule { renderQueue.async { [weak self] in self?.renderPending() } }
    }

    private func renderPending() {
        flagLock.withLock { scheduled = false }
        display() // canDraw + draw en este hilo
        CATransaction.flush()
    }

    func beginHold() {
        renderLock.withLock {
            holding = true
            releaseRequested = false
            framesSinceRelease = 0
        }
        // Se suelta sola si nadie la termina.
        renderQueue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.endHold() }
    }

    func endHold() {
        let wasHolding = renderLock.withLock { () -> Bool in
            guard holding, !releaseRequested else { return false }
            releaseRequested = true
            presentPending = true
            return true
        }
        if wasHolding { renderQueue.async { [weak self] in self?.renderPending() } }
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        CGLRetainPixelFormat(pixelFormat)
        return pixelFormat
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        CGLRetainContext(glContext)
        return glContext
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let renderContext else { return false }
        let size = CGSize(width: bounds.width * contentsScale, height: bounds.height * contentsScale)
        var draw = size != lastSize || presentPending
        presentPending = false
        let pending = flagLock.withLock { () -> Bool in
            defer { updatePending = false }
            return updatePending
        }
        // render_context_update también atiende lo que la VO le encarga a este hilo: se llama siempre que mpv avisó.
        if pending, mpv_render_context_update(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
            renderNext = true
            draw = true
        }
        return draw
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        renderLock.lock()
        defer { renderLock.unlock() }
        var layerFBO: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &layerFBO)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        let width = viewport[2], height = viewport[3]
        guard let renderContext else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            return
        }
        lastSize = CGSize(width: bounds.width * contentsScale, height: bounds.height * contentsScale)
        let back = 1 - front
        let rendered = renderNext
        if renderNext {
            renderNext = false
            ensureTarget(back, width: width, height: height)
            var fbo = mpv_opengl_fbo(fbo: Int32(targets[back].fbo), w: width, h: height, internal_format: 0)
            var flip: Int32 = 1
            var block: Int32 = 1 // BLOCK_FOR_TARGET_TIME: espera la hora del cuadro en esta cola
            withUnsafeMutablePointer(to: &fbo) { fboPointer in
                withUnsafeMutablePointer(to: &flip) { flipPointer in
                    withUnsafeMutablePointer(to: &block) { blockPointer in
                        var params = [
                            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                            mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPointer)),
                            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                        ]
                        _ = mpv_render_context_render(renderContext, &params)
                    }
                }
            }
        }
        // Sin retención se ve lo que se acaba de dibujar; con ella, solo cuando ya se pidió el fin y hay un cuadro
        // dibujado después (el de T).
        var show = rendered
        if holding {
            if rendered && releaseRequested { framesSinceRelease += 1 }
            show = releaseRequested && framesSinceRelease > 0
            if show { holding = false }
        }
        if show { front = back }
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), GLuint(layerFBO))
        glViewport(0, 0, width, height)
        if targets[front].fbo != 0 {
            let source = targets[front]
            glDisable(GLenum(GL_SCISSOR_TEST))
            glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), source.fbo)
            glBlitFramebuffer(0, 0, source.width, source.height, 0, 0, width, height, GLbitfield(GL_COLOR_BUFFER_BIT),
                              GLenum(source.width == width && source.height == height ? GL_NEAREST : GL_LINEAR))
        } else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(layerFBO))
        glFlush()
        // También tras dibujar fuera de pantalla: si se llamó alguna vez, vo_libmpv espera cada swap (hasta 200 ms).
        if rendered { mpv_render_context_report_swap(renderContext) }
    }

    /// FBO con textura RGBA8 del tamaño de la capa (se rehace si cambia el tamaño).
    private func ensureTarget(_ index: Int, width: GLsizei, height: GLsizei) {
        var target = targets[index]
        if target.fbo == 0 {
            glGenFramebuffers(1, &target.fbo)
            glGenTextures(1, &target.texture)
        }
        if target.width != width || target.height != height {
            glBindTexture(GLenum(GL_TEXTURE_2D), target.texture)
            glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, width, height, 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), target.fbo)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), target.texture, 0)
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            target.width = width
            target.height = height
        }
        targets[index] = target
    }

    /// Libera el contexto de render (antes de destruir mpv).
    func stop() {
        CGLLockContext(glContext)
        renderLock.lock()
        if let renderContext {
            CGLSetCurrentContext(glContext)
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            for target in targets where target.fbo != 0 {
                var fbo = target.fbo, texture = target.texture
                glDeleteFramebuffers(1, &fbo)
                glDeleteTextures(1, &texture)
            }
            targets = [Target(), Target()]
            CGLSetCurrentContext(nil)
        }
        renderContext = nil
        renderLock.unlock()
        CGLUnlockContext(glContext)
    }
}

/// Vista que aloja la capa OpenGL. La capa (y su contexto de render) se crea en `attach`, después de
/// `mpv_initialize` y antes del primer `loadfile`: con `vo=libmpv`, la VO falla si al cargar no existe el contexto.
final class MPVOpenGLView: NSView, MPVVideoSurface {
    let renderer = MPVRenderer.openGL
    private var glLayer: MPVOpenGLLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    func mpvOptions() -> [(String, String)] { [("vo", "libmpv")] }

    func attach(to mpv: MPVHandle) throws {
        let glLayer = try MPVOpenGLLayer(mpv: mpv)
        glLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer = glLayer
        wantsLayer = true
        self.glLayer = glLayer
    }

    func detach() { glLayer?.stop() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glLayer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    func beginHold(mpv: MPVHandle) async { glLayer?.beginHold() }
    func endHold() { glLayer?.endHold() }
}
