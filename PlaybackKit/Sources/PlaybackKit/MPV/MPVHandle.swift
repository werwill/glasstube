import Foundation
import Libmpv

// Envoltura mínima de la API cliente de libmpv (client.h y stream_cb.h): opciones, propiedades, comandos, el hilo
// de eventos y los flujos `glasstube://`. De `MPV.swift` de glasstube-spike, ahora con las cabeceras reales de la
// libmpv propia (Vendor/Libmpv.xcframework) en lugar de declaraciones a mano y dlopen.

struct MPVError: Error, CustomStringConvertible {
    let description: String
}

/// Valor de una propiedad o del resultado de un comando (`mpv_node`).
indirect enum MPVNode: CustomStringConvertible, Sendable {
    case none
    case string(String)
    case flag(Bool)
    case int(Int64)
    case double(Double)
    case array([MPVNode])
    case map([String: MPVNode])
    case bytes(Data)

    var double: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    var int: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        default: return nil
        }
    }

    var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var flag: Bool? {
        if case .flag(let v) = self { return v }
        return nil
    }

    var array: [MPVNode]? {
        if case .array(let v) = self { return v }
        return nil
    }

    subscript(key: String) -> MPVNode? {
        if case .map(let m) = self { return m[key] }
        return nil
    }

    var description: String {
        switch self {
        case .none: return "-"
        case .string(let v): return v
        case .flag(let v): return v ? "yes" : "no"
        case .int(let v): return String(v)
        case .double(let v): return String(format: "%.3f", v)
        case .array(let v): return "[" + v.map(\.description).joined(separator: ", ") + "]"
        case .map(let m): return "{" + m.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ") + "}"
        case .bytes(let d): return "<\(d.count) B>"
        }
    }

    /// Copia un `mpv_node` (y sus hijos) a valores de Swift.
    static func from(_ node: mpv_node) -> MPVNode {
        switch node.format {
        case MPV_FORMAT_STRING, MPV_FORMAT_OSD_STRING:
            return node.u.string.map { .string(String(cString: $0)) } ?? .none
        case MPV_FORMAT_FLAG:
            return .flag(node.u.flag != 0)
        case MPV_FORMAT_INT64:
            return .int(node.u.int64)
        case MPV_FORMAT_DOUBLE:
            return .double(node.u.double_)
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list?.pointee, let values = list.values else { return .array([]) }
            return .array((0..<Int(list.num)).map { from(values[$0]) })
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee, let values = list.values, let keys = list.keys else { return .map([:]) }
            var map: [String: MPVNode] = [:]
            for i in 0..<Int(list.num) {
                if let key = keys[i] { map[String(cString: key)] = from(values[i]) }
            }
            return .map(map)
        case MPV_FORMAT_BYTE_ARRAY:
            guard let ba = node.u.ba?.pointee, let data = ba.data else { return .bytes(Data()) }
            return .bytes(Data(bytes: data, count: Int(ba.size)))
        default:
            return .none
        }
    }

    /// Valor de un evento de propiedad.
    static func from(format: mpv_format, data: UnsafeMutableRawPointer?) -> MPVNode {
        guard let data else { return .none }
        switch format {
        case MPV_FORMAT_FLAG: return .flag(data.load(as: Int32.self) != 0)
        case MPV_FORMAT_INT64: return .int(data.load(as: Int64.self))
        case MPV_FORMAT_DOUBLE: return .double(data.load(as: Double.self))
        case MPV_FORMAT_STRING, MPV_FORMAT_OSD_STRING:
            return data.load(as: UnsafePointer<CChar>?.self).map { .string(String(cString: $0)) } ?? .none
        case MPV_FORMAT_NODE: return from(data.load(as: mpv_node.self))
        default: return .none
        }
    }
}

enum MPVEvent: Sendable {
    case property(String, MPVNode)
    case log(prefix: String, level: String, text: String)
    case startFile, fileLoaded, playbackRestart, seek, videoReconfig, audioReconfig
    case endFile(reason: mpv_end_file_reason, error: Int32)
    case shutdown
}

