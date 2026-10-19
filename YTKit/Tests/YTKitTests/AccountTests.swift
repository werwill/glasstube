import Foundation
import Testing
@testable import YTKit

/// OAuth falso: entrega tokens inventados y anota lo que se le pide. Sin red.
final class FakeTokenService: TokenService, @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshes = 0
    private var _revoked: [String] = []
    var refreshError: AuthError?

    var refreshes: Int { lock.withLock { _refreshes } }
    var revoked: [String] { lock.withLock { _revoked } }

    func requestDeviceCode(deviceId: String) async throws -> DeviceCode {
        DeviceCode(userCode: "ABC-DEF-GHI", verificationURL: URL(string: "https://www.youtube.com/activate")!,
                   expiresAt: Date().addingTimeInterval(1800), interval: 5, deviceCode: "codigo-de-dispositivo",
                   client: OAuthClientCredentials(clientId: "cliente.apps.googleusercontent.com", clientSecret: "secreto"))
    }

    func waitForGrant(_ code: DeviceCode) async throws -> TokenGrant {
        TokenGrant(accessToken: "acceso-1", tokenType: "Bearer", expiresIn: 3600, refreshToken: "renovacion-1")
    }

    func refresh(_ refreshToken: String) async throws -> TokenGrant {
        if let refreshError { throw refreshError }
        let n = lock.withLock { _refreshes += 1; return _refreshes }
        return TokenGrant(accessToken: "acceso-r\(n)", tokenType: "Bearer", expiresIn: 3600, refreshToken: nil)
    }

    func revoke(_ token: String) async throws { lock.withLock { _revoked.append(token) } }
}

@Suite struct AccountTests {
    // MARK: - OAuth

    @Test func clientCredentialsComeFromTheFirstMatch() throws {
        // `ClientData`: la primera aparición es la de Android TV; la segunda daría 401.
        let js = #"a={clientId:"111-aaa.apps.googleusercontent.com",x:"PRIMERO"};b={clientId:"222-bbb.apps.googleusercontent.com","# + "\n" + #"y:"SEGUNDO"}"#
        let credentials = try #require(ClientCredentialsCache.credentials(in: js))
        #expect(credentials.clientId == "111-aaa.apps.googleusercontent.com")
        #expect(credentials.clientSecret == "PRIMERO")
        #expect(ClientCredentialsCache.credentials(in: "sin nada") == nil)
    }

    @Test func baseScriptURLFromTheTVPage() {
        let cobalt = #"var s=document.createElement('script');s.src = '/s/_/kabuki/_/js/k=kabuki.base/m=base';"#
        #expect(ClientCredentialsCache.baseScriptURL(in: cobalt)?.absoluteString == "https://www.youtube.com/s/_/kabuki/_/js/k=kabuki.base/m=base")
        let html = #"<script id="base-js" src="\/s\/x\/base.js"></script>"#
        #expect(ClientCredentialsCache.baseScriptURL(in: html)?.absoluteString == "https://www.youtube.com/s/x/base.js")
    }

    @Test func tokenGrantParsing() {
        let grant = OAuthClient.grant(["access_token": "a", "token_type": "Bearer", "expires_in": 3599, "refresh_token": "r"])
        #expect(grant?.refreshToken == "r")
        #expect(grant?.expiresIn == 3599)
        #expect(OAuthClient.grant(["error": "authorization_pending"]) == nil)
    }

    // MARK: - Bóveda

    @Test func vaultDecodesMinimalAndOlderShapes() throws {
        // Lo que guardó la verificación del flujo (sin cuentas ni elegida).
        let json = #"{"version":1,"credentials":[{"id":"s1","refreshToken":"r"}],"accounts":[]}"#
        let vault = try JSONDecoder().decode(Vault.self, from: Data(json.utf8))
        #expect(vault.credentials.count == 1)
        #expect(vault.selectedAccountId == nil)
        #expect(vault.deviceId == nil)
        #expect(try JSONDecoder().decode(Vault.self, from: Data("{}".utf8)).credentials.isEmpty)
    }

    // MARK: - accounts_list

    @Test func accountsListWithBrandAccounts() throws {
        let data = try Fixture.data("cuenta/accounts-list.json")
        let accounts = try AccountsListParser.accounts(from: data, credentialId: "s1")
        #expect(accounts.count >= 1)
        let owner = try #require(accounts.first { !$0.isBrand })
        #expect(owner.id == "s1/principal")
        #expect(!owner.name.isEmpty)
        #expect(owner.avatar.allSatisfy { $0.url.hasPrefix("https://") })
        #expect(accounts.filter(\.isActivated).count == 1)
        for brand in accounts where brand.isBrand {
            #expect(brand.id == "s1/\(brand.pageId!)")
        }
    }

