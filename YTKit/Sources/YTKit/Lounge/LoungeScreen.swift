import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Quién es esta pantalla para Lounge. El `screenId` es lo que el teléfono recuerda al vincular («permanent»); el
/// `deviceId` identifica la conexión. «Desvincular todos» los cambia por unos nuevos (`resetData` de SmartTube).
public struct LoungeIdentity: Codable, Sendable, Hashable {
    public var screenId: String?
    public var deviceId: String

    public init(screenId: String? = nil, deviceId: String = UUID().uuidString.lowercased()) {
        self.screenId = screenId
        self.deviceId = deviceId
    }
}

/// Dónde se guarda la identidad entre aperturas de la app.
public protocol LoungeIdentityStore: Sendable {
    func load() -> LoungeIdentity?
    func save(_ identity: LoungeIdentity)
}

/// En `UserDefaults` (como `MediaServiceData` de SmartTube, en sus preferencias). No son credenciales de la cuenta:
/// el id de pantalla solo sirve para que un teléfono ya vinculado la encuentre.
public final class UserDefaultsLoungeIdentityStore: LoungeIdentityStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "loungeIdentity") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> LoungeIdentity? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(LoungeIdentity.self, from: $0) }
    }

    public func save(_ identity: LoungeIdentity) {
        defaults.set(try? JSONEncoder().encode(identity), forKey: key)
    }
}

/// En memoria (pruebas y la CLI).
public final class MemoryLoungeIdentityStore: LoungeIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: LoungeIdentity?

    public init(_ identity: LoungeIdentity? = nil) {
        self.identity = identity
    }

    public func load() -> LoungeIdentity? { lock.withLock { identity } }
    public func save(_ identity: LoungeIdentity) { lock.withLock { self.identity = identity } }
}

/// Respuesta HTTP que no es 200 (con el principio del cuerpo, que en Lounge dice el motivo: «Unknown SID»…).
public struct LoungeHTTPError: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var body: String
    public init(status: Int, body: String) {
        self.status = status
        self.body = body
    }
    public var description: String { "HTTP \(status): \(body.prefix(120))" }
}

/// La red de Lounge (se reemplaza en las pruebas).
public protocol LoungeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Abre el canal largo. Con 200 devuelve el cuerpo en trozos a medida que llega; si no, lanza `LoungeHTTPError`.
    func open(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error>
}

/// `URLSession` propia: sin cookies de YouTube y con 65 s de espera sin datos (el servidor manda un `noop` cada ~30 s;
/// más de un minuto callado es una conexión colgada, como el `readTimeout` de 60 s de SmartTube).
public final class URLSessionLoungeTransport: LoungeTransport, @unchecked Sendable {
    static let idleTimeout: TimeInterval = 65
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.idleTimeout
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    #if canImport(Darwin)
    public func open(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 2000 { break }
            }
            bytes.task.cancel()
            throw LoungeHTTPError(status: http.statusCode, body: String(decoding: body, as: UTF8.self))
        }
        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    // Cada trozo del canal termina en salto de línea: se entrega al llegar a uno.
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A {
                            continuation.yield(chunk)
                            chunk = Data()
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                bytes.task.cancel()
            }
        }
    }
    #else
    /// Sin `URLSession.bytes(for:)` fuera de Apple: una sesión con delegado por canal, que entrega cada línea al llegar.
    public func open(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let reader = LoungeStreamReader(stream: continuation)
        let streaming = URLSession(configuration: session.configuration, delegate: reader, delegateQueue: nil)
        let task = streaming.dataTask(with: request)
        continuation.onTermination = { _ in
            task.cancel()
            streaming.invalidateAndCancel()
        }
        try await withCheckedThrowingContinuation { (response: CheckedContinuation<Void, Error>) in
            reader.setResponseContinuation(response)
            task.resume()
        }
        return stream
    }
    #endif
}

