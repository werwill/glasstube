import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import YTKit

/// Control remoto por Lounge (fase 4): el canal `bc/bind`, los comandos del teléfono, los reportes y la reconexión con
/// una red falsa.
@Suite struct LoungeTests {
    /// La respuesta real del `bind` inicial (18-oct-2026), con el SID, el `gsessionid` y los ids cambiados por unos de
    /// prueba. Cada trozo es `<longitud>\n<arreglo>`.
    static let initialBind = """
        608
        [[0,["c","SID_DE_PRUEBA","",8]]
        ,[1,["S","GSESSION_DE_PRUEBA"]]
        ,[2,["loungeStatus",{"queueId":"RQ_DE_PRUEBA","devices":"[{\\"app\\":\\"lb-v4\\",\\"capabilities\\":\\"dsp,mic,dpa,que,mus\\",\\"clientName\\":\\"tvhtml5\\",\\"name\\":\\"Glasstube prueba\\",\\"theme\\":\\"cl\\",\\"id\\":\\"00000000-0000-4000-8000-000000000001\\",\\"type\\":\\"LOUNGE_SCREEN\\",\\"hasCc\\":\\"true\\"},{\\"app\\":\\"android-phone-19.40\\",\\"name\\":\\"Teléfono de prueba\\",\\"id\\":\\"remoto-1\\",\\"type\\":\\"REMOTE_CONTROL\\",\\"pairingType\\":\\"manual\\"}]","connectionEventDetails":"{\\"deviceId\\":\\"00000000-0000-4000-8000-000000000001\\"}"}]]
        ,[3,["getNowPlaying"]]
        ,[4,["getDiscoveryDeviceId"]]
        ]

        """

    // MARK: - Canal

    @Test func parsesTheInitialBindEvenOneByteAtATime() {
        var whole = BindChunkParser()
        let messages = whole.feed(Data(Self.initialBind.utf8))
        #expect(messages.map(\.id) == [0, 1, 2, 3, 4])
        #expect(messages.map(\.type) == ["c", "S", "loungeStatus", "getNowPlaying", "getDiscoveryDeviceId"])
        #expect(messages[0].firstArgument == "SID_DE_PRUEBA")
        #expect(messages[1].firstArgument == "GSESSION_DE_PRUEBA")

        // Partido en cualquier byte (también a la mitad de la «é» de «Teléfono»), da lo mismo.
        var parser = BindChunkParser()
        var pieces: [LoungeMessage] = []
        for byte in Data(Self.initialBind.utf8) { pieces += parser.feed(Data([byte])) }
        #expect(pieces.map(\.id) == [0, 1, 2, 3, 4])
        #expect(parser.pending == 0)

        guard case .loungeStatus(let devices) = LoungeCommand.decode(messages[2].payload) else {
            Issue.record("loungeStatus no se decodificó")
            return
        }
        #expect(devices.count == 2)
        #expect(devices[0].isScreen)
        #expect(devices[1].name == "Teléfono de prueba")
        #expect(devices[1].pairingType == "manual")
    }

    @Test func parsesSeveralChunksAndNoops() {
        let stream = "16\n[[5,[\"noop\"]]\n]\n" + "45\n[[6,[\"seekTo\",{\"newTime\":\"95.5\"}]]\n]\n" + "40\n[[7,[\"dpadCommand\",{\"key\":\"UP\"}]]]\n"
        var parser = BindChunkParser()
        let data = Data(stream.utf8)
        // En dos pedazos, cortado a la mitad del segundo trozo.
        var messages = parser.feed(data.prefix(30))
        #expect(messages.map(\.id) == [5])
        messages += parser.feed(data.dropFirst(30))
        #expect(messages.map(\.id) == [5, 6, 7])
        #expect(LoungeCommand.decode(messages[1].payload) == .seekTo(95.5))
        #expect(LoungeCommand.decode(messages[2].payload) == .dpad(.up))
    }