final class MPVHandle: @unchecked Sendable {
    static func errorString(_ code: Int32) -> String { String(cString: mpv_error_string(code)) }

    let handle: OpaquePointer
    /// Las llamadas síncronas a mpv van aquí: nunca en el hilo principal (render.h prohíbe llamar a funciones que
    /// esperan al núcleo desde el hilo que dibuja, y el núcleo puede tardar).
    let control = DispatchQueue(label: "glasstube.mpv.control", qos: .userInitiated)
    private let shutdownSignal = DispatchSemaphore(value: 0)
    /// Solo se lee y escribe en `control`: después de `mpv_terminate_destroy` ninguna llamada llega a mpv.
    private var destroyed = false
    private var eventLoopStarted = false

    init() throws {
        guard let handle = mpv_create() else { throw MPVError(description: "mpv_create falló") }
        self.handle = handle
    }

    private func check(_ code: Int32, _ what: @autoclosure () -> String) throws {
        guard code >= 0 else { throw MPVError(description: "\(what()): \(Self.errorString(code))") }
    }

    func setOption(_ name: String, _ value: String) throws {
        try check(mpv_set_option_string(handle, name, value), "opción \(name)=\(value)")
    }

    func initialize() throws { try check(mpv_initialize(handle), "mpv_initialize") }

    func setProperty(_ name: String, _ value: String) throws {
        try check(mpv_set_property_string(handle, name, value), "propiedad \(name)=\(value)")
    }

    /// Sin esperar el resultado (desde el actor principal).
    func setPropertyAsync(_ name: String, _ value: String) {
        control.async { [self] in
            guard !destroyed else { return }
            var cValue: UnsafeMutablePointer<CChar>? = strdup(value)
            defer { free(cValue) }
            _ = mpv_set_property_async(handle, 0, name, MPV_FORMAT_STRING, &cValue)
        }
    }

    /// Lista de cadenas como `MPV_FORMAT_NODE_ARRAY`. `audio-files` como cadena es una lista de rutas separada por
    /// ':' y partiría `glasstube://…` en dos.
    func setStringList(_ name: String, _ values: [String]) throws {
        let owned = values.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var nodes = owned.map { string -> mpv_node in
            var node = mpv_node()
            node.format = MPV_FORMAT_STRING
            node.u.string = string
            return node
        }
        let code = nodes.withUnsafeMutableBufferPointer { buffer -> Int32 in
            var list = mpv_node_list(num: Int32(values.count), values: buffer.baseAddress, keys: nil)
            return withUnsafeMutablePointer(to: &list) { listPointer -> Int32 in
                var node = mpv_node()
                node.format = MPV_FORMAT_NODE_ARRAY
                node.u.list = listPointer
                return mpv_set_property(handle, name, MPV_FORMAT_NODE, &node)
            }
        }
        try check(code, "propiedad \(name)=\(values)")
    }

    func string(_ name: String) -> String? {
        guard let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    func node(_ name: String) -> MPVNode? {
        var node = mpv_node()
        guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &node) >= 0 else { return nil }
        defer { mpv_free_node_contents(&node) }
        return MPVNode.from(node)
    }