    // MARK: - AccountManager

    static func manager(store: MemoryCredentialStore = MemoryCredentialStore(), oauth: FakeTokenService = FakeTokenService(),
                        accounts: String = "cuenta/accounts-list.json") -> AccountManager {
        AccountManager(store: store, oauth: oauth) { authorization in
            #expect(authorization.hasPrefix("Bearer acceso-"))
            return try Fixture.data(accounts)
        }
    }

    @Test func signInStoresTheSessionAndSelectsTheActivatedAccount() async throws {
        let store = MemoryCredentialStore()
        let oauth = FakeTokenService()
        let manager = Self.manager(store: store, oauth: oauth)
        #expect(try await manager.load().isSignedIn == false)
        #expect(try await manager.authorizationHeaders() == nil)

        let code = try await manager.beginSignIn()
        #expect(code.userCode == "ABC-DEF-GHI")
        let snapshot = try await manager.completeSignIn(code)
        #expect(snapshot.isSignedIn)
        #expect(snapshot.selected?.isActivated == true)

        // La bóveda guarda el refresh token y el device_id; los access tokens no.
        let vault = try #require(try store.load())
        #expect(vault.credentials.map(\.refreshToken) == ["renovacion-1"])
        #expect(vault.deviceId != nil)
        let encoded = String(decoding: try JSONEncoder().encode(vault), as: UTF8.self)
        #expect(!encoded.contains("acceso-"))

        // El access token del inicio de sesión se reutiliza (sin renovar).
        let headers = try #require(try await manager.authorizationHeaders())
        #expect(headers["Authorization"] == "Bearer acceso-1")
        #expect(oauth.refreshes == 0)
    }

    @Test func brandAccountsSendPageIdAndSurviveRelaunch() async throws {
        let store = MemoryCredentialStore()
        let manager = Self.manager(store: store)
        let snapshot = try await manager.completeSignIn(try await manager.beginSignIn())
        guard let brand = snapshot.accounts.first(where: \.isBrand) else { return }   // la cuenta grabada no tiene marcas
        _ = try await manager.select(accountId: brand.id)
        let headers = try #require(try await manager.authorizationHeaders())
        #expect(headers["X-Goog-Pageid"] == brand.pageId)

        // Otra instancia (relanzar la app): lee la bóveda y renueva el access token una vez.
        let oauth = FakeTokenService()
        let relaunched = Self.manager(store: store, oauth: oauth)
        #expect(try await relaunched.load().selected?.id == brand.id)
        _ = try await relaunched.authorizationHeaders()
        _ = try await relaunched.authorizationHeaders()
        #expect(oauth.refreshes == 1)
    }