    @Test func decodesThePhoneCommands() {
        func decode(_ json: String) -> LoungeCommand {
            LoungeCommand.decode(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [Any])
        }
        let playlist = decode("""
            ["setPlaylist",{"videoId":"dQw4w9WgXcQ","currentTime":"12.5","currentIndex":"1","listId":"RQ_DE_PRUEBA",
             "videoIds":"aqz-KE-bpKQ,dQw4w9WgXcQ,eRsGyueVLvQ","ctt":"CTT_DE_PRUEBA","params":"","audioOnly":"false"}]
            """)
        guard case .setPlaylist(let list) = playlist else {
            Issue.record("setPlaylist: \(playlist)")
            return
        }
        #expect(list.currentVideoId == "dQw4w9WgXcQ")
        #expect(list.currentTime == 12.5)
        #expect(list.currentIndex == 1)
        #expect(list.videoIds == ["aqz-KE-bpKQ", "dQw4w9WgXcQ", "eRsGyueVLvQ"])
        #expect(list.ctt == "CTT_DE_PRUEBA")
        #expect(list.listId == "RQ_DE_PRUEBA")
        // Sin `videoId`, el de `currentIndex` en la cola.
        #expect(LoungePlaylist(videoIds: ["a", "b"], currentIndex: 1).currentVideoId == "b")

        #expect(decode(#"["play"]"#) == .play)
        #expect(decode(#"["pause"]"#) == .pause)
        #expect(decode(#"["next"]"#) == .next)
        #expect(decode(#"["previous"]"#) == .previous)
        #expect(decode(#"["stopVideo"]"#) == .stopVideo)
        #expect(decode(#"["seekTo",{"newTime":"30"}]"#) == .seekTo(30))
        #expect(decode(#"["setVolume",{"volume":"40"}]"#) == .setVolume(volume: 40, delta: nil))
        #expect(decode(#"["setVolume",{"delta":"-5"}]"#) == .setVolume(volume: nil, delta: -5))
        #expect(decode(#"["dpadCommand",{"key":"BACK"}]"#) == .dpad(.back))
        #expect(decode(#"["dpadCommand",{"key":"ENTER"}]"#) == .dpad(.enter))
        #expect(decode(#"["setSubtitlesTrack",{"videoId":"dQw4w9WgXcQ","languageCode":"es"}]"#)
                == .setSubtitlesTrack(LoungeSubtitles(videoId: "dQw4w9WgXcQ", languageCode: "es")))
        let off = decode(#"["setSubtitlesTrack",{"videoId":"dQw4w9WgXcQ"}]"#)
        if case .setSubtitlesTrack(let subtitles) = off { #expect(subtitles.isOff) } else { Issue.record("subtítulos: \(off)") }
        #expect(decode(#"["remoteConnected",{"app":"ios-phone","name":"iPhone de prueba","id":"r2","type":"REMOTE_CONTROL"}]"#)
                == .remoteConnected(LoungeRemote(id: "r2", name: "iPhone de prueba", type: "REMOTE_CONTROL", app: "ios-phone")))
        #expect(decode(#"["getVolume"]"#) == .getVolume)
        #expect(decode(#"["voiceCommand",{"status":"INITIATED"}]"#) == .voiceCommand(started: true))
        #expect(decode(#"["setAutoplayMode",{"autoplayMode":"ENABLED"}]"#) == .other("setAutoplayMode"))
        #expect(decode(#"["seekTo",{}]"#) == .other("seekTo"))
    }

    // MARK: - Reportes