#if !canImport(Darwin)
/// Delegado de `URLSessionLoungeTransport.open`: con 200 reanuda la apertura y pasa el cuerpo por líneas; con otro
/// estado junta hasta 2000 B del cuerpo y lanza `LoungeHTTPError`.
private final class LoungeStreamReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncThrowingStream<Data, Error>.Continuation
    private var response: CheckedContinuation<Void, Error>?
    private var status = 0
    private var buffer = Data()

    init(stream: AsyncThrowingStream<Data, Error>.Continuation) { self.stream = stream }

    func setResponseContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { response = continuation }
    }

    private func resumeResponse(_ result: Result<Void, Error>) {
        lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { response = nil }
            return response
        }?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.withLock { self.status = status }
        if status == 200 { resumeResponse(.success(())) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var lines: [Data] = []
        let ok: Bool = lock.withLock {
            buffer.append(data)
            guard status == 200 else { return false }
            // Cada trozo del canal termina en salto de línea: se entrega al llegar a uno.
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer.subdata(in: buffer.startIndex..<buffer.index(after: newline)))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return true
        }
        lines.forEach { stream.yield($0) }
        if !ok, lock.withLock({ buffer.count > 2000 }) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (status, rest) = lock.withLock { () -> (Int, Data) in
            defer { buffer = Data() }
            return (self.status, buffer)
        }
        if status == 200 {
            if !rest.isEmpty { stream.yield(rest) }
            stream.finish(throwing: error)
        } else if status != 0 {
            resumeResponse(.failure(LoungeHTTPError(status: status, body: String(decoding: rest.prefix(2000), as: UTF8.self))))
            stream.finish()
        } else {
            resumeResponse(.failure(error ?? URLError(.badServerResponse)))
            stream.finish(throwing: error)
        }
        session.finishTasksAndInvalidate()
    }
}
#endif

