// Comprueba una firma EdDSA de Sparkle con la clave pública que lleva la app (su SUPublicEDKey), sin el Llavero: así
// Scripts/release.sh se asegura de que la clave privada con la que firmó es la pareja de la que viaja en la app.
//
//   swift verificar-firma-sparkle.swift <clave pública base64> <firma base64> <archivo>
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let keyData = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]),
      let file = FileManager.default.contents(atPath: arguments[3]) else {
    FileHandle.standardError.write(Data("uso: verificar-firma-sparkle.swift <clave pública> <firma> <archivo>\n".utf8))
    exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    if key.isValidSignature(signature, for: file) {
        print("firma válida con la clave pública de la app")
    } else {
        FileHandle.standardError.write(Data("La firma NO corresponde a la clave pública de la app (SUPublicEDKey)\n".utf8))
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("clave pública inválida: \(error)\n".utf8))
    exit(2)
}