    @Test func encodesReportsLikeSmartTube() {
        let playing = LoungeNowPlaying(videoId: "aqz-KE-bpKQ", currentTime: 12.25, duration: 634.5, state: .playing,
                                       listId: "RQ_DE_PRUEBA", currentIndex: 0, ctt: "CTT_DE_PRUEBA")
        let fields = LoungeReport.formFields([.nowPlaying(playing), .stateChange(state: .paused, currentTime: 13, duration: 634.5)], offset: 3)
        let form = Dictionary(fields, uniquingKeysWith: { first, _ in first })
        #expect(form["count"] == "2")
        #expect(form["ofs"] == "3")
        #expect(form["req0__sc"] == "nowPlaying")
        #expect(form["req0_videoId"] == "aqz-KE-bpKQ")
        #expect(form["req0_currentTime"] == "12.25")
        #expect(form["req0_duration"] == "634.5")
        #expect(form["req0_seekableEndTime"] == "634.5")
        #expect(form["req0_state"] == "1")
        #expect(form["req0_listId"] == "RQ_DE_PRUEBA")
        #expect(form["req0_currentIndex"] == "0")
        #expect(form["req0_ctt"] == "CTT_DE_PRUEBA")
        #expect(form["req1__sc"] == "onStateChange")
        #expect(form["req1_state"] == "2")
        #expect(form["req1_currentTime"] == "13")

        // «Nada suena»: solo el nombre del comando.
        #expect(LoungeReport.formFields([.nowPlaying(nil)], offset: 0).map(\.0) == ["count", "ofs", "req0__sc"])
        let volume = Dictionary(LoungeReport.formFields([.volumeChanged(volume: 140, muted: false)], offset: 9), uniquingKeysWith: { a, _ in a })
        #expect(volume["req0_volume"] == "100")
        #expect(volume["req0_muted"] == "false")
        let subtitles = Dictionary(LoungeReport.formFields([.subtitlesTrackChanged(videoId: "x", languageCode: "es", vssId: ".es")], offset: 0),
                                   uniquingKeysWith: { a, _ in a })
        #expect(subtitles["req0__sc"] == "onSubtitlesTrackChanged")
        #expect(subtitles["req0_languageCode"] == "es")
        #expect(subtitles["req0_vss_id"] == ".es")
        // El cuerpo va codificado como formulario.
        #expect(String(decoding: LoungeEndpoints.form([("name", "Mac de prueba & co"), ("x", "a=b")]), as: UTF8.self)
                == "name=Mac%20de%20prueba%20%26%20co&x=a%3Db")
    }

    // MARK: - Código y token

    @Test func parsesPairingCodesAndTokens() {
        // Con `qr=1`: JSON con el código y la imagen.
        let json = LoungePairingCode.parse(Data(#"{"qr":{"width":256,"image":"data:image/png;base64,AAAA","height":256},"code":"123456789012"}"#.utf8))
        #expect(json?.digits == "123456789012")
        #expect(json?.formatted == "123-456-789-012")
        #expect(json?.pairURL.absoluteString == "https://youtube.com/pair/123456789012?qr=1")
        // Sin `qr`: texto plano.
        #expect(LoungePairingCode.parse(Data("987654321098\n".utf8))?.formatted == "987-654-321-098")
        #expect(LoungePairingCode.parse(Data("<html>error</html>".utf8)) == nil)

        let token = LoungeEndpoints.parseToken(Data("""
            {"screens":[{"screenId":"PANTALLA_DE_PRUEBA","refreshIntervalInMillis":1123200000,"loungeTokenLifespanMs":1209600000,
             "loungeToken":"TOKEN_DE_PRUEBA","expiration":1793468221663}]}
            """.utf8))
        #expect(token?.screenId == "PANTALLA_DE_PRUEBA")
        #expect(token?.token == "TOKEN_DE_PRUEBA")
        #expect(token?.expiration != nil)
        #expect(LoungeEndpoints.parseToken(Data(#"{"screens":[]}"#.utf8)) == nil)
    }

    // MARK: - Sesión completa con una red falsa

    /// Abre la sesión, recibe un comando, el servidor cierra el canal y se reabre con la misma sesión (con `AID`), luego
    /// el servidor ya no la conoce (400 «Unknown SID») y se abre otra. Los reportes llevan `ofs` seguidos.
    @Test func reconnectsAndReportsInOrder() async throws {
        let network = FakeLoungeNetwork()
        let store = MemoryLoungeIdentityStore()
        let screen = LoungeScreen(name: "Mac de prueba", store: store, transport: network, retryDelays: [0.01])
        let events = await screen.events()
        let recorder = EventRecorder()
        let listening = Task { for await event in events { await recorder.add(event) } }
        await screen.start()

        // La segunda sesión manda `seekTo`.
        try await recorder.wait { $0.contains(.command(.seekTo(42))) }
        let saw = await recorder.events
        let commands = saw.compactMap { event -> String? in if case .command(let command) = event { command.name } else { nil } }
        #expect(commands == ["loungeStatus", "getNowPlaying", "getDiscoveryDeviceId", "setPlaylist", "loungeStatus", "seekTo"])
        #expect(saw.contains(.remotes([LoungeRemote(id: "remoto-1", name: "Teléfono de prueba", type: "REMOTE_CONTROL",
                                                    app: "android-phone-19.40", pairingType: "manual")])))
        #expect(saw.contains { if case .state(.retrying) = $0 { true } else { false } })
        #expect(await screen.state == .connected)

        let opens = network.requests.filter { $0.url!.absoluteString.contains("RID=rpc") }
        #expect(opens.count == 3)
        // Primera vez, con lo último del bind (4); al reabrir, con el último visto (6, que era el `setPlaylist`).
        #expect(opens[0].query("AID") == "4")
        #expect(opens[0].query("SID") == "SID_DE_PRUEBA")
        #expect(opens[1].query("AID") == "6")
        #expect(opens[1].query("SID") == "SID_DE_PRUEBA")
        #expect(opens[2].query("SID") == "SID_DOS")
        #expect(opens[0].query("loungeIdToken") == "TOKEN_DE_PRUEBA")
        #expect(opens[0].query("name") == "Mac de prueba")
        #expect(store.load()?.screenId == "PANTALLA_DE_PRUEBA")

        await screen.send([.nowPlaying(nil)])
        await screen.send([.volumeChanged(volume: 30, muted: false), .stateChange(state: .paused, currentTime: 1, duration: 10)])
        try await waitUntil { network.posts.count == 2 }
        #expect(network.posts[0]["ofs"] == "0")
        #expect(network.posts[0]["req0__sc"] == "nowPlaying")
        #expect(network.posts[1]["count"] == "2")
        #expect(network.posts[1]["ofs"] == "1")
        #expect(network.posts[1]["req1__sc"] == "onStateChange")

        // Desvincular todos: otra identidad.
        let before = store.load()
        await screen.unlinkAll()
        #expect(store.load()?.deviceId != before?.deviceId)
        await screen.stop()
        #expect(await screen.state == .stopped)
        listening.cancel()
    }
}

