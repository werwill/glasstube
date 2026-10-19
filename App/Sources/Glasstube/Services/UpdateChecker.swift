import AppKit
import Foundation
import Observation
import SwiftUI

/// Número de versión como `0.4.0`, `v1.2` o `0.5.0-beta.2` (el `tag_name` de GitHub o `CFBundleShortVersionString`).
/// Compara como SemVer: número por número (lo que falta cuenta como 0) y una versión con sufijo (`-beta.2`) va antes
/// que la misma sin sufijo.
nonisolated struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let numbers: [Int]
    /// El sufijo de prerrelease separado por puntos (`beta.2` → `["beta", "2"]`); vacío en una versión final.
    let prerelease: [String]

    init?(_ text: String) {
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

    var description: String {
        numbers.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    /// `1.0` y `1.0.0` son la misma versión.
    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
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
nonisolated struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool?
    let prerelease: Bool?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", draft, prerelease
    }
}

/// Una versión publicada mayor que la instalada.
nonisolated struct AvailableUpdate: Equatable, Sendable {
    let version: String
    let current: String
    /// La página de esa versión en GitHub (notas y descarga).
    let page: URL
}

/// Aviso de versiones nuevas, sin Sparkle ni instalador: al abrir la app, y como mucho una vez al día, pregunta a la API
/// pública de GitHub por la última versión publicada y, si es mayor que la instalada, muestra un aviso con «Descargar»
/// (abre la página de esa versión en el navegador) y «Ahora no» (vuelve a avisar en la siguiente consulta, al día
/// siguiente como pronto). Se apaga en Ajustes › General.
///
/// Es la única petición que hace por su cuenta: sin cookies, sin caché, sin cuenta y sin datos de la Mac ni del uso
/// (el `User-Agent` es solo «Glasstube», que GitHub exige). El repositorio sale del `Info.plist`
/// (`GlasstubeGitHubRepository`, que escribe `Scripts/package-app.sh`); sin él, como con `swift run`, no se consulta nada.
@Observable
final class UpdateChecker {
    enum Result: Equatable {
        case available(AvailableUpdate)
        case upToDate
        case failed
        /// Sin repositorio o sin versión en el `Info.plist` (compilación sin empaquetar).
        case unconfigured
    }

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    nonisolated static let interval: TimeInterval = 24 * 60 * 60
    nonisolated static let repositoryKey = "GlasstubeGitHubRepository"
    static let lastCheckKey = "updatesLastCheck"

    /// La versión nueva mientras el aviso está a la vista.
    private(set) var available: AvailableUpdate?
    private(set) var isChecking = false
    private(set) var lastCheck: Date?

    /// `dueño/repo` en GitHub.
    @ObservationIgnored let repository: String?
    @ObservationIgnored let currentVersion: String?
    @ObservationIgnored private let endpoint: URL?
    /// `-GTActualizacionesURL`: la consulta va a esa dirección (también `file://`) y no cuenta para el límite diario.
    @ObservationIgnored private let isOverridden: Bool
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let now: () -> Date

    init(repository: String?, currentVersion: String?, isEnabled: @escaping () -> Bool,
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
    convenience init(settings: AppSettings, bundle: Bundle = .main) {
        let override = UserDefaults.standard.string(forKey: "GTActualizacionesURL").flatMap(URL.init(string:))
        self.init(repository: bundle.object(forInfoDictionaryKey: Self.repositoryKey) as? String,
                  currentVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  isEnabled: { settings.checkForUpdates }, endpoint: override)
    }

    /// Sin cookies ni caché: la consulta no deja ni manda nada más que la propia petición.
    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    var isConfigured: Bool { endpoint != nil && currentVersion.flatMap(AppVersion.init) != nil }

    /// La página de versiones del repositorio (enlace en Ajustes).
    var releasesPage: URL? { repository.flatMap { URL(string: "https://github.com/\($0)/releases") } }

    /// Al abrir la app: consulta si el aviso está activado y pasó un día desde la última consulta.
    func checkIfDue() {
        guard isEnabled(), isConfigured else { return }
        if !isOverridden, let lastCheck, now().timeIntervalSince(lastCheck) < Self.interval { return }
        Task { await check() }
    }

    /// Consulta ahora (también «Buscar ahora» en Ajustes, aunque el aviso esté apagado).
    @discardableResult
    func check() async -> Result {
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
    nonisolated static func update(from release: GitHubRelease, current: String) -> AvailableUpdate? {
        guard release.draft != true, release.prerelease != true,
              let published = AppVersion(release.tagName), let installed = AppVersion(current),
              installed < published,
              ["https", "http"].contains(release.htmlURL.scheme?.lowercased() ?? "")
        else { return nil }
        return AvailableUpdate(version: published.description, current: installed.description, page: release.htmlURL)
    }

    /// `dueño/repo` con los caracteres que admite GitHub.
    nonisolated static func isValidRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.count == 2 && parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// «Descargar»: abre la página de la versión en el navegador.
    func download() {
        guard let available else { return }
        NSWorkspace.shared.open(available.page)
        self.available = nil
    }

    /// «Ahora no».
    func dismiss() { available = nil }
}

/// El aviso de versión nueva: una tarjeta de vidrio abajo a la derecha de la ventana (sin vidrio dentro: los botones son
/// cápsulas planas, como los de «A continuación»).
struct UpdateNotice: View {
    let update: AvailableUpdate
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Glasstube \(update.version) ya está disponible")
                    .font(.callout.weight(.semibold))
                Text("Tienes la \(update.current). YouTube cambia seguido y las versiones nuevas lo siguen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 270, alignment: .leading)
            HStack(spacing: 8) {
                Button { model.updates.dismiss() } label: {
                    Text("Ahora no")
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(.quaternary))
                        .contentShape(.capsule)
                }
                Button { model.updates.download() } label: {
                    Text("Descargar")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(.tint))
                        .contentShape(.capsule)
                }
            }
            .font(.callout.weight(.semibold))
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Glasstube \(update.version) ya está disponible")
    }
}
