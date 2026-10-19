import Foundation
import YTKit

/// `ytkit record-account <carpeta>`: graba respuestas con la cuenta elegida para las pruebas, **anonimizadas**: sin
/// tokens, correos, nombres, identificadores de la cuenta ni ids de sus listas propias. Las páginas (Suscripciones,
/// Historial, Playlists, Ver más tarde, `next` con sesión) van en la carpeta; lo demás (accounts_list,
/// get_add_to_playlist) en `cuenta/`. Si después de anonimizar queda algo sospechoso, no escribe nada.
@MainActor
struct AccountRecorder {
    let service: YouTubeService
    let directory: String?
    /// Video público conocido para `next` y `get_add_to_playlist` (freeCodeCamp, el de las demás fixtures).
    let videoId = "rfscVS0vtbw"

    var outputURL: URL { URL(fileURLWithPath: directory ?? "Tests/YTKitTests/Fixtures", isDirectory: true) }

    /// Lo que se quita entero: rastreo, contexto de la respuesta (lleva `datasyncId` y `visitorData`) y decoración.
    static let droppedKeys: Set<String> = Recorder.prunedKeys
        .subtracting(["buttonViewModel", "toggleButtonViewModel", "listItemViewModel"])
        .union(["responseContext", "visitorData", "datasyncId", "serializedUndoToken", "undoToken", "accessibilityData",
                "accessibility", "a11yLabel", "onCreateListCommand", "sharePanelCommand"])
    /// Claves cuyo valor es un token opaco: se cambia por uno de prueba (se conserva que existe).
    static let tokenKeys: Set<String> = ["token", "feedbackToken", "continuation", "params", "trackingParams",
                                         "serializedContextData", "clickTrackingParams", "pageId",
                                         // Identificadores de la cuenta en accounts_list.
                                         "obfuscatedGaiaId", "clientCacheKey", "datasyncIdToken", "datasyncId",
                                         "delegatedSessionId", "visitorData"]

    /// Pide las respuestas con la cuenta. Con `rawDirectory`, también las guarda crudas ahí (tienen datos personales,
    /// no tokens: solo para volver a anonimizar sin red con `ytkit sanitize`; bórralas después).
    func run(rawDirectory: String?) async throws {
        var raw: [(String, Data)] = []
        let accounts = try await service.rawRequest("account/accounts_list", surface: .tv, fields: [:], authenticated: true,
                                                    extra: ["accountReadMask": ["returnOwner": true, "returnBrandAccounts": true, "returnPersonaAccounts": false]])
        raw.append(("cuenta/accounts-list.json", accounts))
        let plinfo = try await service.rawRequest("playlist/get_add_to_playlist", surface: .tv, fields: [:], authenticated: true,
                                                  extra: ["videoIds": [videoId]])
        raw.append(("cuenta/plinfo-tv.json", plinfo))
        // Solo TV: con la sesión, el cliente WEB responde HTTP 400 a todo.
        for (name, fields) in [
            ("subs-tv", ["browseId": "FEsubscriptions"]), ("history-tv", ["browseId": "FEhistory"]),
            ("library-tv", ["browseId": "FEplaylist_aggregation"]), ("watchlater-tv", ["browseId": "VLWL"]),
            ("home-signed-tv", ["browseId": "default"]),
        ] {
            do {
                raw.append((name + ".json", try await service.rawRequest("browse", surface: .tv, fields: fields, authenticated: true)))
            } catch {
                print("\(name): \(error)")
            }
        }
        if let next = try? await service.rawRequest("next", surface: .tv, fields: ["videoId": videoId], authenticated: true) {
            raw.append(("next-signed-tv.json", next))
        }
        // El panel del menú de la primera tarjeta del Inicio que lo tenga (para "No me interesa").
        if let home = raw.first(where: { $0.0 == "home-signed-tv.json" })?.1,
           let page = try? await YouTubeService.parsePage(home, surface: .tv, api: .browse, kind: .home),
           let panel = page.groups.lazy.flatMap(\.items).compactMap(\.menuPanel).first,
           let data = try? await service.rawRequest("get_panel", surface: .tv, fields: ["panelId": panel.panelId, "params": panel.params],
                                                    authenticated: true) {
            raw.append(("cuenta/panel-tv.json", data))
        }

        if let rawDirectory {
            for (path, data) in raw {
                let url = URL(fileURLWithPath: rawDirectory).appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            print("Crudas en \(rawDirectory) (\(raw.count)); bórralas cuando termines.")
        }
        try Self.sanitize(raw, into: outputURL)
    }

    /// Anonimiza y escribe. Si después de anonimizar queda algo sospechoso en cualquier archivo, no escribe ninguno.
    static func sanitize(_ raw: [(String, Data)], into outputURL: URL) throws {
        var sanitizer = Sanitizer()
        guard let accounts = raw.first(where: { $0.0.hasSuffix("accounts-list.json") })?.1 else { throw CLIError("falta accounts-list.json") }
        try sanitizer.learn(accountsList: accounts)
        if let plinfo = raw.first(where: { $0.0.hasSuffix("plinfo-tv.json") })?.1 { try sanitizer.learn(playlistInfo: plinfo) }

        var outputs: [(URL, Data)] = []
        for (path, data) in raw {
            let clean = try sanitizer.clean(data, trim: !path.hasPrefix("cuenta/"))
            let leftovers = sanitizer.leftovers(in: clean)
            guard leftovers.isEmpty else {
                throw CLIError("\(path): quedan datos personales tras anonimizar (\(leftovers.joined(separator: ", "))); no se escribió nada")
            }
            outputs.append((outputURL.appendingPathComponent(path), clean))
        }
        for (url, data) in outputs {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            print("\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent): \(data.count) B")
        }
        print("Anonimizadas \(sanitizer.replacements.count) cadenas personales y los tokens opacos.")
    }

    /// `ytkit sanitize <crudas> [carpeta]`: vuelve a anonimizar las crudas sin red ni Llavero.
    static func sanitizeDirectory(_ rawDirectory: String, into outputURL: URL) throws {
        let base = URL(fileURLWithPath: rawDirectory)
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "json" }
        let raw = try files.map { url -> (String, Data) in
            let relative = url.path.replacingOccurrences(of: base.path + "/", with: "")
            return (relative, try Data(contentsOf: url))
        }
        try sanitize(raw, into: outputURL)
    }
}

