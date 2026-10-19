import Foundation
import Security

// Dónde se guardan las sesiones. Todo lo de la cuenta (refresh tokens, cuentas de marca y la elegida) va en un solo
// elemento del Llavero, nunca en UserDefaults ni en archivos (SmartTube lo guardaba en SharedPreferences:
// `YouTubeAccountManager.persistAccounts`). Los access tokens solo viven en memoria.

/// Una sesión de Google: lo que devuelve un inicio de sesión por código. Varias cuentas (la personal y las de marca)
/// comparten la misma sesión.
struct StoredCredential: Codable, Sendable, Equatable {
    var id: String
    var refreshToken: String
}

/// Lo que se guarda en el Llavero.
struct Vault: Codable, Sendable, Equatable {
    var version = 1
    var credentials: [StoredCredential] = []
    var accounts: [Account] = []
    var selectedAccountId: String?
    /// `device_id` de esta instalación para `device/code` (SmartTube guarda un UUID en `MediaServiceData`).
    var deviceId: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        credentials = try c.decodeIfPresent([StoredCredential].self, forKey: .credentials) ?? []
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        selectedAccountId = try c.decodeIfPresent(String.self, forKey: .selectedAccountId)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
    }
}

/// Almacén de la bóveda: el Llavero en la app, memoria en las pruebas.
protocol CredentialStore: Sendable {
    func load() throws -> Vault?
    func save(_ vault: Vault) throws
    func delete() throws
}

public struct KeychainError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error"
        return "Llavero: \(message) (\(status))"
    }
}

/// Elemento genérico del Llavero de inicio de sesión (`kSecClassGenericPassword`), servicio `mx.glasstube.cuentas`.
///
/// Firmada ad hoc, macOS identifica a quien lee el elemento por el hash de su binario: después de recompilar, la
/// primera lectura pide permiso ("Glasstube quiere usar información confidencial…"). Firmada con un certificado propio
/// («Glasstube Desarrollo», ver App/Scripts/package-app.sh), la identidad es el certificado y el «Permitir siempre» vale
/// para las compilaciones siguientes.
struct KeychainStore: CredentialStore {
    static let defaultService = "mx.glasstube.cuentas"
    let service: String
    let account = "boveda"

    init(service: String = KeychainStore.defaultService) { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> Vault? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Vault.self, from: data)
    }

    func save(_ vault: Vault) throws {
        let data = try JSONEncoder().encode(vault)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Glasstube: cuentas de YouTube"
            add[kSecAttrDescription as String] = "Sesiones de la app de TV de YouTube"
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Bóveda en memoria (pruebas y `ytkit` con `--sin-llavero`).
final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var vault: Vault?
    private let readDelay: TimeInterval

    init(_ vault: Vault? = nil, readDelay: TimeInterval = 0) {
        self.vault = vault
        self.readDelay = readDelay
    }

    func load() throws -> Vault? {
        if readDelay > 0 { Thread.sleep(forTimeInterval: readDelay) }
        return lock.withLock { vault }
    }
    func save(_ vault: Vault) throws { lock.withLock { self.vault = vault } }
    func delete() throws { lock.withLock { vault = nil } }
}
