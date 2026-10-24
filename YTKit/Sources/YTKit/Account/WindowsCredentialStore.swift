#if os(Windows)
import Foundation
import WinSDK

public struct CredentialManagerError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let code: DWORD
    public var description: String { "Administrador de credenciales: \(operation) falló (error \(code))" }
}

/// La bóveda en el Administrador de credenciales de Windows: credenciales genéricas (`CRED_TYPE_GENERIC`) del usuario,
/// cifradas por Windows con su sesión, como el elemento genérico del Llavero en macOS.
///
/// Una credencial guarda a lo más `CRED_MAX_CREDENTIAL_BLOB_SIZE` (2560 B) y la bóveda (avatares incluidos) pasa de eso
/// con un par de cuentas, así que el JSON va partido en `mx.glasstube.cuentas/boveda/0`, `/1`, …; se lee hasta el primer
/// trozo que falte y al guardar se borran los que sobren.
struct WindowsCredentialStore: CredentialStore {
    static let defaultService = "mx.glasstube.cuentas"
    static let maxBlobSize = 2560
    let service: String
    let account = "boveda"

    init(service: String = WindowsCredentialStore.defaultService) { self.service = service }

    private func target(_ index: Int) -> String { "\(service)/\(account)/\(index)" }

    func load() throws -> Vault? {
        var data = Data()
        var index = 0
        while let chunk = try read(target(index)) {
            data.append(chunk)
            index += 1
        }
        if index == 0 { return nil }
        return try JSONDecoder().decode(Vault.self, from: data)
    }

    func save(_ vault: Vault) throws {
        let data = try JSONEncoder().encode(vault)
        var index = 0
        var offset = 0
        repeat {
            let end = min(offset + Self.maxBlobSize, data.count)
            try write(target(index), blob: data.subdata(in: offset..<end))
            offset = end
            index += 1
        } while offset < data.count
        try deleteChunks(from: index)
    }

    func delete() throws {
        try deleteChunks(from: 0)
    }

    // MARK: - Win32

    private func deleteChunks(from first: Int) throws {
        var index = first
        while try remove(target(index)) { index += 1 }
    }

    private func read(_ target: String) throws -> Data? {
        var credential: PCREDENTIALW?
        let found = target.withCString(encodedAs: UTF16.self) { CredReadW($0, DWORD(CRED_TYPE_GENERIC), 0, &credential) }
        guard found, let credential else {
            let code = GetLastError()
            if code == DWORD(ERROR_NOT_FOUND) { return nil }
            throw CredentialManagerError(operation: "CredReadW", code: code)
        }
        defer { CredFree(credential) }
        let size = Int(credential.pointee.CredentialBlobSize)
        guard size > 0, let blob = credential.pointee.CredentialBlob else { return Data() }
        return Data(bytes: blob, count: size)
    }

    private func write(_ target: String, blob: Data) throws {
        let written: Bool = target.withCString(encodedAs: UTF16.self) { targetName in
            "Glasstube: cuentas de YouTube".withCString(encodedAs: UTF16.self) { comment in
                account.withCString(encodedAs: UTF16.self) { userName in
                    var bytes = [UInt8](blob)
                    return bytes.withUnsafeMutableBufferPointer { buffer in
                        var credential = CREDENTIALW()
                        credential.`Type` = DWORD(CRED_TYPE_GENERIC)
                        credential.TargetName = UnsafeMutablePointer(mutating: targetName)
                        credential.Comment = UnsafeMutablePointer(mutating: comment)
                        credential.UserName = UnsafeMutablePointer(mutating: userName)
                        credential.CredentialBlobSize = DWORD(buffer.count)
                        credential.CredentialBlob = buffer.baseAddress
                        credential.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                        return CredWriteW(&credential, 0)
                    }
                }
            }
        }
        if !written { throw CredentialManagerError(operation: "CredWriteW", code: GetLastError()) }
    }

    /// `true` si había una credencial con ese nombre y se borró.
    private func remove(_ target: String) throws -> Bool {
        let deleted = target.withCString(encodedAs: UTF16.self) { CredDeleteW($0, DWORD(CRED_TYPE_GENERIC), 0) }
        if deleted { return true }
        let code = GetLastError()
        if code == DWORD(ERROR_NOT_FOUND) { return false }
        throw CredentialManagerError(operation: "CredDeleteW", code: code)
    }
}
#endif