    func double(_ name: String) -> Double? {
        var value = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    func command(_ args: [String]) throws {
        try check(Self.withCStrings(args) { mpv_command(handle, $0) }, args.joined(separator: " "))
    }

    func commandAsync(_ args: [String]) {
        control.async { [self] in
            guard !destroyed else { return }
            _ = Self.withCStrings(args) { mpv_command_async(handle, 0, $0) }
        }
    }

    /// Comando con resultado (p. ej. `screenshot-raw`).
    func commandNode(_ args: [String]) throws -> MPVNode {
        let owned = args.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var nodes = owned.map { string -> mpv_node in
            var node = mpv_node()
            node.format = MPV_FORMAT_STRING
            node.u.string = string
            return node
        }
        var result = mpv_node()
        let code = nodes.withUnsafeMutableBufferPointer { buffer -> Int32 in
            var list = mpv_node_list(num: Int32(args.count), values: buffer.baseAddress, keys: nil)
            return withUnsafeMutablePointer(to: &list) { listPointer -> Int32 in
                var node = mpv_node()
                node.format = MPV_FORMAT_NODE_ARRAY
                node.u.list = listPointer
                return mpv_command_node(handle, &node, &result)
            }
        }
        try check(code, args.joined(separator: " "))
        defer { mpv_free_node_contents(&result) }
        return MPVNode.from(result)
    }

    func observe(_ name: String, _ format: mpv_format) {
        _ = mpv_observe_property(handle, 0, name, format)
    }

    func requestLog(_ level: String) { _ = mpv_request_log_messages(handle, level) }

    /// Corre `body` en la cola de control y espera el resultado sin bloquear al llamador.
    func run<T: Sendable>(_ body: @escaping @Sendable (MPVHandle) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            control.async { [self] in
                guard !destroyed else { return continuation.resume(throwing: MPVError(description: "mpv ya se cerró")) }
                continuation.resume(with: Result { try body(self) })
            }
        }
    }

    /// `const char **` terminado en NULL.
    static func withCStrings<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let owned = strings.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } } + [nil]
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    // MARK: - Eventos

    /// Hilo propio que espera eventos (`mpv_wait_event`) y los pasa a `handler`, hasta MPV_EVENT_SHUTDOWN.
    func startEventLoop(_ handler: @escaping @Sendable (MPVEvent) -> Void) {
        eventLoopStarted = true
        let thread = Thread { [handle, shutdownSignal] in
            loop: while true {
                guard let event = mpv_wait_event(handle, -1)?.pointee else { continue }
                switch event.event_id {
                case MPV_EVENT_NONE:
                    continue
                case MPV_EVENT_SHUTDOWN:
                    handler(.shutdown)
                    break loop
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee else { continue }
                    handler(.property(String(cString: property.name), MPVNode.from(format: property.format, data: property.data)))
                case MPV_EVENT_LOG_MESSAGE:
                    guard let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee else { continue }
                    handler(.log(prefix: String(cString: message.prefix), level: String(cString: message.level),
                                 text: String(cString: message.text).trimmingCharacters(in: .newlines)))
                case MPV_EVENT_START_FILE: handler(.startFile)
                case MPV_EVENT_FILE_LOADED: handler(.fileLoaded)
                case MPV_EVENT_PLAYBACK_RESTART: handler(.playbackRestart)
                case MPV_EVENT_SEEK: handler(.seek)
                case MPV_EVENT_VIDEO_RECONFIG: handler(.videoReconfig)
                case MPV_EVENT_AUDIO_RECONFIG: handler(.audioReconfig)
                case MPV_EVENT_END_FILE:
                    guard let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { continue }
                    handler(.endFile(reason: end.reason, error: end.error))
                default:
                    continue
                }
            }
            shutdownSignal.signal()
        }
        thread.name = "glasstube.mpv.events"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// "quit", espera MPV_EVENT_SHUTDOWN (y que termine el hilo de eventos) y destruye el handle, todo en la cola de
    /// control: lo que se encole después ya no llega a mpv. El contexto de render, si hay, debe liberarse antes.
    func shutdown(timeout: TimeInterval = 5) {
        control.sync { [self] in
            guard !destroyed else { return }
            destroyed = true
            _ = Self.withCStrings(["quit"]) { mpv_command_async(handle, 0, $0) }
            if eventLoopStarted, shutdownSignal.wait(timeout: .now() + timeout) == .timedOut {
                NSLog("PlaybackKit: mpv no respondió a quit en %d s", Int(timeout))
            }
            mpv_terminate_destroy(handle)
        }
    }

    // MARK: - Flujos glasstube://

    /// Registra el protocolo con `mpv_stream_cb_add_ro`. `open_fn` busca el búfer de la URI en `registry`; los flujos
    /// no tienen `seek_fn` ni `size_fn` (no buscables) y `cancel_fn` despierta a un `read_fn` bloqueado.
    func addStreamProtocol(_ name: String, registry: MPVStreamRegistry) throws {
        let userData = Unmanaged.passRetained(registry).toOpaque() // se suelta en `deinit` del registro: ver abajo
        registry.retainedByMPV = userData
        let open: mpv_stream_cb_open_ro_fn = { userData, uri, info in
            let registry = Unmanaged<MPVStreamRegistry>.fromOpaque(userData!).takeUnretainedValue()
            guard let uri, let info, let buffer = registry.open(String(cString: uri)) else { return MPV_ERROR_LOADING_FAILED.rawValue }
            info.pointee.cookie = Unmanaged.passRetained(buffer).toOpaque()
            info.pointee.read_fn = { cookie, buf, count in
                Unmanaged<StreamBuffer>.fromOpaque(cookie!).takeUnretainedValue().read(into: UnsafeMutableRawPointer(buf!), capacity: Int(count))
            }
            info.pointee.seek_fn = nil
            info.pointee.size_fn = nil
            info.pointee.close_fn = { cookie in
                let buffer = Unmanaged<StreamBuffer>.fromOpaque(cookie!)
                buffer.takeUnretainedValue().cancel()
                MPVStreamRegistry.retire(buffer) // no se suelta aquí: ver `retire`
            }
            info.pointee.cancel_fn = { cookie in
                Unmanaged<StreamBuffer>.fromOpaque(cookie!).takeUnretainedValue().cancel()
            }
            return 0
        }
        try check(mpv_stream_cb_add_ro(handle, name, userData, open), "mpv_stream_cb_add_ro(\(name))")
    }
}