/// Anonimizador de respuestas con sesión.
@MainActor
struct Sanitizer {
    /// Cadena personal → sustituto. Se reemplaza también dentro de otras cadenas (URLs, textos).
    private(set) var replacements: [String: String] = [:]
    private var tokenCounter = 0

    mutating func personal(_ value: String, _ replacement: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, replacements[trimmed] == nil else { return }
        replacements[trimmed] = replacement
    }

    /// Nombres, correos, @identificadores, pageIds, avatares e ids de canal de `accounts_list`.
    mutating func learn(accountsList data: Data) throws {
        let json = try JSONSerialization.jsonObject(with: data)
        var counter = 0
        Self.walk(json) { key, value in
            guard key == "accountItem", let item = value as? [String: Any] else { return }
            counter += 1
            if let name = Self.text(item["accountName"]) { personal(name, counter == 1 ? "Cuenta de prueba" : "Marca de prueba \(counter)") }
            if let byline = Self.text(item["accountByline"]) {
                personal(byline, byline.contains("@") ? "cuenta.de.prueba@example.com" : "Cuenta de marca de prueba")
            }
            if let handle = Self.text(item["channelHandle"]) { personal(handle, "@cuentadeprueba\(counter)") }
            Self.walk(item) { innerKey, innerValue in
                guard let string = innerValue as? String else { return }
                switch innerKey {
                case "pageId": personal(string, String(repeating: "0", count: max(1, string.count - 1)) + "\(counter)")
                case "obfuscatedGaiaId", "clientCacheKey", "datasyncIdToken":
                    // También pueden aparecer dentro de otras cadenas (el datasyncId es "<gaia>||<página>").
                    for part in string.components(separatedBy: "||") where part.count >= 8 {
                        personal(part, "ID_DE_PRUEBA_\(innerKey)_\(counter)")
                    }
                case "url" where string.contains("ggpht.com") || string.contains("googleusercontent.com"):
                    personal(string, "https://yt3.ggpht.com/ytc/cuenta-de-prueba=s88-c-k-c0x00ffffff-no-rj")
                case _ where string.hasPrefix("UC") && string.count == 24:
                    personal(string, "UC" + String(repeating: "0", count: 21) + "\(counter % 10)")
                default: break
                }
            }
        }
    }

