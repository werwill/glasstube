import AppKit
import Foundation
import Observation
import YTKit

/// Cuentas de YouTube en la app (el `SignInService` de SmartTube sobre `AccountManager` de YTKit). Los tokens viven en
/// el Llavero y en YTKit; aquí solo hay nombres, avatares y el estado del inicio de sesión. Nada de esto se registra.
@Observable
final class AccountModel {
    /// Estado de la hoja de inicio de sesión.
    enum SignInState: Equatable {
        case requesting
        case waiting(code: String, url: URL, expiresAt: Date)
        case finishing
        case done(name: String)
        case failed(String)
    }

    let manager: AccountManager
    private(set) var snapshot = AccountSnapshot(accounts: [], selected: nil)
    /// Hay una hoja de inicio de sesión abierta (nil = cerrada).
    var signIn: SignInState?
    /// Último error de cuenta que vale la pena mostrar (sesión vencida, Llavero denegado).
    var notice: String?
    /// Sube cuando cambia la cuenta elegida: las páginas lo leen para recargarse.
    private(set) var generation = 0
    /// La lectura del Llavero lleva más de 2 s: macOS está esperando el «Permitir» de la persona (pasa después de cada
    /// compilación, porque la app va firmada ad hoc). Mientras tanto las páginas salen sin cuenta.
    private(set) var waitingForKeychain = false
    private var signInTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?

    var isSignedIn: Bool { snapshot.isSignedIn }
    var selected: Account? { snapshot.selected }

    init(manager: AccountManager) {
        self.manager = manager
    }

    /// Lee el Llavero y escucha los cambios. Después actualiza nombres y avatares con `accounts_list` (sin bloquear).
    func start() {
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
                self?.notice = String(localized: "No se pudieron leer las cuentas del Llavero: \(Self.describe(error))")
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

    /// Pruebas: fija el estado sin pasar por el Llavero.
    func setSnapshotForTesting(_ snapshot: AccountSnapshot) { self.snapshot = snapshot }

    private func apply(_ new: AccountSnapshot) {
        let changed = new.selected?.id != snapshot.selected?.id
        let lostSession = snapshot.isSignedIn && !new.isSignedIn && signIn == nil
        snapshot = new
        if changed { generation += 1 }
        if lostSession, notice == nil { notice = String(localized: "Se cerró la sesión de YouTube.") }
    }

    // MARK: - Inicio de sesión por código

    func beginSignIn() {
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
                self?.signIn = .done(name: snapshot.selected?.displayName ?? String(localized: "tu cuenta"))
                self?.apply(snapshot)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.signIn = .failed(Self.describe(error))
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signIn = nil
    }

    // MARK: - Cuentas

    func select(_ account: Account) {
        Task {
            do {
                apply(try await manager.select(accountId: account.id))
            } catch {
                notice = Self.describe(error)
            }
        }
    }

    /// Cierra la sesión de Google de la cuenta (con sus cuentas de marca) y la revoca.
    func signOut(_ account: Account) {
        Task {
            do {
                apply(try await manager.signOut(accountId: account.id))
            } catch {
                notice = Self.describe(error)
            }
        }
    }

    func refresh() {
        Task {
            do {
                apply(try await manager.refreshAccounts())
            } catch {
                notice = Self.describe(error)
            }
        }
    }

    /// Las cuentas agrupadas por sesión de Google (la personal primero).
    var sessions: [[Account]] {
        var order: [String] = []
        var groups: [String: [Account]] = [:]
        for account in snapshot.accounts {
            if groups[account.credentialId] == nil { order.append(account.credentialId) }
            groups[account.credentialId, default: []].append(account)
        }
        return order.map { groups[$0]!.sorted { !$0.isBrand && $1.isBrand } }
    }

    static func describe(_ error: Error) -> String {
        // Los textos de YTKit van en español (los comparte la app de Windows): aquí, en el idioma de la interfaz.
        if let auth = error as? AuthError {
            switch auth {
            case .codeExpired: return String(localized: "El código venció antes de autorizarlo.")
            case .accessDenied: return String(localized: "Se rechazó el acceso en la página de activación.")
            case .revoked: return String(localized: "Google ya no acepta esta sesión; hay que volver a iniciarla.")
            case .clientNotFound: return String(localized: "No se encontró el client_id de la app de TV de YouTube.")
            case .rejected(let code): return String(localized: "Google rechazó la petición (\(code)).")
            case .notSignedIn: return String(localized: "No hay ninguna sesión iniciada.")
            }
        }
        if let keychain = error as? KeychainError {
            let message = SecCopyErrorMessageString(keychain.status, nil) as String? ?? "\(keychain.status)"
            return String(localized: "Llavero: \(message) (\(keychain.status))")
        }
        if let urlError = error as? URLError { return String(localized: "Sin conexión con YouTube (\(urlError.code.rawValue)).") }
        if let ytkit = error as? YTKitError {
            switch ytkit {
            case .signInRequired(let what): return String(localized: "\(what) requiere iniciar sesión.")
            case .notAvailable(let what): return String(localized: "No disponible: \(what)")
            case .badResponse(let what): return String(localized: "Respuesta inesperada: \(what)")
            }
        }
        return "\(error)"
    }
}

extension Account {
    /// Avatar más pequeño que llegue a `points` × 2 píxeles.
    func avatarURL(points: CGFloat) -> URL? {
        guard !Automation.shared.masksAccount else { return nil }
        return avatar.best(forWidth: Int(points * 2)).flatMap { URL(string: $0.url) }
    }

    /// "Personal" o "Cuenta de marca", para la segunda línea de los menús.
    var kindLabel: String { isBrand ? String(localized: "Cuenta de marca") : String(localized: "Cuenta personal") }

    /// Nombre en pantalla (con `-GTAnonimo`, uno de prueba para las capturas).
    var displayName: String {
        guard Automation.shared.masksAccount else { return name }
        return isBrand ? String(localized: "Marca de prueba") : String(localized: "Cuenta de prueba")
    }

    /// Segunda línea en pantalla (correo de la cuenta personal o @identificador de la de marca).
    var displayByline: String? {
        guard Automation.shared.masksAccount else {
            // Sin correos en las capturas (`-GTSinCorreo`); los @identificadores sí.
            if Automation.shared.hidesEmails, let byline, byline.contains("@"), !byline.hasPrefix("@") { return nil }
            return byline
        }
        return byline == nil ? nil : (isBrand ? "@marcadeprueba" : "cuenta.de.prueba@example.com")
    }
}