/// URIs `glasstube://<id>/<pista>?g=<n>` → búfer. Cada URI se abre una sola vez.
final class MPVStreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [String: StreamBuffer] = [:]
    /// La referencia que tiene mpv (`user_data` del protocolo); se suelta tras destruir el handle.
    var retainedByMPV: UnsafeMutableRawPointer?

    func register(_ uri: String, _ buffer: StreamBuffer) { lock.withLock { buffers[uri] = buffer } }

    func remove(_ uri: String) { lock.withLock { _ = buffers.removeValue(forKey: uri) } }

    func open(_ uri: String) -> StreamBuffer? {
        Self.releaseRetired(olderThan: 10)
        return lock.withLock { buffers.removeValue(forKey: uri) }
    }

    /// Tras `mpv_terminate_destroy`: mpv ya no llamará a `open_fn`.
    func releaseMPVReference() {
        if let retainedByMPV { Unmanaged<MPVStreamRegistry>.fromOpaque(retainedByMPV).release() }
        retainedByMPV = nil
    }

    /// mpv puede llamar a `cancel_fn` después de `close_fn`: el hilo del demuxer cierra el flujo y, antes de liberar su
    /// `mp_cancel`, el hilo principal de mpv cancela la reproducción al cambiar de archivo (`mp_cancel_trigger` en
    /// `play_current_file`). Si `close_fn` soltaba el búfer, `cancel_fn` usaba un objeto liberado (dos crashes en el
    /// spike, 15-oct-2026). Por eso el búfer cerrado (ya vacío) se guarda aquí y se suelta en un `open` posterior,
    /// cuando ya pasaron unos segundos y el archivo anterior terminó de desmontarse.
    private static let retiredLock = NSLock()
    nonisolated(unsafe) private static var retired: [(buffer: Unmanaged<StreamBuffer>, at: Date)] = []

    static func retire(_ buffer: Unmanaged<StreamBuffer>) {
        retiredLock.withLock { retired.append((buffer, Date())) }
    }

    static func releaseRetired(olderThan seconds: TimeInterval) {
        let old = retiredLock.withLock { () -> [Unmanaged<StreamBuffer>] in
            let cutoff = Date().addingTimeInterval(-seconds)
            let old = retired.filter { $0.at < cutoff }.map(\.buffer)
            retired.removeAll { $0.at < cutoff }
            return old
        }
        old.forEach { $0.release() }
    }
}
