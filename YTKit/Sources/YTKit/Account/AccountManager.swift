import Foundation

/// Sesiones y cuentas de YouTube: `YouTubeSignInService` + `YouTubeAccountManager` de SmartTube.
///
/// - Inicio de sesión por código (`beginSignIn` → mostrar `DeviceCode.userCode` → `completeSignIn`).
/// - Varias sesiones de Google y, en cada una, la cuenta personal y las de marca (`accounts_list`); se elige una con
///   `select` y las peticiones van con su `X-Goog-Pageid`.
/// - El access token se renueva solo: dura una hora y se pide otro cinco minutos antes de que venza (SmartTube lo
///   renueva cada hora, `TOKEN_REFRESH_PERIOD_MS`). Vive solo en memoria.
/// - Cerrar sesión revoca el refresh token en Google y lo borra del Llavero.
public actor AccountManager: SignInService {
    /// Margen antes del vencimiento del access token para pedir otro.
    static let refreshMargin: TimeInterval = 5 * 60

    struct AccessToken: Sendable {
        let header: String
        let expiresAt: Date
    }

    /// `accounts_list` con un `Authorization` dado (inyectable en las pruebas).
    typealias AccountsListLoader = @Sendable (_ authorization: String) async throws -> Data

    let store: CredentialStore
    let oauth: TokenService
    let loadAccountsList: AccountsListLoader

    private var vault = Vault()
    private var loaded = false
    private var tokens: [String: AccessToken] = [:]
    private var refreshing: [String: Task<AccessToken, Error>] = [:]
    private var observers: [UUID: AsyncStream<AccountSnapshot>.Continuation] = [:]
    /// Lo último que se supo de la sesión, legible sin pasar por el actor (ver `knownSignedIn`).
    nonisolated let known = KnownSessionState()

    /// Cuentas guardadas en el Llavero de inicio de sesión. `ephemeral`: sin Llavero, lo que dure el proceso (pruebas
    /// automáticas: un binario recién compilado haría que macOS pidiera permiso para leerlo); `simulatedReadDelay`, con
    /// `ephemeral`, hace que la lectura tarde esos segundos, como cuando macOS espera el «Permitir» de la persona.
    public init(catalog: ClientCatalog? = nil, locale: CatalogLocale = .current, ephemeral: Bool = false,
                simulatedReadDelay: TimeInterval = 0) throws {
        let api = CatalogAPI(catalog: try catalog ?? ClientCatalog.load(), locale: locale)
        let store: CredentialStore = ephemeral ? MemoryCredentialStore(readDelay: simulatedReadDelay) : CredentialStores.platformDefault()
        self.init(store: store, oauth: OAuthClient()) { authorization in
            try await api.post("account/accounts_list", surface: .tv, [
                "accountReadMask": ["returnOwner": true, "returnBrandAccounts": true, "returnPersonaAccounts": false],
            ], auth: .headers(["Authorization": authorization]))
        }
    }

    init(store: CredentialStore, oauth: TokenService, accountsList: @escaping AccountsListLoader) {
        self.store = store
        self.oauth = oauth
        loadAccountsList = accountsList
    }

    // MARK: - Estado

    /// Lee el Llavero (la primera vez). Puede pedir permiso al sistema si el binario cambió desde que se guardó.
    @discardableResult
    public func load() throws -> AccountSnapshot {
        if !loaded {
            vault = try store.load() ?? Vault()
            loaded = true
            fixSelection()
            known.update(signedIn: snapshot.isSignedIn)
        }
        return snapshot
    }

    /// Si hay una cuenta elegida, sin esperar: nil mientras el Llavero no se ha leído. Leerlo puede quedar esperando el
    /// permiso del sistema («Glasstube quiere usar información confidencial…») después de cada compilación, y mientras
    /// tanto el actor está ocupado: preguntarle a él dejaba el Inicio en «Cargando…» hasta que alguien respondiera.
    public nonisolated var knownSignedIn: Bool? { known.signedIn }

    public var snapshot: AccountSnapshot {
        AccountSnapshot(accounts: vault.accounts, selected: vault.accounts.first { $0.id == vault.selectedAccountId })
    }

    public var isSignedIn: Bool { (try? load())?.isSignedIn ?? false }

    /// Avisos de cambio (inicio y cierre de sesión, cambio de cuenta). Empieza con el estado actual.
    public nonisolated func updates() -> AsyncStream<AccountSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.addObserver(id, continuation) }
            continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        }
    }

    private func addObserver(_ id: UUID, _ continuation: AsyncStream<AccountSnapshot>.Continuation) {
        observers[id] = continuation
        continuation.yield((try? load()) ?? snapshot)
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() {
        let current = snapshot
        known.update(signedIn: current.isSignedIn)
        for continuation in observers.values { continuation.yield(current) }
    }

    private func persist() throws {
        if vault.credentials.isEmpty {
            try store.delete()
        } else {
            try store.save(vault)
        }
    }

    /// Si la elegida ya no existe, se elige la que se activó en youtube.com/activate o la primera (`fixSelectedAccount`).
    private func fixSelection() {
        guard !vault.accounts.contains(where: { $0.id == vault.selectedAccountId }) else { return }
        vault.selectedAccountId = (vault.accounts.first { $0.isActivated } ?? vault.accounts.first)?.id
    }

    // MARK: - Inicio de sesión

    /// Pide un código nuevo. Muéstrale `userCode` a la persona con `verificationURL` y llama a `completeSignIn`.
    public func beginSignIn() async throws -> DeviceCode {
        try load()
        if vault.deviceId == nil {
            vault.deviceId = UUID().uuidString
        }
        return try await oauth.requestDeviceCode(deviceId: vault.deviceId!)
    }

    /// Espera a que la persona autorice el código (sondea cada `interval` segundos; se cancela con la tarea), guarda la
    /// sesión en el Llavero y trae sus cuentas. Si es una sesión que ya estaba (la misma cuenta otra vez), la reemplaza.
    @discardableResult
    public func completeSignIn(_ code: DeviceCode) async throws -> AccountSnapshot {
        let grant = try await oauth.waitForGrant(code)
        guard let refreshToken = grant.refreshToken else { throw AuthError.rejected("sin refresh_token") }
        let credential = StoredCredential(id: UUID().uuidString, refreshToken: refreshToken)
        tokens[credential.id] = AccessToken(header: "\(grant.tokenType) \(grant.accessToken)",
                                            expiresAt: Date().addingTimeInterval(grant.expiresIn - Self.refreshMargin))
        let accounts = try await fetchAccounts(credential: credential)
        guard !accounts.isEmpty else { throw AuthError.rejected("accounts_list sin cuentas") }

        // La misma cuenta personal otra vez: la sesión vieja sobra (se revoca después de guardar la nueva).
        let owner = accounts.first { !$0.isBrand }
        let replaced = vault.credentials.filter { old in
            vault.accounts.contains { $0.credentialId == old.id && !$0.isBrand && $0.name == owner?.name && $0.byline == owner?.byline }
        }
        for old in replaced { drop(credentialId: old.id) }

        vault.credentials.append(credential)
        vault.accounts.append(contentsOf: accounts)
        vault.selectedAccountId = (accounts.first { $0.isActivated } ?? accounts[0]).id
        try persist()
        notify()
        for old in replaced { try? await oauth.revoke(old.refreshToken) }
        return snapshot
    }

    // MARK: - Cuentas

    public func select(accountId: String) throws -> AccountSnapshot {
        try load()
        guard vault.accounts.contains(where: { $0.id == accountId }), vault.selectedAccountId != accountId else { return snapshot }
        vault.selectedAccountId = accountId
        try persist()
        notify()
        return snapshot
    }

    /// Cierra la sesión de Google a la que pertenece la cuenta (con sus cuentas de marca): revoca el refresh token en
    /// Google y lo borra del Llavero. Si Google no responde, igual se borra aquí.
    @discardableResult
    public func signOut(accountId: String, revoke: Bool = true) async throws -> AccountSnapshot {
        try load()
        guard let credentialId = vault.accounts.first(where: { $0.id == accountId })?.credentialId,
              let credential = vault.credentials.first(where: { $0.id == credentialId }) else { return snapshot }
        drop(credentialId: credentialId)
        fixSelection()
        try persist()
        notify()
        if revoke { try? await oauth.revoke(credential.refreshToken) }
        return snapshot
    }

    /// Cierra todas las sesiones.
    @discardableResult
    public func signOutAll(revoke: Bool = true) async throws -> AccountSnapshot {
        try load()
        let credentials = vault.credentials
        vault.credentials = []
        vault.accounts = []
        vault.selectedAccountId = nil
        tokens = [:]
        try persist()
        notify()
        if revoke {
            for credential in credentials { try? await oauth.revoke(credential.refreshToken) }
        }
        return snapshot
    }

    private func drop(credentialId: String) {
        vault.credentials.removeAll { $0.id == credentialId }
        vault.accounts.removeAll { $0.credentialId == credentialId }
        tokens[credentialId] = nil
        refreshing[credentialId]?.cancel()
        refreshing[credentialId] = nil
    }

    /// Vuelve a pedir `accounts_list` de cada sesión (nombres, avatares y cuentas de marca nuevas): `syncStorage`.
    /// Las sesiones guardadas sin cuentas (por ejemplo, de una versión anterior) se completan aquí.
    @discardableResult
    public func refreshAccounts() async throws -> AccountSnapshot {
        try load()
        for credential in vault.credentials {
            let fresh: [Account]
            do {
                fresh = try await fetchAccounts(credential: credential)
            } catch AuthError.revoked {
                drop(credentialId: credential.id)
                continue
            }
            guard !fresh.isEmpty else { continue }
            let index = vault.accounts.firstIndex { $0.credentialId == credential.id } ?? vault.accounts.endIndex
            vault.accounts.removeAll { $0.credentialId == credential.id }
            vault.accounts.insert(contentsOf: fresh, at: min(index, vault.accounts.endIndex))
        }
        fixSelection()
        try persist()
        notify()
        return snapshot
    }

    private func fetchAccounts(credential: StoredCredential) async throws -> [Account] {
        let header = try await accessToken(for: credential).header
        let data = try await loadAccountsList(header)
        return try AccountsListParser.accounts(from: data, credentialId: credential.id)
    }

    // MARK: - Peticiones autenticadas

    /// Cabeceras de la cuenta elegida (`Authorization` y, en una cuenta de marca, `X-Goog-Pageid`), o nil sin sesión.
    /// Renueva el access token si va a vencer.
    public func authorizationHeaders() async throws -> [String: String]? {
        try load()
        guard let account = snapshot.selected,
              let credential = vault.credentials.first(where: { $0.id == account.credentialId }) else { return nil }
        let token: AccessToken
        do {
            token = try await accessToken(for: credential)
        } catch AuthError.revoked {
            drop(credentialId: credential.id)
            fixSelection()
            try? persist()
            notify()
            throw AuthError.revoked
        }
        var headers = ["Authorization": token.header]
        if let pageId = account.pageId { headers["X-Goog-Pageid"] = pageId }
        return headers
    }

    /// Olvida el access token en memoria (después de un 401) para que la próxima petición pida otro.
    public func invalidateAccessToken() {
        if let id = snapshot.selected?.credentialId { tokens[id] = nil }
    }

    private func accessToken(for credential: StoredCredential) async throws -> AccessToken {
        if let token = tokens[credential.id], token.expiresAt > Date() { return token }
        if let task = refreshing[credential.id] { return try await task.value }
        let oauth = oauth
        let refreshToken = credential.refreshToken
        let task = Task<AccessToken, Error> {
            let grant = try await oauth.refresh(refreshToken)
            return AccessToken(header: "\(grant.tokenType) \(grant.accessToken)",
                               expiresAt: Date().addingTimeInterval(grant.expiresIn - Self.refreshMargin))
        }
        refreshing[credential.id] = task
        defer { refreshing[credential.id] = nil }
        let token = try await task.value
        tokens[credential.id] = token
        return token
    }
}

/// Estado de la sesión que el catálogo puede leer desde cualquier hilo sin esperar al actor de cuentas.
final class KnownSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var signedIn: Bool? { lock.withLock { value } }

    func update(signedIn: Bool) { lock.withLock { value = signedIn } }
}