// MARK: - Apoyo

private actor EventRecorder {
    private(set) var events: [LoungeEvent] = []
    func add(_ event: LoungeEvent) { events.append(event) }

    func wait(timeout: TimeInterval = 5, until condition: @Sendable ([LoungeEvent]) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(events) {
            guard Date() < deadline else {
                Issue.record("tiempo agotado; eventos: \(events)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("tiempo agotado")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private extension URLRequest {
    func query(_ name: String) -> String? {
        URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

/// Red de Lounge falsa: un id de pantalla, un token, dos sesiones y los cierres del canal que hacen falta para probar
/// la reconexión.
private final class FakeLoungeNetwork: LoungeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _posts: [[String: String]] = []
    private var binds = 0
    private var opens = 0

    var requests: [URLRequest] { lock.withLock { _requests } }
    var posts: [[String: String]] { lock.withLock { _posts } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!.absoluteString
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let reply: String = lock.withLock {
            _requests.append(request)
            if url.contains("generate_screen_id") { return "PANTALLA_DE_PRUEBA" }
            if url.contains("get_lounge_token_batch") {
                return #"{"screens":[{"screenId":"PANTALLA_DE_PRUEBA","loungeToken":"TOKEN_DE_PRUEBA","expiration":1793468221663}]}"#
            }
            if body == "count=0" {
                binds += 1
                return binds == 1 ? LoungeTests.initialBind : "60\n[[0,[\"c\",\"SID_DOS\",\"\",8]]\n,[1,[\"S\",\"GSESSION_DOS\"]]\n,[2,[\"loungeStatus\",{\"devices\":\"[]\"}]]\n]\n"
            }
            var fields: [String: String] = [:]
            for pair in body.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if parts.count == 2 { fields[parts[0]] = parts[1] }
            }
            _posts.append(fields)
            return "8\n[1,5,0]\n"
        }
        return (Data(reply.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func open(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let attempt: Int = lock.withLock {
            _requests.append(request)
            opens += 1
            return opens
        }
        switch attempt {
        case 1:
            // Un comando y el servidor cierra el canal.
            return AsyncThrowingStream { continuation in
                continuation.yield(Data("16\n[[5,[\"noop\"]]\n]\n".utf8))
                continuation.yield(Data("60\n[[6,[\"setPlaylist\",{\"videoId\":\"aqz-KE-bpKQ\",\"currentTime\":\"0\"}]]\n]\n".utf8))
                continuation.finish()
            }
        case 2:
            throw LoungeHTTPError(status: 400, body: "Unknown SID")
        default:
            // La sesión nueva: un comando y el canal queda abierto.
            return AsyncThrowingStream { continuation in
                continuation.yield(Data("40\n[[3,[\"seekTo\",{\"newTime\":\"42\"}]]\n]\n".utf8))
            }
        }
    }
}
