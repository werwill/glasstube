import Foundation
import YTKit

/// Subcomandos con cuenta. Las sesiones se guardan en el Llavero (las mismas que usa Glasstube.app). Nunca se imprimen
/// tokens; los nombres y correos salen enmascarados salvo con `--mostrar`.
extension CLI {
    static let accountUsage = """

        Con cuenta (sesión en el Llavero, compartida con Glasstube.app):
          ytkit signin                                   pide un código para youtube.com/activate y espera
          ytkit accounts [--refresh]                     cuentas guardadas (* = elegida)
          ytkit select <n>                               elige la cuenta n de `accounts`
          ytkit signout [<n>|--all] [--no-revoke]        cierra la sesión de Google de la cuenta n (y la revoca)
          ytkit subs | history | library | watchlater [--pages N]   (siempre por TV)
          ytkit like|unlike|dislike|undislike <videoId>
          ytkit subscribe|unsubscribe <UC…>
          ytkit plinfo <videoId>                         tus listas y si el video está en cada una
          ytkit pladd|plremove <playlistId> <videoId>
          ytkit watched <videoId> <segundos>…            reporta la posición vista (varias: en tiempo real)
          ytkit notinterested <feedbackToken>
          ytkit state <videoId>                          me gusta y suscripción del video con la cuenta
          ytkit rawauth <endpoint> <tv|web> clave=valor…   respuesta cruda con la cuenta (diagnóstico)
          ytkit record-account [carpeta] [--crudo DIR]   graba fixtures con la cuenta, anonimizadas
          ytkit sanitize <crudas> [carpeta]              vuelve a anonimizar respuestas crudas (sin red ni Llavero)
        Con --cuenta, los demás comandos (home, search, next…) van con la cuenta elegida.
        Con --sin-llavero, la sesión vive en memoria lo que dure el comando (pruebas automáticas: sin leer el Llavero ni
        su aviso de permiso tras recompilar).
        """

    static let accountCommands: Set<String> = [
        "signin", "accounts", "select", "signout", "subs", "history", "library", "watchlater", "like", "unlike",
        "dislike", "undislike", "subscribe", "unsubscribe", "plinfo", "pladd", "plremove", "watched", "notinterested",
        "state", "rawauth", "record-account", "playerauth",
    ]