    @Test func signOutRevokesAndForgets() async throws {
        let store = MemoryCredentialStore()
        let oauth = FakeTokenService()
        let manager = Self.manager(store: store, oauth: oauth)
        let snapshot = try await manager.completeSignIn(try await manager.beginSignIn())
        let after = try await manager.signOut(accountId: try #require(snapshot.selected).id)
        #expect(after.accounts.isEmpty)
        #expect(!after.isSignedIn)
        #expect(oauth.revoked == ["renovacion-1"])
        #expect(try store.load() == nil)
        #expect(try await manager.authorizationHeaders() == nil)
    }

    @Test func revokedSessionIsDropped() async throws {
        let store = MemoryCredentialStore()
        let first = Self.manager(store: store)
        _ = try await first.completeSignIn(try await first.beginSignIn())

        let oauth = FakeTokenService()
        oauth.refreshError = .revoked
        let manager = Self.manager(store: store, oauth: oauth)
        await #expect(throws: AuthError.revoked) { try await manager.authorizationHeaders() }
        #expect(try await manager.load().isSignedIn == false)
        #expect(try store.load() == nil)
    }

    @Test func updatesStreamReportsChanges() async throws {
        let manager = Self.manager()
        var iterator = manager.updates().makeAsyncIterator()
        #expect(await iterator.next()?.isSignedIn == false)
        _ = try await manager.completeSignIn(try await manager.beginSignIn())
        #expect(await iterator.next()?.isSignedIn == true)
    }

    // MARK: - Tiempo visto

    static let tracking = WatchTimeTracker.Tracking(
        videoId: "aqz-KE-bpKQ", lengthSeconds: 600,
        playbackBase: "https://s.youtube.com/api/stats/playback?cl=1&docid=aqz-KE-bpKQ&ei=EI&plid=PL&el=detailpage&len=600&of=OF&vm=VM%2B%2F%3D",
        watchtimeBase: "https://s.youtube.com/api/stats/watchtime?cl=1&docid=aqz-KE-bpKQ&ei=EI&plid=PL&el=detailpage&len=600&of=OF&vm=VM%2B%2F%3D",
        cpn: "CPNCPNCPNCPNCPN1", accountKey: "principal", startedAt: Date().addingTimeInterval(-90))

    @Test func watchTimePlanFollowsSmartTube() async throws {
        let tracker = WatchTimeTracker()
        // Primer reporte antes de 3 min: registro nuevo desde 0 y tramo 0 → 90.
        let first = await tracker.plan(Self.tracking, position: 90)
        #expect(first.map(\.path) == ["/api/stats/playback", "/api/stats/watchtime"])
        let watch = try #require(URLComponents(url: first[1], resolvingAgainstBaseURL: false))
        #expect(watch.value("st") == "0.000")
        #expect(watch.value("et") == "90.000")
        #expect(watch.value("cmt") == "90.000")
        #expect(watch.value("len") == "600.000")
        #expect(watch.value("ver") == "2")
        #expect(watch.value("cpn") == "CPNCPNCPNCPNCPN1")
        #expect(Double(watch.value("rt") ?? "") ?? 0 >= 89)
        // Se conservan los parámetros de YouTube (plid, el, vm con `+` y `/` escapados).
        #expect(watch.value("plid") == "PL")
        #expect(watch.value("el") == "detailpage")
        #expect(first[1].absoluteString.contains("vm=VM%2B%2F%3D"))
        #expect(first[1].host == "s.youtube.com")

        // Después de 3 min, el primer registro empieza donde se está.
        #expect(try #require(URLComponents(url: await tracker.plan(Self.tracking, position: 400)[1], resolvingAgainstBaseURL: false)).value("st") == "400.000")

        // Casi al final (queda < 5 %): las variantes con final=1.
        let end = await tracker.plan(Self.tracking, position: 590)
        #expect(end.allSatisfy { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.value("final") == "1" })
    }

    @Test func trackingParamsFromPlayer() throws {
        let player = #"""
        {"videoDetails":{"lengthSeconds":"634"},"playbackTracking":{"videostatsPlaybackUrl":{"baseUrl":"https://s.youtube.com/api/stats/playback?cl=1&docid=aqz-KE-bpKQ&ei=EVENTO"},"videostatsWatchtimeUrl":{"baseUrl":"https://s.youtube.com/api/stats/watchtime?cl=1&docid=aqz-KE-bpKQ&ei=EVENTO&vm=CAEQ%2Bx&of=OFPARAM&len=634"}}}
        """#
        let tracking = try #require(WatchTimeTracker.tracking(fromPlayer: Data(player.utf8), videoId: "aqz-KE-bpKQ", accountKey: "principal"))
        #expect(tracking.lengthSeconds == 634)
        #expect(tracking.playbackBase.contains("/api/stats/playback"))
        #expect(tracking.watchtimeBase.contains("of=OFPARAM"))
        #expect(WatchTimeTracker.tracking(fromPlayer: Data("{}".utf8), videoId: "x", accountKey: "p") == nil)
    }
}

/// Pantallas con cuenta sobre respuestas reales de TV grabadas con `ytkit record-account` (anonimizadas).
@Suite struct SignedInPageTests {
    @Test func subscriptionsUseTheSelectedTabAndMergeRows() throws {
        // TV manda ~120 pestañas (Todos y una por canal); solo cuenta la elegida.
        let page = try Fixture.page("subs-tv.json", kind: .subscriptions).mergingUntitledRows(title: "Más recientes")
        // "Más relevantes", las tandas de tres juntas en "Más recientes" y los Shorts.
        #expect(page.groups.count == 3)
        #expect(page.groups.first?.title != nil)
        #expect(page.groups[1].title == "Más recientes")
        #expect(page.groups[1].items.count == 15)
        #expect(page.groups.last?.isShorts == true)
        #expect(page.itemCount >= 20)
        #expect(page.continuation != nil)
        // "Ocultar" (primer token del menú de cada tarjeta).
        #expect(page.groups.flatMap(\.items).allSatisfy { $0.feedbackToken != nil })
    }

    @Test func historyHasProgress() throws {
        let page = try Fixture.page("history-tv.json", kind: .history)
        let items = page.groups.flatMap(\.items)
        #expect(items.count >= 10)
        #expect(items.allSatisfy { $0.kind == .video && $0.percentWatched != nil })
        #expect(items.contains { $0.startTimeSeconds != nil })
        #expect(items.allSatisfy { $0.feedbackToken != nil })   // "Quitar del historial"
    }

    @Test func libraryHasWatchLaterAndLiked() throws {
        let ids = try Fixture.page("library-tv.json", kind: .library).groups.flatMap(\.items).compactMap(\.playlistId)
        #expect(ids.contains("WL"))
        #expect(ids.contains("LL"))
    }

    @Test func watchLaterIsAPlaylist() throws {
        let page = try Fixture.page("watchlater-tv.json")
        #expect(page.itemCount >= 5)
        #expect(page.groups.flatMap(\.items).allSatisfy { $0.videoId != nil })
    }

    @Test func signedInHomeHasMenuPanels() throws {
        let page = try Fixture.page("home-signed-tv.json", kind: .home)
        #expect(!page.isEmpty)
        #expect(page.groups.flatMap(\.items).contains { $0.menuPanel != nil })
    }

    @Test func panelGivesNotInterestedFirst() throws {
        let tokens = FeedbackTokens.all(in: try Fixture.data("cuenta/panel-tv.json"))
        // "No me interesa" directo; el de "No recomendar el canal" va dentro de una confirmación y no cuenta.
        #expect(tokens.count == 1)
    }

    @Test func playlistInfo() throws {
        let lists = try PlaylistInfoParser.playlists(from: try Fixture.data("cuenta/plinfo-tv.json"))
        let watchLater = try #require(lists.first { $0.id == "WL" })
        #expect(!watchLater.title.isEmpty)
        #expect(watchLater.containsVideo == false)   // NONE
    }

    @Test func accountStateFromSignedInNext() throws {
        var metadata = try Fixture.metadata("next-signed-tv.json")
        WatchNextAccountState.apply(try Fixture.data("next-signed-tv.json"), to: &metadata)
        #expect(metadata.likeStatus == .indifferent)
        #expect(metadata.isSubscribed == false)
        #expect(metadata.channelId == "UC8butISFwT-Wl7EV0hUK0BQ")
    }

    @Test func channelSubscriptionFromTVHeader() throws {
        // `subscriptionState(channelId:)` lee el botón de la cabecera del canal de TV.
        var probe = MediaItemMetadata(videoId: "", surface: .tv)
        probe.channelId = "UCX6OQ3DkcsbYNE6H8uQQuVA"
        WatchNextAccountState.apply(try Fixture.data("channel-tv.json"), to: &probe)
        #expect(probe.isSubscribed == false)
    }

    @Test func accountStateShapes() throws {
        // WEB: likeStatusEntity y subscribeButtonRenderer con params; TV: likeButtonRenderer.
        let web = #"{"a":{"likeStatusEntity":{"likeStatus":"LIKE"}},"b":{"subscribeButtonRenderer":{"subscribed":true,"channelId":"UCx","onSubscribeEndpoints":[{"subscribeEndpoint":{"params":"EgIIAxgA%3D"}}]}}}"#
        var meta = MediaItemMetadata(videoId: "v", surface: .web)
        WatchNextAccountState.apply(Data(web.utf8), to: &meta)
        #expect(meta.likeStatus == .like)
        #expect(meta.isSubscribed == true)
        #expect(meta.subscribeParams == "EgIIAxgA=")
        #expect(meta.channelId == "UCx")
        let tv = #"{"transportControls":{"likeButtonRenderer":{"likeStatus":"DISLIKE"}}}"#
        var other = MediaItemMetadata(videoId: "v", surface: .tv)
        WatchNextAccountState.apply(Data(tv.utf8), to: &other)
        #expect(other.likeStatus == .dislike)
        #expect(other.isSubscribed == nil)
    }

    @Test func mergingUntitledRowsKeepsTitledOnes() {
        func row(_ title: String?, _ n: Int) -> MediaGroup {
            MediaGroup(kind: .subscriptions, title: title, items: (0..<n).map { MediaItem(kind: .video, title: "\($0)", renderer: "t") },
                       renderer: "shelfRenderer")
        }
        let page = BrowsePage(groups: [row("Más relevantes", 5), row(nil, 3), row(nil, 3), row("Otra", 2), row(nil, 1)], surface: .tv)
        let merged = page.mergingUntitledRows(title: "Más recientes")
        #expect(merged.groups.map(\.title) == ["Más relevantes", "Más recientes", "Otra", "Más recientes"])
        #expect(merged.groups.map(\.items.count) == [5, 6, 2, 1])
    }
}

/// Ninguna respuesta grabada lleva credenciales ni datos personales (las de cuenta se graban anonimizadas con
/// `ytkit record-account`).
@Suite struct FixturePrivacyTests {
    static var allFiles: [URL] {
        let enumerator = FileManager.default.enumerator(at: Fixture.directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { ["json", "txt"].contains($0.pathExtension) }
    }

    static let patterns = [
        #"ya29\.[A-Za-z0-9_-]{10,}"#,                      // access token de Google
        #"1//0[A-Za-z0-9_-]{10,}"#,                        // refresh token de Google
        #"Bearer [A-Za-z0-9._-]{10,}"#,
        #""(access|refresh)_token""#,
        #""(datasyncId|visitorData|delegatedSessionId)""#,
        // Identificadores de la cuenta en accounts_list: solo valen los de prueba.
        #""(obfuscatedGaiaId|clientCacheKey|datasyncIdToken|pageId)":"(?!(TOKEN|ID)_DE_PRUEBA|0+[0-9]")"#,
    ]
    /// En las grabadas con cuenta, además, ningún correo que no sea de example.com (las anónimas traen correos públicos
    /// de negocios en las descripciones de los canales).
    static let email = #"[A-Za-z0-9._%+-]+@(?!example\.com)[A-Za-z0-9-]+\.(com|net|org|mx|es)\b"#
    static let accountPrefixes = ["subs-", "history-", "library-", "watchlater-", "next-signed-"]

    static func isAccountFixture(_ file: URL) -> Bool {
        file.deletingLastPathComponent().lastPathComponent == "cuenta"
            || accountPrefixes.contains { file.lastPathComponent.hasPrefix($0) }
    }

    @Test func noCredentialsOrEmails() throws {
        #expect(!Self.allFiles.isEmpty)
        for file in Self.allFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in Self.patterns + (Self.isAccountFixture(file) ? [Self.email] : []) {
                #expect(text.range(of: pattern, options: .regularExpression) == nil, "\(file.lastPathComponent) coincide con \(pattern)")
            }
        }
    }
}

/// Un Llavero que tarda en responder (como cuando macOS espera el «Permitir» de la persona).
final class SlowCredentialStore: CredentialStore, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let vault: Vault?
    init(_ vault: Vault?) { self.vault = vault }
    func load() throws -> Vault? {
        _ = release.wait(timeout: .now() + 5)
        return vault
    }
    func save(_ vault: Vault) throws {}
    func delete() throws {}
}

@Suite struct KeychainWaitTests {
    /// El catálogo no espera al Llavero: mientras se lee (el aviso del sistema sin responder), las páginas salen anónimas
    /// en lugar de quedarse colgadas; cuando la lectura termina, la sesión ya cuenta.
    @Test func catalogDoesNotWaitForTheKeychain() async throws {
        var vault = Vault()
        vault.credentials = [StoredCredential(id: "c1", refreshToken: "REFRESH_DE_PRUEBA")]
        vault.accounts = [Account(credentialId: "c1", name: "Persona", pageId: nil, hasChannel: true)]
        vault.selectedAccountId = vault.accounts[0].id
        let store = SlowCredentialStore(vault)
        let manager = AccountManager(store: store, oauth: FakeTokenService()) { _ in Data() }
        let service = try YouTubeService(session: manager)
        #expect(manager.knownSignedIn == nil)

        let reading = Task { try await manager.load() } // el actor queda ocupado leyendo
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        let signedIn = await service.api.isSignedIn
        let headers = try await service.api.authorizationHeaders(.session, surface: .tv)
        #expect(!signedIn && headers.isEmpty)
        #expect(Date().timeIntervalSince(start) < 0.5)

        store.release.signal()
        _ = try await reading.value
        #expect(manager.knownSignedIn == true)
        #expect(await service.api.isSignedIn)
    }
}