    /// Ids y títulos de las listas propias (las que no son WL/LL).
    mutating func learn(playlistInfo data: Data) throws {
        let json = try JSONSerialization.jsonObject(with: data)
        var counter = 0
        Self.walk(json) { key, value in
            guard key == "playlistAddToOptionRenderer", let option = value as? [String: Any],
                  let id = option["playlistId"] as? String, id != "WL", id != "LL" else { return }
            counter += 1
            personal(id, "PLcuentadeprueba" + String(repeating: "0", count: max(0, id.count - 17)) + "\(counter % 10)")
            if let title = Self.text(option["title"]) { personal(title, "Lista de prueba \(counter)") }
        }
    }

    /// Quita lo que sobra, cambia los tokens por unos de prueba y reemplaza lo personal.
    mutating func clean(_ data: Data, trim: Bool) throws -> Data {
        let sorted = replacements.keys.sorted { $0.count > $1.count }
        let replacements = replacements
        func scrub(_ string: String) -> String {
            var out = string
            for key in sorted where out.contains(key) { out = out.replacingOccurrences(of: key, with: replacements[key]!) }
            return Self.scrubEmails(out)
        }
        func walk(_ value: Any, key: String?) -> Any {
            if let dict = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (childKey, child) in dict where !AccountRecorder.droppedKeys.contains(childKey) {
                    out[childKey] = walk(child, key: childKey)
                }
                return out
            }
            if var array = value as? [Any] {
                if trim, let key, Recorder.trimmedLists.contains(key), array.count > Recorder.maxItems {
                    let last = array.last as? [String: Any]
                    array = Array(array.prefix(Recorder.maxItems))
                    if let last, last["continuationItemRenderer"] != nil || last["continuationItemViewModel"] != nil { array.append(last) }
                }
                return array.map { walk($0, key: key) }
            }
            if let string = value as? String {
                if let key, AccountRecorder.tokenKeys.contains(key), replacements[string] == nil, string.count > 12 {
                    tokenCounter += 1
                    return "TOKEN_DE_PRUEBA_\(key)_\(tokenCounter)"
                }
                return scrub(string)
            }
            return value
        }
        let json = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: walk(json, key: nil), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Lo que no debería seguir ahí: valores personales conocidos, correos que no sean de example.com y formas de token.
    func leftovers(in data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var found = replacements.keys.filter { text.contains($0) }.map { _ in "valor personal" }
        for pattern in Self.suspiciousPatterns where text.range(of: pattern, options: .regularExpression) != nil {
            found.append(pattern)
        }
        return found
    }

    /// Formas de credenciales de Google: access token, refresh token, cabecera y claves de OAuth; correos ajenos.
    static let suspiciousPatterns = [
        #"ya29\.[A-Za-z0-9_-]{10,}"#, #"1//0[A-Za-z0-9_-]{10,}"#, #"Bearer [A-Za-z0-9._-]{10,}"#, #""(access|refresh)_token""#,
        #"[A-Za-z0-9._%+-]+@(?!example\.com)[A-Za-z0-9-]+\.[A-Za-z.]{2,}"#,
    ]

    static func scrubEmails(_ string: String) -> String {
        guard string.contains("@") else { return string }
        return string.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@(?!example\.com)[A-Za-z0-9-]+\.[A-Za-z.]{2,}"#,
                                    with: "cuenta.de.prueba@example.com", options: .regularExpression)
    }

    static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let dict = value as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] { return runs.compactMap { $0["text"] as? String }.joined() }
        return dict["content"] as? String
    }

    static func walk(_ node: Any, _ visit: (String, Any) -> Void) {
        if let dict = node as? [String: Any] {
            for key in dict.keys.sorted() {
                visit(key, dict[key]!)
                walk(dict[key]!, visit)
            }
        } else if let array = node as? [Any] {
            for value in array { walk(value, visit) }
        }
    }
}