    func runAccount(_ command: String, _ service: YouTubeService, _ options: Options, _ printer: Printer) async throws {
        guard let session = service.session else { throw CLIError("sin sesión") }
        let reveal = options.has("--mostrar")
        func arg(_ index: Int, _ what: String) throws -> String {
            guard options.positional.count > index else { throw CLIError("falta \(what)") }
            return options.positional[index]
        }
        switch command {
        case "signin":
            let code = try await session.beginSignIn()
            print("Escribe este código en \(code.verificationURL.absoluteString) con la cuenta que quieras usar:\n")
            print("    \(code.userCode)\n")
            print("Esperando la autorización (el código vence a las \(code.expiresAt.formatted(date: .omitted, time: .shortened)))…")
            #if canImport(Darwin)
            fflush(stdout)
            #else
            fflush(nil) // `stdout` de Glibc/ucrt no es seguro en concurrencia para Swift 6
            #endif
            let snapshot = try await session.completeSignIn(code)
            print("Listo. \(snapshot.accounts.count) cuenta(s) en esta sesión; elegida: \(mask(snapshot.selected?.name, reveal))")
        case "accounts":
            let snapshot = options.has("--refresh") ? try await session.refreshAccounts() : try await session.load()
            printAccounts(snapshot, reveal: reveal)
        case "select":
            let snapshot = try await session.load()
            guard let n = Int(try arg(0, "el número")), snapshot.accounts.indices.contains(n - 1) else { throw CLIError("número fuera de rango") }
            printAccounts(try await session.select(accountId: snapshot.accounts[n - 1].id), reveal: reveal)
        case "signout":
            let revoke = !options.has("--no-revoke")
            if options.has("--all") {
                printAccounts(try await session.signOutAll(revoke: revoke), reveal: reveal)
            } else {
                let snapshot = try await session.load()
                let account = try options.positional.first.map { value -> Account in
                    guard let n = Int(value), snapshot.accounts.indices.contains(n - 1) else { throw CLIError("número fuera de rango") }
                    return snapshot.accounts[n - 1]
                } ?? snapshot.selected
                guard let account else { throw CLIError("no hay sesión") }
                printAccounts(try await session.signOut(accountId: account.id, revoke: revoke), reveal: reveal)
            }
        case "subs", "history", "library", "watchlater":
            // Siempre por TV: la sesión de la app de TV no vale con el cliente WEB (HTTP 400).
            let page: BrowsePage
            switch command {
            case "subs": page = try await service.subscriptions()
            case "history": page = try await service.history()
            case "library": page = try await service.playlists()
            default: page = try await service.watchLater()
            }
            printer.page(page)
            try await paginate(service, page: page, pages: options.int("--pages") ?? 1, printer: printer)
        case "like": try await service.setLike(videoId: try arg(0, "el videoId")); print("ok")
        case "unlike": try await service.removeLike(videoId: try arg(0, "el videoId")); print("ok")
        case "dislike": try await service.setDislike(videoId: try arg(0, "el videoId")); print("ok")
        case "undislike": try await service.removeDislike(videoId: try arg(0, "el videoId")); print("ok")
        case "subscribe": try await service.subscribe(channelId: try arg(0, "el canal")); print("ok")
        case "unsubscribe": try await service.unsubscribe(channelId: try arg(0, "el canal")); print("ok")
        case "plinfo":
            let lists = try await service.playlistsInfo(videoId: try arg(0, "el videoId"))
            print("\(lists.count) listas:")
            for list in lists { print("  \(list.containsVideo ? "✓" : " ") \(list.id.count <= 4 ? list.id : String(list.id.prefix(4)) + "…")  \(list.title)") }
        case "pladd": try await service.addToPlaylist(playlistId: try arg(0, "la lista"), videoId: try arg(1, "el videoId")); print("ok")
        case "plremove": try await service.removeFromPlaylist(playlistId: try arg(0, "la lista"), videoId: try arg(1, "el videoId")); print("ok")
        case "watched":
            // Varias posiciones: se reportan en tiempo real (espera entre una y otra lo que avanzó), como el reproductor.
            let videoId = try arg(0, "el videoId")
            let positions = options.positional.dropFirst().compactMap(Double.init)
            guard !positions.isEmpty else { throw CLIError("faltan los segundos") }
            var previous: Double?
            for position in positions {
                if let previous, position > previous { try await Task.sleep(for: .seconds(position - previous)) }
                try await service.updateHistoryPosition(videoId: videoId, positionSeconds: position)
                print("reportado \(Int(position)) s")
                previous = position
            }
        case "playerauth":
            // Diagnóstico sin tokens: estado, si hay playbackTracking y dónde dice YouTube que se reanuda.
            let data = try await service.rawAuthenticatedPlayer(videoId: try arg(0, "el videoId"))
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            print("playability:", (json["playabilityStatus"] as? [String: Any])?["status"] ?? "?",
                  "· playbackTracking:", json["playbackTracking"] != nil ? "sí" : "no")
            func walk(_ node: Any, _ path: String) {
                if let dict = node as? [String: Any] {
                    for (key, value) in dict {
                        let lower = key.lowercased()
                        if lower.contains("start") && (lower.contains("sec") || lower.contains("ms")) || lower.contains("resume") {
                            print("  \(path).\(key) = \(value is [String: Any] || value is [Any] ? "{…}" : "\(value)")")
                        }
                        walk(value, path + "." + key)
                    }
                } else if let array = node as? [Any] {
                    for (index, value) in array.enumerated() { walk(value, path + "[\(index)]") }
                }
            }
            walk(json, "$")
        case "notinterested": try await service.markAsNotInterested(feedbackToken: try arg(0, "el token")); print("ok")
        case "state":
            let meta = try await service.metadata(videoId: try arg(0, "el videoId"))
            print("«\(meta.title ?? "?")» — me gusta: \(meta.likeStatus?.rawValue ?? "?"), suscrito a \(meta.author ?? "?"): \(meta.isSubscribed.map { $0 ? "sí" : "no" } ?? "?")")
        case "record-account":
            try await AccountRecorder(service: service, directory: options.positional.first).run(rawDirectory: options.value("--crudo"))
        case "rawauth":
            guard options.positional.count >= 2, let surface = Surface(rawValue: options.positional[1]) else {
                throw CLIError("uso: ytkit rawauth <endpoint> <tv|web> clave=valor…")
            }
            var fields: [String: String] = [:]
            for pair in options.positional.dropFirst(2) {
                guard let equals = pair.firstIndex(of: "=") else { continue }
                fields[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            }
            FileHandle.standardOutput.write(try await service.rawRequest(options.positional[0], surface: surface, fields: fields, authenticated: true))
        default:
            throw CLIError("comando desconocido")
        }
    }

    func printAccounts(_ snapshot: AccountSnapshot, reveal: Bool) {
        guard !snapshot.accounts.isEmpty else { return print("Sin sesión.") }
        let sessions = Set(snapshot.accounts.map(\.credentialId)).count
        print("\(snapshot.accounts.count) cuenta(s) en \(sessions) sesión(es) de Google:")
        for (index, account) in snapshot.accounts.enumerated() {
            let mark = account.id == snapshot.selected?.id ? "*" : " "
            let kind = account.isBrand ? "marca" : "personal"
            print("  \(mark) \(index + 1). [\(kind)] \(mask(account.name, reveal)) — \(mask(account.byline, reveal))"
                  + "\(account.hasChannel ? "" : " (sin canal)")\(account.isActivated ? " (activada)" : "")")
        }
    }

    /// "Cuenta de prueba" → "C•••a"; "persona@gmail.com" → "p•••@gmail.com".
    func mask(_ value: String?, _ reveal: Bool) -> String {
        guard let value, !value.isEmpty else { return "—" }
        if reveal { return value }
        if let at = value.firstIndex(of: "@"), at != value.startIndex {
            return String(value[value.startIndex]) + "•••" + value[at...]
        }
        return String(value.prefix(1)) + "•••" + String(value.suffix(1))
    }
}
