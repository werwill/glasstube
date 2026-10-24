import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

/// Número de versión como `0.4.0`, `v1.2` o `0.5.0-beta.2` (el `tag_name` de GitHub o `CFBundleShortVersionString`).
/// Compara como SemVer: número por número (lo que falta cuenta como 0) y una versión con sufijo (`-beta.2`) va antes
/// que la misma sin sufijo.
public nonisolated struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    /// El sufijo de prerrelease separado por puntos (`beta.2` → `["beta", "2"]`); vacío en una versión final.
    public let prerelease: [String]

    public init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.first == "v" || core.first == "V" { core.removeFirst() }
        // Los metadatos de compilación (`+abc`) no cuentan para el orden.
        if let plus = core.firstIndex(of: "+") { core = String(core[..<plus]) }
        var suffix = ""
        if let dash = core.firstIndex(of: "-") {
            suffix = String(core[core.index(after: dash)...])
            core = String(core[..<dash])
        }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.numbers = numbers.compactMap { $0 }
        prerelease = suffix.isEmpty ? [] : suffix.split(separator: ".").map(String.init)
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    /// `1.0` y `1.0.0` son la misma versión.
    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x < y }
        }
        // Mismos números: la prerrelease va antes que la final; entre dos prerreleases, identificador por identificador
        // (los numéricos como números y antes que los de texto), y la más corta antes si todo lo demás coincide.
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// Lo que importa de `GET /repos/{dueño}/{repo}/releases/latest`.
public nonisolated struct GitHubRelease: Decodable, Sendable {
    public let tagName: String
    public let htmlURL: URL
    public let draft: Bool?
    public let prerelease: Bool?

    public init(tagName: String, htmlURL: URL, draft: Bool?, prerelease: Bool?) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.draft = draft
        self.prerelease = prerelease
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", draft, prerelease
    }
}

/// Una versión publicada mayor que la instalada.
public nonisolated struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let current: String
    /// La página de esa versión en GitHub (notas y descarga).
    public let page: URL

    public init(version: String, current: String, page: URL) {
        self.version = version
        self.current = current
        self.page = page
    }
}

/// Aviso de versiones nuevas, sin Sparkle ni instalador: al abrir la app, y como mucho una vez al día, pregunta a la API
/// pública de GitHub por la última versión publicada y, si es mayor que la instalada, muestra un aviso con «Descargar»
/// (abre la página de esa versión en el navegador) y «Ahora no» (vuelve a avisar en la siguiente consulta, al día
/// siguiente como pronto). Se apaga en Ajustes › General.
///
/// Es la única petición que hace por su cuenta: sin cookies, sin caché, sin cuenta y sin datos de la PC ni del uso
/// (el `User-Agent` es solo «Glasstube», que GitHub exige). El repositorio sale del `Info.plist`
/// (`GlasstubeGitHubRepository`, que escribe `Scripts/package-app.sh`); sin él, como con `swift run`, no se consulta nada.
/// En Windows no hay `Info.plist`: la app pasa el repositorio y la versión con `init(repository:currentVersion:…)`.
@Observable
public final class UpdateChecker {
    public enum Result: Equatable {
        case available(AvailableUpdate)
        case upToDate
        case failed
        /// Sin repositorio o sin versión en el `Info.plist` (compilación sin empaquetar).
        case unconfigured
    }

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public nonisolated static let interval: TimeInterval = 24 * 60 * 60
    public nonisolated static let repositoryKey = "GlasstubeGitHubRepository"
    public static let lastCheckKey = "updatesLastCheck"

    /// La versión nueva mientras el aviso está a la vista.
    public private(set) var available: AvailableUpdate?
    public private(set) var isChecking = false
    public private(set) var lastCheck: Date?

    /// `dueño/repo` en GitHub.
    @ObservationIgnored public let repository: String?
    @ObservationIgnored public let currentVersion: String?
    @ObservationIgnored private let endpoint: URL?
    /// `-GTActualizacionesURL`: la consulta va a esa dirección (también `file://`) y no cuenta para el límite diario.
    @ObservationIgnored private let isOverridden: Bool
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let now: () -> Date

