import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import GlasstubeCore

/// El aviso de versiones nuevas: la comparación de versiones y la consulta a GitHub con respuestas simuladas, sin red.
@MainActor
@Suite struct UpdateCheckerTests {
    private func version(_ text: String) throws -> AppVersion { try #require(AppVersion(text)) }

    @Test func versionsCompareNumberByNumber() throws {
        #expect(try version("0.4.0") < version("0.5.0"))
        #expect(try version("0.4.0") < version("0.4.1"))
        #expect(try version("0.9.9") < version("0.10.0"))  // no es orden alfabético
        #expect(try version("0.4.9") < version("1.0"))
        #expect(try !(version("0.5.0") < version("0.4.12")))
        #expect(try version("v1.2.3") == version("1.2.3"))
        #expect(try version("1.0") == version("1.0.0"))
        #expect(try version(" 2.0.0 ").description == "2.0.0")
        #expect(try version("1.0.0+20261018") == version("1.0.0"))
    }

    @Test func prereleasesGoBeforeTheFinalVersion() throws {
        #expect(try version("0.5.0-beta") < version("0.5.0"))
        #expect(try version("0.5.0-beta.2") < version("0.5.0-beta.10"))
        #expect(try version("0.5.0-alpha") < version("0.5.0-beta"))
        #expect(try version("0.5.0-1") < version("0.5.0-beta"))
        #expect(try version("0.5.0-beta") < version("0.5.0-beta.1"))
        #expect(try version("0.4.0") < version("0.5.0-beta"))
        #expect(try version("0.5.0-beta.2").description == "0.5.0-beta.2")
    }

    @Test func invalidVersionsAreRejected() {
        for text in ["", "v", "latest", "1..2", "1.2.x", "nightly-2026", "1.2.3.4.5", "-1.0"] {
            #expect(AppVersion(text) == nil, "\(text)")
        }
    }

    @Test func onlyANewerFinalReleaseIsAnUpdate() throws {
        let page = try #require(URL(string: "https://github.com/dueno/repo/releases/tag/v0.5.0"))
        let newer = GitHubRelease(tagName: "v0.5.0", htmlURL: page, draft: false, prerelease: false)
        #expect(UpdateChecker.update(from: newer, current: "0.4.0") == AvailableUpdate(version: "0.5.0", current: "0.4.0", page: page))
        #expect(UpdateChecker.update(from: newer, current: "0.5.0") == nil)
        #expect(UpdateChecker.update(from: newer, current: "0.6.0") == nil)
        #expect(UpdateChecker.update(from: GitHubRelease(tagName: "v0.5.0", htmlURL: page, draft: false, prerelease: true), current: "0.4.0") == nil)
        #expect(UpdateChecker.update(from: GitHubRelease(tagName: "v0.5.0", htmlURL: page, draft: true, prerelease: nil), current: "0.4.0") == nil)
        #expect(UpdateChecker.update(from: GitHubRelease(tagName: "nightly", htmlURL: page, draft: nil, prerelease: nil), current: "0.4.0") == nil)
        // Solo una página web: nada de `file:` ni otros esquemas para «Descargar».
        let local = try #require(URL(string: "file:///Applications/Calculator.app"))
        #expect(UpdateChecker.update(from: GitHubRelease(tagName: "v9.0.0", htmlURL: local, draft: nil, prerelease: nil), current: "0.4.0") == nil)
    }

    @Test func repositoryNames() {
        #expect(UpdateChecker.isValidRepository("werwill/glasstube"))
        #expect(UpdateChecker.isValidRepository("dueno-1/mi.repo_2"))
        for bad in ["", "glasstube", "a/b/c", "/repo", "dueno/", "dueno/..", "dueno/repo?x=1", "due no/repo"] {
            #expect(!UpdateChecker.isValidRepository(bad), "\(bad)")
        }
    }

    // MARK: - Consulta con respuestas simuladas

    /// Respuesta de `releases/latest` recortada (los campos que importan y algunos más, como la real).
    nonisolated static let latestJSON = """
    {"url":"https://api.github.com/repos/dueno/repo/releases/1","html_url":"https://github.com/dueno/repo/releases/tag/v0.5.0",
     "id":1,"tag_name":"v0.5.0","name":"Glasstube 0.5.0","draft":false,"prerelease":false,
     "published_at":"2026-11-01T12:00:00Z","assets":[{"name":"Glasstube-0.5.0.dmg","size":30000000}]}
    """

    /// Guarda las peticiones y contesta con lo que se le diga.
    final class FakeGitHub: @unchecked Sendable {
        var requests: [URLRequest] = []
        var status = 200
        var body = Data(UpdateCheckerTests.latestJSON.utf8)
        var error: Error?

        func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            if let error { throw error }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (body, response)
        }
    }

