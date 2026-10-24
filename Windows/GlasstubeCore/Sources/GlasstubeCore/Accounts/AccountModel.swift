import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import YTKit

/// Cuentas de YouTube en la app (el `SignInService` de SmartTube sobre `AccountManager` de YTKit). Los tokens viven en
/// el Administrador de credenciales de Windows y en YTKit; aquí solo hay nombres, avatares y el estado del inicio de sesión. Nada de esto se registra.
@Observable
public final class AccountModel {
    /// Estado de la hoja de inicio de sesión.
    public enum SignInState: Equatable {
        case requesting
        case waiting(code: String, url: URL, expiresAt: Date)
        case finishing
        case done(name: String)
        case failed(String)
    }

    public let manager: AccountManager
    public private(set) var snapshot = AccountSnapshot(accounts: [], selected: nil)
    /// Hay una hoja de inicio de sesión abierta (nil = cerrada).
    public var signIn: SignInState?
    /// Último error de cuenta que vale la pena mostrar (sesión vencida, credenciales que no se pudieron leer).
    public var notice: String?
    /// Sube cuando cambia la cuenta elegida: las páginas lo leen para recargarse.
    public private(set) var generation = 0
    /// La lectura de las credenciales lleva más de 2 s. Mientras tanto las páginas salen sin cuenta. (En macOS pasa cuando
    /// el Llavero espera el «Permitir»; en Windows el Administrador de credenciales no pregunta, pero se deja el aviso.)
    public private(set) var waitingForKeychain = false
    private var signInTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?

    public var isSignedIn: Bool { snapshot.isSignedIn }
    public var selected: Account? { snapshot.selected }

    public init(manager: AccountManager) {
        self.manager = manager
    }

    /// Lee las credenciales guardadas y escucha los cambios. Después actualiza nombres y avatares con `accounts_list` (sin bloquear).
    public func start() {
        guard observeTask == nil else { return }
        let manager = manager
        observeTask = Task { [weak self] in
            let slow = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.waitingForKeychain = true
            }
            do {
                try await manager.load()
            } catch {
                self?.notice = "No se pudieron leer las cuentas guardadas: \(error)"
            }
            slow.cancel()
            self?.waitingForKeychain = false
            for await snapshot in manager.updates() {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
        Task {
            _ = try? await manager.load()
            if await manager.isSignedIn { _ = try? await manager.refreshAccounts() }
        }
    }

    /// Pruebas: fija el estado sin pasar por las credenciales guardadas.
    public func setSnapshotForTesting(_ snapshot: AccountSnapshot) { self.snapshot = snapshot }

    private func apply(_ new: AccountSnapshot) {
        let changed = new.selected?.id != snapshot.selected?.id
        let lostSession = snapshot.isSignedIn && !new.isSignedIn && signIn == nil
        snapshot = new
        if changed { generation += 1 }
        if lostSession, notice == nil { notice = "Se cerró la sesión de YouTube." }
    }

    // MARK: - Inicio de sesión por código

    public func beginSignIn() {
        signInTask?.cancel()
        signIn = .requesting
        let manager = manager
        signInTask = Task { [weak self] in
            do {
                let code = try await manager.beginSignIn()
                guard !Task.isCancelled else { return }
                self?.signIn = .waiting(code: code.userCode, url: code.verificationURL, expiresAt: code.expiresAt)
                let snapshot = try await manager.completeSignIn(code)
                guard !Task.isCancelled else { return }
                self?.signIn = .done(name: snapshot.selected?.displayName ?? "tu cuenta")
                self?.apply(snapshot)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.signIn = .failed(Self.describe(error))
            }
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signIn = nil
    }

    // MARK: - Cuentas

    public func select(_ account: Account) {
        Task {
            do {
                apply(try await manager.select(accountId: account.id))
            } catch {
                notice = Self.describe(error)
            }
        }
    }

    /// Cierra la sesión de Google de la cuenta (con sus cuentas de marca) y la revoca.
    public func signOut(_ account: Account) {
        Task {
            do {
                apply(try await manager.signOut(accountId: account.id))
            } catch {
                notice = Self.describe(error)
            }
        }
    }

    public func refresh() {
        Task {
            do {
                apply(try await manager.refreshAccounts())
            } catch {
                notice = Self.describe(error)
            }
        }
    }

    /// Las cuentas agrupadas por sesión de Google (la personal primero).
    public var sessions: [[Account]] {
        var order: [String] = []
        var groups: [String: [Account]] = [:]
        for account in snapshot.accounts {
            if groups[account.credentialId] == nil { order.append(account.credentialId) }
            groups[account.credentialId, default: []].append(account)
        }
        return order.map { groups[$0]!.sorted { !$0.isBrand && $1.isBrand } }
    }

    public static func describe(_ error: Error) -> String {
        if let auth = error as? AuthError { return auth.description.prefix(1).uppercased() + auth.description.dropFirst() + "." }
        #if os(Windows)
        if let vault = error as? CredentialManagerError { return vault.description }
        #elseif canImport(Security)
        if let keychain = error as? KeychainError { return keychain.description }
        #endif
        if let urlError = error as? URLError { return "Sin conexión con YouTube (\(urlError.code.rawValue))." }
        return "\(error)"
    }
}

extension Account {
    /// Avatar más pequeño que llegue a `points` × 2 píxeles.
    public func avatarURL(points: Double) -> URL? {
        guard !CaptureMode.masksAccount else { return nil }
        return avatar.best(forWidth: Int(points * 2)).flatMap { URL(string: $0.url) }
    }

    /// "Personal" o "Cuenta de marca", para la segunda línea de los menús.
    public var kindLabel: String { isBrand ? "Cuenta de marca" : "Cuenta personal" }

    /// Nombre en pantalla (con `-GTAnonimo`, uno de prueba para las capturas).
    public var displayName: String {
        guard CaptureMode.masksAccount else { return name }
        return isBrand ? "Marca de prueba" : "Cuenta de prueba"
    }

    /// Segunda línea en pantalla (correo de la cuenta personal o @identificador de la de marca).
    public var displayByline: String? {
        guard CaptureMode.masksAccount else {
            // Sin correos en las capturas (`-GTSinCorreo`); los @identificadores sí.
            if CaptureMode.hidesEmails, let byline, byline.contains("@"), !byline.hasPrefix("@") { return nil }
            return byline
        }
        return byline == nil ? nil : (isBrand ? "@marcadeprueba" : "cuenta.de.prueba@example.com")
    }
}
