import Foundation

/// Un mensaje del canal: `[id, ["tipo", argumentos…]]`. El id crece de uno en uno en cada sesión; el último visto se
/// devuelve como `AID` para que el servidor no repita lo ya entregado.
struct LoungeMessage {
    var id: Int
    var payload: [Any]

    var type: String? { payload.first as? String }
    /// Primer argumento como texto (`["c", "SID", …]`, `["S", "gsessionid"]`).
    var firstArgument: String? { payload.count > 1 ? LoungeValue.string(payload[1]) : nil }
}

/// Corta el cuerpo del canal largo en sus trozos. Cada trozo es `<longitud>\n<arreglo JSON>\n`. La longitud cuenta
/// caracteres de JavaScript (UTF-16), no bytes, así que en lugar de contarla se busca el cierre del arreglo siguiendo
/// los corchetes fuera de las cadenas: en UTF-8 ningún byte de un carácter de varios bytes es `[`, `]`, `"` ni `\`.
/// (SmartTube junta líneas hasta una que sea `]`; esto no depende de cómo venga partido el texto.)
struct BindChunkParser {
    private var buffer: [UInt8] = []

    /// Agrega lo recibido y devuelve los mensajes de los trozos completos.
    mutating func feed(_ data: Data) -> [LoungeMessage] {
        buffer.append(contentsOf: data)
        var messages: [LoungeMessage] = []
        while let (end, json) = nextChunk() {
            buffer.removeFirst(end)
            guard let array = try? JSONSerialization.jsonObject(with: Data(json)) as? [Any] else { continue }
            for case let entry as [Any] in array {
                guard entry.count >= 2, let id = (entry[0] as? NSNumber)?.intValue, let payload = entry[1] as? [Any] else { continue }
                messages.append(LoungeMessage(id: id, payload: payload))
            }
        }
        // Los saltos de línea entre trozos no cuentan como pendientes.
        if buffer.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { buffer.removeAll() }
        return messages
    }

    /// Lo que queda sin un trozo completo (para saber si el servidor cortó a la mitad).
    var pending: Int { buffer.count }

    /// Fin del siguiente trozo completo (bytes a consumir) y su JSON, o nil si falta llegar algo.
    private func nextChunk() -> (Int, ArraySlice<UInt8>)? {
        var index = 0
        func skipSpace() { while index < buffer.count, [0x20, 0x0A, 0x0D, 0x09].contains(buffer[index]) { index += 1 } }
        skipSpace()
        guard index < buffer.count else { return nil }
        // Longitud opcional (las respuestas de un POST también la traen; un cuerpo sin ella empieza con `[`).
        if buffer[index] != UInt8(ascii: "[") {
            guard let newline = buffer[index...].firstIndex(of: 0x0A) else { return nil }
            index = newline + 1
            skipSpace()
            guard index < buffer.count else { return nil }
        }
        guard buffer[index] == UInt8(ascii: "[") else {
            // Algo que no es JSON (p. ej. una página de error): se descarta hasta el siguiente salto de línea.
            guard let newline = buffer[index...].firstIndex(of: 0x0A) else { return nil }
            return (newline + 1, [])
        }
        let start = index
        var depth = 0
        var inString = false
        var escaped = false
        while index < buffer.count {
            let byte = buffer[index]
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return (index + 1, buffer[start...index]) }
            }
            index += 1
        }
        return nil
    }
}

/// Las direcciones de Lounge (`BindManager`, `InfoManager`, `BindParams` de SmartTube).
enum LoungeEndpoints {
    static let generateScreenId = URL(string: "https://www.youtube.com/api/lounge/pairing/generate_screen_id")!
    static let tokenBatch = URL(string: "https://www.youtube.com/api/lounge/pairing/get_lounge_token_batch")!
    static let pairingCode = URL(string: "https://www.youtube.com/api/lounge/pairing/get_pairing_code?ctx=pair")!
    static let bind = "https://www.youtube.com/api/lounge/bc/bind"
    /// `lb-v4` es la app de YouTube para TV («leanback»); con ella el teléfono la trata como una tele.
    static let app = "lb-v4"

    /// La dirección base del canal con los parámetros de pantalla de SmartTube (`dsp,mic,dpa`: cruceta, micrófono y
    /// «dial» de la TV), más los de la sesión.
    static func bindURL(_ extra: [(String, String)]) -> URL {
        var components = URLComponents(string: bind)!
        let base: [(String, String)] = [
            ("device", "LOUNGE_SCREEN"), ("theme", "cl"), ("capabilities", "dsp,mic,dpa"), ("mdxVersion", "2"),
            ("VER", "8"), ("v", "2"), ("t", "1"), ("app", app), ("zx", zx()),
        ]
        for (name, value) in base + extra { components.set(name, value) }
        return components.url!
    }

    /// Cadena aleatoria que BrowserChannel agrega para que nada en medio guarde la respuesta en caché.
    static func zx() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<12).map { _ in letters.randomElement()! })
    }

    /// Cuerpo `application/x-www-form-urlencoded`.
    static func form(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    /// `get_lounge_token_batch` → `screens[0]`.
    static func parseToken(_ data: Data) -> (screenId: String, token: String, expiration: Date?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let screens = object["screens"] as? [[String: Any]], let screen = screens.first,
              let screenId = LoungeValue.string(screen["screenId"]), let token = LoungeValue.string(screen["loungeToken"]) else { return nil }
        let expiration = LoungeValue.double(screen["expiration"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return (screenId, token, expiration)
    }
}