    private func makeChecker(_ github: FakeGitHub, current: String = "0.4.0", enabled: Bool = true,
                             defaults: UserDefaults, now: @escaping () -> Date = Date.init) -> UpdateChecker {
        UpdateChecker(repository: "dueno/repo", currentVersion: current, isEnabled: { enabled }, defaults: defaults,
                      fetch: { try github.fetch($0) }, now: now)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "glasstube-tests-updates-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func newerReleaseShowsTheNotice() async throws {
        let github = FakeGitHub()
        let checker = makeChecker(github, defaults: freshDefaults())
        let result = await checker.check()
        let page = try #require(URL(string: "https://github.com/dueno/repo/releases/tag/v0.5.0"))
        #expect(result == .available(AvailableUpdate(version: "0.5.0", current: "0.4.0", page: page)))
        #expect(checker.available?.version == "0.5.0")
        // La única petición: la API pública, sin cookies ni nada de la cuenta.
        let request = try #require(github.requests.first)
        #expect(github.requests.count == 1)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/dueno/repo/releases/latest")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Glasstube")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        checker.dismiss()
        #expect(checker.available == nil)
    }

    @Test func sameOrOlderReleaseShowsNothing() async {
        let github = FakeGitHub()
        let checker = makeChecker(github, current: "0.5.0", defaults: freshDefaults())
        #expect(await checker.check() == .upToDate)
        #expect(checker.available == nil)
    }

    @Test func noReleasesYetOrBadResponses() async {
        let github = FakeGitHub()
        let checker = makeChecker(github, defaults: freshDefaults())
        github.status = 404
        #expect(await checker.check() == .upToDate)
        github.status = 403  // límite de consultas de GitHub
        #expect(await checker.check() == .failed)
        github.status = 200
        github.body = Data("<html>no es JSON</html>".utf8)
        #expect(await checker.check() == .failed)
        github.error = URLError(.notConnectedToInternet)
        #expect(await checker.check() == .failed)
        #expect(checker.available == nil)
    }

    @Test func checksAtMostOnceADay() async throws {
        let github = FakeGitHub()
        let defaults = freshDefaults()
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        let checker = makeChecker(github, defaults: defaults, now: { clock })
        checker.checkIfDue()
        try await waitUntil { github.requests.count == 1 && !checker.isChecking }
        #expect(checker.available?.version == "0.5.0")
        #expect(defaults.object(forKey: UpdateChecker.lastCheckKey) as? Date == clock)

        // Al volver a abrir el mismo día no se consulta; al día siguiente sí.
        clock += 6 * 60 * 60
        let sameDay = makeChecker(github, defaults: defaults, now: { clock })
        sameDay.checkIfDue()
        try await Task.sleep(for: .milliseconds(50))
        #expect(github.requests.count == 1)
        clock += 20 * 60 * 60
        let nextDay = makeChecker(github, defaults: defaults, now: { clock })
        nextDay.checkIfDue()
        try await waitUntil { github.requests.count == 2 && !nextDay.isChecking }
    }

    @Test func failedConnectionRetriesOnTheNextLaunch() async throws {
        let github = FakeGitHub()
        github.error = URLError(.notConnectedToInternet)
        let defaults = freshDefaults()
        let checker = makeChecker(github, defaults: defaults)
        #expect(await checker.check() == .failed)
        #expect(defaults.object(forKey: UpdateChecker.lastCheckKey) == nil)
    }

    @Test func turnedOffOrUnpackagedDoesNotAsk() async throws {
        let github = FakeGitHub()
        makeChecker(github, enabled: false, defaults: freshDefaults()).checkIfDue()
        // Sin versión ni repositorio en el Info.plist (`swift run`, pruebas): nada.
        let unpackaged = UpdateChecker(repository: nil, currentVersion: nil, isEnabled: { true }, defaults: freshDefaults(),
                                       fetch: { try github.fetch($0) })
        unpackaged.checkIfDue()
        #expect(!unpackaged.isConfigured)
        #expect(await unpackaged.check() == .unconfigured)
        let badRepository = UpdateChecker(repository: "no es un repo", currentVersion: "0.4.0", isEnabled: { true },
                                          defaults: freshDefaults(), fetch: { try github.fetch($0) })
        #expect(!badRepository.isConfigured)
        try await Task.sleep(for: .milliseconds(50))
        #expect(github.requests.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
