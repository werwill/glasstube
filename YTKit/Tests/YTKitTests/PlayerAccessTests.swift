import Foundation
import Testing
@testable import YTKit

/// El player de SABR con la cuenta y el LOGIN_REQUIRED («Inicia sesión para confirmar que no eres un bot»).
@Suite struct PlayerAccessTests {
    @Test func loginRequiredResponsesNeedSignIn() throws {
        let simulated = try JSONDecoder().decode(PlayerResponse.self, from: Data(SabrSession.simulatedBotCheck.utf8))
        #expect(simulated.playabilityStatus?.status == "LOGIN_REQUIRED")
        // Un video privado también llega como LOGIN_REQUIRED (visto el 16-oct-2026).
        let privateVideo = try Fixture.decode(PlayerResponse.self, """
            {"playabilityStatus": {"status": "LOGIN_REQUIRED", "reason": "Este video es privado",
             "messages": ["Este video es privado. Accede para verificar que puedes verlo."]}}
            """)
        let error = SabrUnplayableError(status: privateVideo.playabilityStatus?.status ?? "?",
                                        reason: privateVideo.playabilityStatus?.reason, signedIn: false)
        #expect(error.needsSignIn)
        #expect(error.description == "player: LOGIN_REQUIRED Este video es privado")
        #expect(!SabrUnplayableError(status: "UNPLAYABLE", reason: nil, signedIn: true).needsSignIn)
    }

    /// Con sesión, el player de TV va con la cuenta; mientras el Llavero no se ha leído va anónimo sin esperar, y con un
    /// cliente que no es de TV, nunca (la sesión es de la app de TV).
    @Test func sabrPlayerUsesTheAccountOnlyWhenKnown() async throws {
        var vault = Vault()
        vault.credentials = [StoredCredential(id: "c1", refreshToken: "REFRESH_DE_PRUEBA")]
        vault.accounts = [Account(credentialId: "c1", name: "Persona", pageId: nil, hasChannel: true)]
        vault.selectedAccountId = vault.accounts[0].id
        let store = SlowCredentialStore(vault)
        let manager = AccountManager(store: store, oauth: FakeTokenService()) { _ in Data() }
        let catalog = try ClientCatalog.load()
        let tv = try #require(catalog.profile("TV"))
        let web = try #require(catalog.profile("WEB"))
        let session = SabrSession(videoId: "aqz-KE-bpKQ", client: tv, options: SabrOptions(), poTokenSource: nil)
        session.account = manager

        let reading = Task { try await manager.load() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        #expect(await session.accountHeaders().isEmpty)
        #expect(Date().timeIntervalSince(start) < 0.5)

        store.release.signal()
        _ = try await reading.value
        #expect(await session.accountHeaders()["Authorization"] != nil)

        let webSession = SabrSession(videoId: "aqz-KE-bpKQ", client: web, options: SabrOptions(), poTokenSource: nil)
        webSession.account = manager
        #expect(await webSession.accountHeaders().isEmpty)
    }
}