/// La Mac como «pantalla» de Lounge (`LoungeService` de SmartTube): código para vincular, canal largo con reconexión,
/// comandos del teléfono como eventos y reportes de vuelta.
///
///     let screen = LoungeScreen(name: "Glasstube", store: UserDefaultsLoungeIdentityStore())
///     let events = await screen.events()
///     await screen.start()
///     let code = try await screen.pairingCode()      // «123-456-789-012» en la app del teléfono
///     for await event in events { … }                 // .command(.setPlaylist(…)), .remotes([…]), .state(…)
///     await screen.send([.nowPlaying(…)])
///
/// Reconexión: si el canal se cierra (lo hace el servidor cada pocos minutos) se vuelve a abrir con la misma sesión;
/// si el servidor ya no la conoce (400, 404, 410) se abre otra; si el token venció (401, 403) se pide otro; si falla la
/// red, se espera 3, 6, 12… hasta 60 s. El token se renueva cada 30 min al reabrir, como en SmartTube.
public actor LoungeScreen {
    public private(set) var state: LoungeConnectionState = .stopped
    public private(set) var remotes: [LoungeRemote] = []

    private var name: String
    private let store: LoungeIdentityStore
    private let transport: LoungeTransport
    private var identity: LoungeIdentity
    private var token: (value: String, fetchedAt: Date)?
    private var session: (sid: String, gsessionid: String)?
    /// Último id de mensaje recibido (se devuelve como `AID`).
    private var lastMessageId = -1
    /// Reportes enviados en esta sesión (el `ofs` de BrowserChannel).
    private var offset = 0
    private var rid = Int.random(in: 10_000..<90_000)
    private var runTask: Task<Void, Never>?
    /// Sube en cada arranque; lo que llega de una conexión anterior se descarta.
    private var generation = 0
    private var postChain: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<LoungeEvent>.Continuation] = [:]
    /// Pausas de reintento (en las pruebas son más cortas).
    private let retryDelays: [TimeInterval]

    static let tokenLifetime: TimeInterval = 30 * 60

    public init(name: String, store: LoungeIdentityStore = MemoryLoungeIdentityStore(),
                transport: LoungeTransport = URLSessionLoungeTransport(),
                retryDelays: [TimeInterval] = [3, 6, 12, 24, 48, 60]) {
        self.name = name
        self.store = store
        self.transport = transport
        self.retryDelays = retryDelays
        if let saved = store.load() {
            identity = saved
        } else {
            identity = LoungeIdentity()
            store.save(identity)
        }
    }

    /// Un flujo de eventos por suscriptor; empieza con el estado actual.
    public func events() -> AsyncStream<LoungeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LoungeEvent>.makeStream(bufferingPolicy: .bufferingNewest(200))
        continuation.yield(.state(state))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func emit(_ event: LoungeEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func setState(_ newState: LoungeConnectionState) {
        guard newState != state else { return }
        state = newState
        emit(.state(newState))
    }

    public var isRunning: Bool { runTask != nil }
    public var screenId: String? { identity.screenId }

    // MARK: - Arranque y parada

    public func start() {
        guard runTask == nil else { return }
        generation += 1
        let current = generation
        setState(.connecting)
        runTask = Task { await self.run(current) }
    }

    public func stop() {
        generation += 1
        runTask?.cancel()
        runTask = nil
        session = nil
        if !remotes.isEmpty {
            remotes = []
            emit(.remotes([]))
        }
        setState(.stopped)
    }

    /// Otra sesión desde cero (token nuevo), si estaba encendida.
    public func restart() {
        guard runTask != nil else { return }
        stop()
        token = nil
        start()
    }

    /// El nombre con que aparece en el teléfono. Vale para la próxima sesión; si está encendida, se reabre.
    public func setName(_ newName: String) {
        guard newName != name else { return }
        name = newName
        restart()
    }

    /// «Desvincular todos»: id de pantalla y de dispositivo nuevos. Los teléfonos vinculados ya no la encuentran.
    public func unlinkAll() {
        let wasRunning = runTask != nil
        stop()
        identity = LoungeIdentity()
        store.save(identity)
        token = nil
        lastMessageId = -1
        if wasRunning { start() }
    }

    // MARK: - Código para vincular

    /// Pide un código de 12 dígitos para «Vincular con código de TV» (`get_pairing_code`, con los campos de
    /// `getPairingCodeV2`). Como SmartTube, después reabre la sesión con un token nuevo («apply changes»).
    public func pairingCode() async throws -> LoungePairingCode {
        let token = try await ensureToken()
        guard let screenId = identity.screenId else { throw YTKitError.badResponse("Lounge sin id de pantalla") }
        var request = URLRequest(url: LoungeEndpoints.pairingCode, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = LoungeEndpoints.form([
            ("lounge_token", token), ("screen_id", screenId), ("screen_name", name), ("access_type", "permanent"),
            ("app", LoungeEndpoints.app), ("device_id", identity.deviceId), ("qr", "1"),
        ])
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            if [401, 403].contains(response.statusCode) { self.token = nil }
            throw LoungeHTTPError(status: response.statusCode, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let code = LoungePairingCode.parse(data) else { throw YTKitError.badResponse("get_pairing_code sin código") }
        Log.debug("lounge: código de vinculación nuevo")
        restart()
        return code
    }

    // MARK: - Reportes

    /// Manda reportes al teléfono (en orden, uno tras otro). Sin sesión abierta no se mandan.
    public func send(_ reports: [LoungeReport]) {
        guard !reports.isEmpty else { return }
        let previous = postChain
        postChain = Task {
            await previous?.value
            await self.post(reports)
        }
    }

    private func post(_ reports: [LoungeReport]) async {
        guard let session, let token else {
            Log.debug("lounge: sin sesión, no se manda \(reports.map(\.command).joined(separator: ", "))")
            return
        }
        let fields = LoungeReport.formFields(reports, offset: offset)
        offset += reports.count
        rid += 1
        var request = URLRequest(url: LoungeEndpoints.bindURL([
            ("RID", String(rid)), ("AID", String(lastMessageId)), ("name", name), ("id", identity.deviceId),
            ("loungeIdToken", token.value), ("SID", session.sid), ("gsessionid", session.gsessionid),
        ]), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = LoungeEndpoints.form(fields)
        do {
            let (data, response) = try await transport.send(request)
            Log.debug("lounge: → \(reports.map(\.command).joined(separator: ", ")) HTTP \(response.statusCode)")
            if response.statusCode != 200 {
                Log.info("Lounge: el reporte \(reports.map(\.command).joined(separator: ", ")) dio HTTP \(response.statusCode) \(String(decoding: data.prefix(80), as: UTF8.self))")
            }
        } catch {
            Log.info("Lounge: no se pudo mandar \(reports.map(\.command).joined(separator: ", ")): \(error.localizedDescription)")
        }
    }

    // MARK: - Canal

    private func run(_ current: Int) async {
        var failures = 0
        while !Task.isCancelled, current == generation {
            do {
                _ = try await ensureToken()
                if session == nil { try await bind(current) }
                guard current == generation else { return }
                setState(.connected)
                let received = try await listen(current)
                if received {
                    failures = 0
                } else {
                    // Se cerró sin mandar nada: una pausa corta para no reabrir en bucle.
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {
                return
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                if let http = error as? LoungeHTTPError {
                    switch http.status {
                    case 400, 404, 410:
                        // El servidor ya no conoce la sesión («Unknown SID»): otra sesión.
                        session = nil
                    case 401, 403:
                        token = nil
                        session = nil
                    default:
                        break
                    }
                }
                let delay = retryDelays.isEmpty ? 3 : retryDelays[min(failures, retryDelays.count - 1)]
                failures += 1
                let reason = Self.describe(error)
                Log.info("Lounge: \(reason); reintento en \(Int(delay)) s")
                setState(.retrying(after: delay, reason: reason))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard current == generation else { return }
                setState(.connecting)
            }
        }
    }

    /// Token de Lounge para el id de pantalla (lo crea la primera vez), renovado cada 30 min.
    private func ensureToken() async throws -> String {
        if let token, Date().timeIntervalSince(token.fetchedAt) < Self.tokenLifetime { return token.value }
        if identity.screenId == nil {
            let (data, response) = try await transport.send(URLRequest(url: LoungeEndpoints.generateScreenId, timeoutInterval: 30))
            let screenId = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard response.statusCode == 200, !screenId.isEmpty, !screenId.contains("<") else {
                throw LoungeHTTPError(status: response.statusCode, body: String(decoding: data.prefix(200), as: UTF8.self))
            }
            identity.screenId = screenId
            store.save(identity)
        }
        var request = URLRequest(url: LoungeEndpoints.tokenBatch, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = LoungeEndpoints.form([("screen_ids", identity.screenId ?? "")])
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200, let parsed = LoungeEndpoints.parseToken(data) else {
            if response.statusCode == 200 || response.statusCode == 400 {
                // Un id de pantalla que YouTube ya no reconoce: la próxima vez se pide otro.
                identity.screenId = nil
                store.save(identity)
            }
            throw LoungeHTTPError(status: response.statusCode, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
        token = (parsed.token, Date())
        return parsed.token
    }

    /// Abre la sesión (`count=0`): llegan el SID (`c`), el `gsessionid` (`S`), `loungeStatus` y `getNowPlaying`.
    private func bind(_ current: Int) async throws {
        guard let token else { throw YTKitError.badResponse("Lounge sin token") }
        rid += 1
        var request = URLRequest(url: LoungeEndpoints.bindURL([
            ("RID", String(rid)), ("name", name), ("id", identity.deviceId), ("loungeIdToken", token.value),
        ]), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = LoungeEndpoints.form([("count", "0")])
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            if [400, 401, 403].contains(response.statusCode) { self.token = nil }
            throw LoungeHTTPError(status: response.statusCode, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard current == generation else { throw CancellationError() }
        var parser = BindChunkParser()
        let messages = parser.feed(data)
        var sid: String?
        var gsessionid: String?
        for message in messages {
            switch message.type {
            case "c": sid = message.firstArgument
            case "S": gsessionid = message.firstArgument
            default: break
            }
        }
        guard let sid, let gsessionid else { throw YTKitError.badResponse("bind sin SID") }
        session = (sid, gsessionid)
        offset = 0
        lastMessageId = -1
        Log.debug("lounge: sesión abierta")
        for message in messages { handle(message) }
    }

    /// Lee el canal hasta que se cierra. Devuelve si llegó algo.
    private func listen(_ current: Int) async throws -> Bool {
        guard let session, let token else { throw YTKitError.badResponse("Lounge sin sesión") }
        let request = URLRequest(url: LoungeEndpoints.bindURL([
            ("RID", "rpc"), ("SID", session.sid), ("CI", "0"), ("AID", String(lastMessageId)), ("TYPE", "xmlhttp"),
            ("name", name), ("id", identity.deviceId), ("loungeIdToken", token.value), ("gsessionid", session.gsessionid),
        ]), timeoutInterval: URLSessionLoungeTransport.idleTimeout)
        let chunks = try await transport.open(request)
        guard current == generation else { throw CancellationError() }
        var parser = BindChunkParser()
        var received = false
        for try await data in chunks {
            guard current == generation, !Task.isCancelled else { throw CancellationError() }
            for message in parser.feed(data) {
                received = true
                handle(message)
                if message.type == "stop" {
                    // El servidor terminó la sesión.
                    self.session = nil
                    return received
                }
            }
        }
        return received
    }

    private func handle(_ message: LoungeMessage) {
        if message.id <= lastMessageId { return }
        lastMessageId = message.id
        guard let type = message.type, !["c", "S", "noop", "stop"].contains(type) else { return }
        let command = LoungeCommand.decode(message.payload)
        Log.debug("lounge: ← \(command.name)")
        switch command {
        case .loungeStatus(let devices):
            updateRemotes(devices.filter { !$0.isScreen })
        case .remoteConnected(let remote) where !remote.isScreen:
            updateRemotes(remotes.filter { $0.id != remote.id } + [remote])
        case .remoteDisconnected(let remote):
            updateRemotes(remotes.filter { $0.id != remote.id })
        default:
            break
        }
        emit(.command(command))
    }

    private func updateRemotes(_ list: [LoungeRemote]) {
        guard list != remotes else { return }
        remotes = list
        emit(.remotes(list))
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let http as LoungeHTTPError: return http.description
        case let url as URLError where url.code == .timedOut: return "sin noticias del servidor en 65 s"
        case let url as URLError where url.code == .notConnectedToInternet: return "sin conexión a internet"
        case let url as URLError: return url.localizedDescription
        default: return "\(error)"
        }
    }
}