    public init(repository: String?, currentVersion: String?, isEnabled: @escaping () -> Bool,
         defaults: UserDefaults = .standard, endpoint override: URL? = nil,
         fetch: @escaping Fetch = { try await UpdateChecker.session.data(for: $0) }, now: @escaping () -> Date = Date.init) {
        let repository = repository.flatMap { Self.isValidRepository($0) ? $0 : nil }
        self.repository = repository
        self.currentVersion = currentVersion
        endpoint = override ?? repository.flatMap { URL(string: "https://api.github.com/repos/\($0)/releases/latest") }
        isOverridden = override != nil
        self.isEnabled = isEnabled
        self.defaults = defaults
        self.fetch = fetch
        self.now = now
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    /// Con los datos del `Info.plist` de la app.
    public convenience init(settings: AppSettings, bundle: Bundle = .main) {
        let override = UserDefaults.standard.string(forKey: "GTActualizacionesURL").flatMap(URL.init(string:))
        self.init(repository: bundle.object(forInfoDictionaryKey: Self.repositoryKey) as? String,
                  currentVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  isEnabled: { settings.checkForUpdates }, endpoint: override)
    }

    /// Sin cookies ni caché: la consulta no deja ni manda nada más que la propia petición.
    public nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    public var isConfigured: Bool { endpoint != nil && currentVersion.flatMap(AppVersion.init) != nil }

    /// La página de versiones del repositorio (enlace en Ajustes).
    public var releasesPage: URL? { repository.flatMap { URL(string: "https://github.com/\($0)/releases") } }

    /// Al abrir la app: consulta si el aviso está activado y pasó un día desde la última consulta.
    public func checkIfDue() {
        guard isEnabled(), isConfigured else { return }
        if !isOverridden, let lastCheck, now().timeIntervalSince(lastCheck) < Self.interval { return }
        Task { await check() }
    }

    /// Consulta ahora (también «Buscar ahora» en Ajustes, aunque el aviso esté apagado).
    @discardableResult
    public func check() async -> Result {
        guard let endpoint, let currentVersion, isConfigured else { return .unconfigured }
        guard !isChecking else { return .failed }
        isChecking = true
        defer { isChecking = false }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Glasstube", forHTTPHeaderField: "User-Agent")
        let data: Data
        let status: Int
        do {
            let (body, response) = try await fetch(request)
            data = body
            // `file://` (respuestas simuladas) no trae estado HTTP.
            status = (response as? HTTPURLResponse)?.statusCode ?? 200
        } catch {
            // Sin conexión: se vuelve a intentar en el próximo arranque.
            return .failed
        }
        // GitHub contestó: cuenta para el límite diario aunque la respuesta no sirva (p. ej. 403 por exceso de consultas).
        if !isOverridden {
            lastCheck = now()
            defaults.set(lastCheck, forKey: Self.lastCheckKey)
        }
        // 404: el repositorio todavía no tiene versiones publicadas.
        if status == 404 { return .upToDate }
        guard (200..<300).contains(status), let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            return .failed
        }
        guard let update = Self.update(from: release, current: currentVersion) else { return .upToDate }
        available = update
        return .available(update)
    }

    /// La versión publicada si es mayor que la instalada (ni borradores ni prerreleases, aunque `releases/latest` ya los
    /// deja fuera).
    public nonisolated static func update(from release: GitHubRelease, current: String) -> AvailableUpdate? {
        guard release.draft != true, release.prerelease != true,
              let published = AppVersion(release.tagName), let installed = AppVersion(current),
              installed < published,
              ["https", "http"].contains(release.htmlURL.scheme?.lowercased() ?? "")
        else { return nil }
        return AvailableUpdate(version: published.description, current: installed.description, page: release.htmlURL)
    }

    /// `dueño/repo` con los caracteres que admite GitHub.
    public nonisolated static func isValidRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.count == 2 && parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// «Descargar»: devuelve la página de la versión para que la interfaz la abra en el navegador (en Windows,
    /// `Launcher.LaunchUriAsync`) y cierra el aviso.
    public func download() -> URL? {
        guard let available else { return nil }
        self.available = nil
        return available.page
    }

    /// «Ahora no».
    public func dismiss() { available = nil }
}
