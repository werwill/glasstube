import Foundation
import Testing
import YTKit
@testable import Glasstube

/// Lógica de cuentas de la app, sin red ni Llavero.
@MainActor
@Suite struct AccountModelTests {
    static func account(_ session: String, _ name: String, pageId: String? = nil, byline: String? = nil) -> Account {
        var account = Account(credentialId: session, name: name, pageId: pageId, hasChannel: true)
        account.byline = byline
        return account
    }

    @Test func sessionsGroupAccountsWithThePersonalFirst() throws {
        let manager = try AccountManager(ephemeral: true)
        let model = AccountModel(manager: manager)
        let snapshot = AccountSnapshot(accounts: [
            Self.account("s1", "Marca", pageId: "1"), Self.account("s1", "Persona", byline: "persona@example.com"),
            Self.account("s2", "Otra", byline: "otra@example.com"),
        ], selected: nil)
        model.setSnapshotForTesting(snapshot)
        #expect(model.sessions.map { $0.map(\.name) } == [["Persona", "Marca"], ["Otra"]])
        #expect(!model.isSignedIn)
    }

    @Test func errorsAreReadable() {
        #expect(AccountModel.describe(AuthError.codeExpired) == "El código venció antes de autorizarlo.")
        #expect(AccountModel.describe(AuthError.revoked).hasPrefix("Google ya no acepta"))
        #expect(AccountModel.describe(URLError(.notConnectedToInternet)).hasPrefix("Sin conexión"))
    }

    @Test func kindLabels() {
        #expect(Self.account("s", "A").kindLabel == "Cuenta personal")
        #expect(Self.account("s", "B", pageId: "9").kindLabel == "Cuenta de marca")
        #expect(Self.account("s", "A", byline: "a@example.com").displayName == "A")
    }

    @Test func libraryScopes() {
        #expect(LibraryScope.allCases.map(\.title) == ["YouTube", "Esta Mac"])
        #expect(LibraryScope(rawValue: "mac") == .mac)
    }

    @Test func browseSourcesForAccountPages() {
        #expect(BrowseSource.subscriptions.title == "Suscripciones")
        #expect(BrowseSource.history.title == "Historial")
        #expect(BrowseSource.library.title == "Playlists")
        #expect(!BrowseSource.history.isSearch)
    }
}
