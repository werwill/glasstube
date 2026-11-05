import Foundation
import YTKit

// Iniciar y cerrar sesión desde la app (0.5): el código de la app de TV que se escribe en youtube.com/activate
// (`AccountManager.beginSignIn` / `completeSignIn` de YTKit, como `ytkit signin`), elegir entre las cuentas guardadas y
// cerrar la sesión de una. El `deviceCode` secreto se queda aquí: al cliente solo le llega el código para la persona.

struct AccountsPayload: Encodable {
    struct AccountPayload: Encodable {
        var id: String
        var name: String
        var byline: String?
        var avatar: String?
        var isBrand: Bool
        var isSelected: Bool
    }

    var signedIn: Bool
    var accounts: [AccountPayload]

    init(_ snapshot: AccountSnapshot) {
        signedIn = snapshot.isSignedIn
        accounts = snapshot.accounts.map {
            AccountPayload(id: $0.id, name: $0.name, byline: $0.byline,
                           avatar: $0.avatar.best(forWidth: 88).map { absolute($0.url) }, isBrand: $0.isBrand,
                           isSelected: $0.id == snapshot.selected?.id)
        }
    }
}

/// El inicio de sesión en curso: el código que se mostró y la espera de `gt_sign_in_wait`.
@MainActor
enum SignInState {
    static var code: DeviceCode?
    static var waiting: Task<AccountSnapshot, Error>?
}

extension Engine {
    /// Cambió la cuenta: lo que se guardó con la anterior ya no vale (el Inicio, la Bandeja, me gusta y suscripciones).
    func sessionChanged() {
        homeContinuation = nil
        homeSeen = []
        MetadataCache.invalidateAll()
        SubscriptionsState.shared.reset()
    }
}

/// Las cuentas guardadas: {"signedIn", "accounts": [{"id", "name", "byline", "avatar", "isBrand", "isSelected"}]}.
@_cdecl("gt_accounts")
public func gt_accounts(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        do {
            reply.ok(AccountsPayload(try await Engine.require().session.load()))
        } catch {
            reply.fail(error)
        }
    }
}

/// Pide un código nuevo: {"userCode", "verificationUrl", "expiresIn"} (segundos). Luego, `gt_sign_in_wait`.
@_cdecl("gt_sign_in_begin")
public func gt_sign_in_begin(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        do {
            SignInState.waiting?.cancel()
            SignInState.waiting = nil
            let code = try await Engine.require().session.beginSignIn()
            SignInState.code = code
            log("inicio de sesión: código pedido, vence en \(Int(code.expiresAt.timeIntervalSinceNow)) s")
            struct Payload: Encodable {
                var userCode: String
                var verificationUrl: String
                var expiresIn: Int
            }
            reply.ok(Payload(userCode: code.userCode, verificationUrl: code.verificationURL.absoluteString,
                             expiresIn: max(0, Int(code.expiresAt.timeIntervalSinceNow))))
        } catch {
            log("inicio de sesión: no se pudo pedir el código: \(error)")
            reply.fail(error)
        }
    }
}

/// Espera a que la persona apruebe el código de `gt_sign_in_begin` y guarda la sesión. Responde como `gt_accounts`;
/// falla si el código vence, si la persona lo rechaza o con `gt_sign_in_cancel` ("cancelado").
@_cdecl("gt_sign_in_wait")
public func gt_sign_in_wait(_ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            guard let code = SignInState.code else { throw FFIError("no hay un código pedido") }
            let waiting = Task { try await engine.session.completeSignIn(code) }
            SignInState.waiting = waiting
            let snapshot = try await waiting.value
            if SignInState.waiting == waiting {
                SignInState.waiting = nil
                SignInState.code = nil
            }
            engine.sessionChanged()
            log("inicio de sesión: listo, \(snapshot.accounts.count) cuentas")
            reply.ok(AccountsPayload(snapshot))
        } catch is CancellationError {
            log("inicio de sesión: cancelado")
            reply.fail("cancelado")
        } catch {
            log("inicio de sesión: \(error)")
            reply.fail(error)
        }
    }
}

/// Deja de esperar el código (la persona cerró el diálogo).
@_cdecl("gt_sign_in_cancel")
public func gt_sign_in_cancel() {
    Task { @MainActor in
        SignInState.waiting?.cancel()
        SignInState.waiting = nil
        SignInState.code = nil
    }
}

/// Elige una de las cuentas guardadas (otra sesión o una cuenta de marca). Responde como `gt_accounts`.
@_cdecl("gt_select_account")
public func gt_select_account(_ accountId: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    guard let accountId = string(accountId) else { return reply.fail("falta la cuenta") }
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            let snapshot = try await engine.session.select(accountId: accountId)
            engine.sessionChanged()
            log("cuenta elegida: \(snapshot.accounts.firstIndex { $0.id == accountId }.map { "\($0 + 1)" } ?? "?") de \(snapshot.accounts.count)")
            reply.ok(AccountsPayload(snapshot))
        } catch {
            reply.fail(error)
        }
    }
}

/// Cierra la sesión de Google de esa cuenta (con sus cuentas de marca): revoca el token y lo borra del Administrador
/// de credenciales. NULL = todas. Responde como `gt_accounts`.
@_cdecl("gt_sign_out")
public func gt_sign_out(_ accountId: UnsafePointer<CChar>?, _ callback: GTCallback, _ context: UnsafeMutableRawPointer?) {
    let reply = Reply(callback: callback, context: context)
    let accountId = string(accountId)
    Task { @MainActor in
        do {
            let engine = try Engine.require()
            let snapshot: AccountSnapshot
            if let accountId {
                snapshot = try await engine.session.signOut(accountId: accountId)
            } else {
                snapshot = try await engine.session.signOutAll()
            }
            engine.sessionChanged()
            log("sesión cerrada; quedan \(snapshot.accounts.count) cuentas")
            reply.ok(AccountsPayload(snapshot))
        } catch {
            reply.fail(error)
        }
    }
}
